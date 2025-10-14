#!/bin/bash

# Import common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Configuration
NAMESPACE=${NAMESPACE:-vastnfs-kmm}
VASTNFS_VERSION=${VASTNFS_VERSION:-4.0.35}
KMM_IMG=${KMM_IMG:-}
KUSTOMIZE_DIR=${KUSTOMIZE_DIR:-k8s/base}
FOLLOW_LOGS=false

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Install VAST NFS KMM and optionally follow logs"
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -n, --namespace NAME          Kubernetes namespace (default: $NAMESPACE)"
    echo "  -v, --version VERSION         VAST NFS version (default: $VASTNFS_VERSION)"
    echo "  -i, --image IMAGE             KMM image (default: auto-generated)"
    echo "  -d, --dir DIRECTORY           Kustomize directory (default: $KUSTOMIZE_DIR)"
    echo "  -f, --follow-logs             Follow pod logs after installation"
    echo ""
    echo "Environment Variables:"
    echo "  NAMESPACE                     Kubernetes namespace"
    echo "  VASTNFS_VERSION               VAST NFS version"
    echo "  KMM_IMG                       KMM image"
    echo "  KUSTOMIZE_DIR                 Kustomize directory"
    
    show_common_help_footer
}

install_vastnfs() {
    local namespace="$1"
    local vastnfs_version="$2"
    local kmm_img="$3"
    local kustomize_dir="$4"
    
    print_step "Installing VAST NFS KMM to namespace: $namespace"
    print_info "VAST NFS Version: $vastnfs_version"
    print_info "KMM Image: $kmm_img"
    print_info "Kustomize Directory: $kustomize_dir"
    
    # Export environment variables for envsubst
    export VASTNFS_VERSION="$vastnfs_version"
    export KMM_IMG="$kmm_img"
    export NAMESPACE="$namespace"
    export KMM_PULL_SECRET="${KMM_PULL_SECRET:-}"
    
    # Build and apply manifests
    # Validate pull secret if provided
    if [ -n "$KMM_PULL_SECRET" ]; then
        print_step "Validating pull secret..."
        if ! oc get secret "$KMM_PULL_SECRET" -n "$namespace" >/dev/null 2>&1; then
            print_error "Pull secret '$KMM_PULL_SECRET' not found in namespace '$namespace'"
            print_error "Please create the secret first or remove KMM_PULL_SECRET variable"
            print_error "Example: oc create secret docker-registry $KMM_PULL_SECRET --docker-server=... --docker-username=... --docker-password=... -n $namespace"
            return 1
        fi
        print_success "Pull secret '$KMM_PULL_SECRET' found"
    fi

    print_info "Building and applying manifests..."
    
    # Create temporary file for manifests
    local temp_manifest="/tmp/vastnfs-install-$$.yaml"
    
    # Build and apply manifests
    # Use KUSTOMIZE env var if set, otherwise fall back to 'kustomize' command
    local kustomize_cmd="${KUSTOMIZE:-kustomize}"
    
    if [ -n "$KMM_PULL_SECRET" ]; then
        print_info "Using pull secret overlay: $KMM_PULL_SECRET"
        "$kustomize_cmd" build "$kustomize_dir/../overlays/with-pull-secret" | envsubst '$VASTNFS_VERSION $KMM_IMG $NAMESPACE $KMM_PULL_SECRET' > "$temp_manifest"
    else
        print_info "No pull secret specified, using base configuration"
        "$kustomize_cmd" build "$kustomize_dir" | envsubst '$VASTNFS_VERSION $KMM_IMG $NAMESPACE' > "$temp_manifest"
    fi
    
    # Apply the manifests
    if oc apply -f "$temp_manifest"; then
        rm -f "$temp_manifest"
        print_success "VAST NFS KMM installed successfully"
        return 0
    else
        rm -f "$temp_manifest"
        print_error "Failed to install VAST NFS KMM"
        return 1
    fi
}

check_vastnfs_version() {
    local expected_version="$1"
    
    # Get all nodes  
    local nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    for node in $nodes; do
        # Check VAST NFS version on this node
        local version=$(oc debug node/$node -- chroot /host bash -c '
            if [[ -e /sys/module/sunrpc/parameters/nfs_bundle_version ]]; then
                cat /sys/module/sunrpc/parameters/nfs_bundle_version
            fi
        ' 2>&1 | grep -E "^[0-9]+\.[0-9]+\.[0-9]+" | head -1)
        
        if [[ "$version" == "$expected_version" ]]; then
            return 0  # Correct version found
        fi
    done
    
    return 1  # Correct version not found
}

wait_for_pods() {
    local namespace="$1"
    local timeout=60
    local count=0
    
    print_step "Waiting for pods to start..."
    sleep 5
    
    while [ $count -lt $timeout ]; do
        local pods=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        if [ -n "$pods" ]; then
            print_success "Found pods: $pods"
            return 0
        else
            if [ $((count % 10)) -eq 0 ]; then
                print_info "Waiting for pods to start... (${count}s elapsed)"
                
                # Check if correct version is already loaded (pods may have completed quickly)
                if check_vastnfs_version "$VASTNFS_VERSION" 2>/dev/null; then
                    print_success "VAST NFS version $VASTNFS_VERSION is already active - pods completed successfully"
                    return 0
                fi
            fi
            sleep 2
            count=$((count + 2))
        fi
    done
    
    # Final check if correct version is loaded before declaring timeout
    if check_vastnfs_version "$VASTNFS_VERSION" 2>/dev/null; then
        print_success "VAST NFS version $VASTNFS_VERSION is active - installation successful"
        return 0
    fi
    
    print_error "Timeout waiting for pods to start"
    return 1
}

wait_for_container_ready() {
    local namespace="$1"
    local pod="$2"
    local timeout=30  # Reduced from 300 to 30 seconds
    local count=0
    
    print_info "Waiting for pod $pod to be ready..."
    
    while [ $count -lt $timeout ]; do
        # Check if pod still exists
        if ! oc get pod "$pod" -n "$namespace" >/dev/null 2>&1; then
            print_info "Pod $pod no longer exists - it completed successfully"
            return 1  # Return error so we don't try to stream logs
        fi
        
        # Get pod phase
        local phase=$(oc get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        # If pod succeeded or failed, no need to wait for logs
        if [[ "$phase" == "Succeeded" ]]; then
            print_success "Pod $pod completed successfully"
            return 1  # Return error so we don't try to stream logs from completed pod
        elif [[ "$phase" == "Failed" ]]; then
            print_warning "Pod $pod failed"
            return 0  # Try to get logs to see what failed
        fi
        
        # Check if pod has any containers running
        local running_containers=$(oc get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || echo "")
        
        # Check if any container is ready or if we can get logs
        if [[ "$running_containers" == *"true"* ]] || [[ "$phase" == "Running" ]] || oc logs "$pod" -n "$namespace" --tail=1 >/dev/null 2>&1; then
            print_success "Pod $pod is ready for log streaming"
            return 0
        fi
        
        # Show current status every 10 seconds
        if [ $((count % 10)) -eq 0 ]; then
            print_info "Pod status: $phase, waiting... ($count/$timeout)"
        fi
        
        sleep 2
        count=$((count + 2))
    done
    
    print_info "Pod may have completed too quickly to stream logs"
    return 1
}

follow_pod_logs() {
    local namespace="$1"
    
    print_step "Following pod logs..."
    
    # Get all pods in the namespace
    local pods=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$pods" ]; then
        print_info "Found pods: $pods"
        
        local pods_to_follow=()
        
        # Wait for each pod to be ready and follow logs
        for pod in $pods; do
            print_info "=== Preparing to follow logs for $pod ==="
            
            # Wait for container to be ready (with timeout)
            if wait_for_container_ready "$namespace" "$pod"; then
                pods_to_follow+=("$pod")
            else
                print_info "Pod $pod completed too quickly to stream logs (this is normal with pre-built images)"
            fi
        done
        
        # If no pods are available for streaming, that's okay - they completed quickly
        if [ ${#pods_to_follow[@]} -eq 0 ]; then
            print_success "All pods completed successfully"
            return 0
        fi
        
        # Stream logs from available pods
        for pod in "${pods_to_follow[@]}"; do
            print_info "Starting log stream for $pod..."
            
            # Follow logs with retry logic
            {
                # Try to get logs, retry if container isn't ready yet
                local retry_count=0
                while [ $retry_count -lt 10 ]; do
                    if oc logs -f "$pod" -n "$namespace" --tail=50 2>/dev/null; then
                        break
                    else
                        print_info "Retrying log stream for $pod... ($retry_count/10)"
                        sleep 3
                        retry_count=$((retry_count + 1))
                    fi
                done
            } &
        done
        
        print_info "Log streaming started for all pods. Press Ctrl+C to stop."
        
        # Wait for all background processes
        wait
    else
        print_error "No pods found to follow logs"
        return 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -v|--version)
            VASTNFS_VERSION="$2"
            shift 2
            ;;
        -i|--image)
            KMM_IMG="$2"
            shift 2
            ;;
        -d|--dir)
            KUSTOMIZE_DIR="$2"
            shift 2
            ;;
        -f|--follow-logs)
            FOLLOW_LOGS=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main execution
main() {
    print_header "VAST NFS KMM Installation"
    
    check_prerequisites
    check_openshift_login
    
    # Set default KMM_IMG if not provided
    if [ -z "$KMM_IMG" ]; then
        print_error "KMM_IMG environment variable not set"
        print_info "Please set KMM_IMG or use the Makefile which sets it automatically"
        exit 1
    fi
    
    show_configuration "Installation Configuration" "NAMESPACE" "VASTNFS_VERSION" "KMM_IMG" "KUSTOMIZE_DIR"
    
    # Install VAST NFS KMM
    if ! install_vastnfs "$NAMESPACE" "$VASTNFS_VERSION" "$KMM_IMG" "$KUSTOMIZE_DIR"; then
        exit 1
    fi
    
    # Follow logs if requested
    if [ "$FOLLOW_LOGS" = "true" ]; then
        if wait_for_pods "$NAMESPACE"; then
            follow_pod_logs "$NAMESPACE"
        else
            print_warning "Could not wait for pods, skipping log following"
        fi
    fi
    
    print_success "VAST NFS KMM installation completed"
    
    echo ""
    print_info "Next Steps:"
    print_info "1. The kernel modules are now being built and deployed to cluster nodes"
    print_info "2. After the build completes, DaemonSet pods will start on each node"
    print_info "3. Each node will then load the VAST NFS kernel modules (modprobe)"
    print_info ""
    print_warning "IMPORTANT: Wait approximately 1-2 minutes before running verification"
    print_info "   This allows time for:"
    print_info "   - Module compilation to complete"
    print_info "   - DaemonSet pods to start on all nodes"  
    print_info "   - Kernel modules to be loaded via modprobe"
    print_info ""
    print_info "To verify installation:"
    print_info "   make verify"
    print_info ""
    print_info "For VAST NFS driver documentation:"
    print_info "   https://vastnfs.vastdata.com/docs/4.0/Intro.html"
}

# Run main function
main "$@"
