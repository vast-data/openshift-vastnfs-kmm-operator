#!/bin/bash

# VAST NFS KMM Deployment with Secure Boot Support
# This script sets up and deploys VAST NFS with kernel module signing for secure boot environments

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Configuration (using common.sh defaults)
NAMESPACE=${NAMESPACE:-$DEFAULT_NAMESPACE}
VASTNFS_VERSION=${VASTNFS_VERSION:-$DEFAULT_VASTNFS_VERSION}
KUSTOMIZE_DIR=${KUSTOMIZE_DIR:-"k8s/overlays/secure-boot"}
FOLLOW_LOGS=false

# Secure Boot specific configuration
SIGNING_KEY_SECRET=${SIGNING_KEY_SECRET:-$DEFAULT_SIGNING_KEY_SECRET}
SIGNING_CERT_SECRET=${SIGNING_CERT_SECRET:-$DEFAULT_SIGNING_CERT_SECRET}
IMAGE_REPO_SECRET=${IMAGE_REPO_SECRET:-$DEFAULT_IMAGE_REPO_SECRET}

# Image configuration (KMM_IMG is passed from Makefile)
KMM_IMG_REPO=${KMM_IMG_REPO:-$DEFAULT_KMM_IMG_REPO}
KMM_PULL_SECRET=${KMM_PULL_SECRET:-""}

# Key file paths (can be overridden)
PRIVATE_KEY_FILE=${PRIVATE_KEY_FILE:-""}
PUBLIC_CERT_FILE=${PUBLIC_CERT_FILE:-""}

show_deployment_configuration() {
    show_configuration "Configuration" \
        "NAMESPACE" \
        "VASTNFS_VERSION" \
        "SIGNING_KEY_SECRET" \
        "SIGNING_CERT_SECRET" \
        "IMAGE_REPO_SECRET" \
        "KMM_IMG"
}

generate_keys() {
    if [ -n "$PRIVATE_KEY_FILE" ] && [ -n "$PUBLIC_CERT_FILE" ]; then
        print_step "Using provided key files..."
        check_file_exists "$PRIVATE_KEY_FILE" "Private key file"
        check_file_exists "$PUBLIC_CERT_FILE" "Public certificate file"
        return
    fi
    
    print_step "Generating secure boot keys..."
    
    # Create temporary directory for keys
    KEY_DIR=$(mktemp -d)
    
    # Use the dedicated key generation script
    KEYS_DIR="$KEY_DIR" KEY_NAME="vastnfs_signing_key" "$SCRIPT_DIR/generate_secure_boot_keys.sh" --force
    
    PRIVATE_KEY_FILE="${KEY_DIR}/vastnfs_signing_key.priv"
    PUBLIC_CERT_FILE="${KEY_DIR}/vastnfs_signing_key.der"
    
    print_info "Keys generated using dedicated script"
    print_warning "IMPORTANT: Save these keys securely!"
    print_info "Private Key: ${PRIVATE_KEY_FILE}"
    print_info "Public Cert: ${PUBLIC_CERT_FILE}"
    echo ""
}

create_secrets() {
    print_step "Creating Kubernetes secrets..."
    
    # Create namespace if it doesn't exist
    create_namespace_if_not_exists "${NAMESPACE}"
    
    # Create private key secret
    create_secret_from_file "${SIGNING_KEY_SECRET}" "${NAMESPACE}" "key" "${PRIVATE_KEY_FILE}"
    
    # Create certificate secret
    create_secret_from_file "${SIGNING_CERT_SECRET}" "${NAMESPACE}" "cert" "${PUBLIC_CERT_FILE}"
    
    # Note: For OpenShift internal registry, no separate registry secret is needed
    # Build pods automatically have access through service account tokens
    print_info "Using OpenShift internal registry with service account authentication"
}

verify_keys() {
    print_step "Verifying keys..."
    
    # Verify private key secret
    verify_secret_content "${SIGNING_KEY_SECRET}" "${NAMESPACE}" "key" "grep -q 'BEGIN.*KEY'"
    
    # Verify certificate secret
    verify_secret_content "${SIGNING_CERT_SECRET}" "${NAMESPACE}" "cert" "openssl x509 -inform der -text"
}

deploy_vastnfs() {
    print_step "Deploying VAST NFS with secure boot support..."
    
    # Export environment variables for envsubst
    export NAMESPACE
    export VASTNFS_VERSION
    export KMM_IMG
    export SIGNING_KEY_SECRET
    export SIGNING_CERT_SECRET
    export IMAGE_REPO_SECRET
    
    # Build and apply manifests
    local temp_manifest="/tmp/vastnfs-secure-boot.yaml"
    
    # Validate pull secret if provided
    if [ -n "$KMM_PULL_SECRET" ]; then
        print_step "Validating pull secret..."
        if ! oc get secret "$KMM_PULL_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
            print_error "Pull secret '$KMM_PULL_SECRET' not found in namespace '$NAMESPACE'"
            print_error "Please create the secret first or remove KMM_PULL_SECRET variable"
            print_error "Example: oc create secret docker-registry $KMM_PULL_SECRET --docker-server=... --docker-username=... --docker-password=... -n $NAMESPACE"
            exit 1
        fi
        print_success "Pull secret '$KMM_PULL_SECRET' found"
    fi

    print_info "Building manifests with kustomize..."
    # Use KUSTOMIZE env var if set, otherwise fall back to 'kustomize' command
    local kustomize_cmd="${KUSTOMIZE:-kustomize}"
    
    if [ -n "$KMM_PULL_SECRET" ]; then
        print_info "Using pull secret overlay: $KMM_PULL_SECRET"
        "$kustomize_cmd" build "${KUSTOMIZE_DIR}/../overlays/with-pull-secret" | envsubst '$NAMESPACE $VASTNFS_VERSION $KMM_IMG $KMM_PULL_SECRET $SIGNING_KEY_SECRET $SIGNING_CERT_SECRET $IMAGE_REPO_SECRET' > "$temp_manifest"
    else
        print_info "No pull secret specified, using base configuration"
        "$kustomize_cmd" build "${KUSTOMIZE_DIR}" | envsubst '$NAMESPACE $VASTNFS_VERSION $KMM_IMG $SIGNING_KEY_SECRET $SIGNING_CERT_SECRET $IMAGE_REPO_SECRET' > "$temp_manifest"
    fi
    
    print_info "Applying to cluster..."
    oc apply -f "$temp_manifest"
    
    # Cleanup temp file
    cleanup_temp_files "$temp_manifest"
    
    print_success "VAST NFS deployed with secure boot support"
}

monitor_deployment() {
    print_step "Monitoring deployment..."
    
    print_info "Module status:"
    oc get module vastnfs -n "${NAMESPACE}" 2>/dev/null || echo "Module not found yet"
    
    echo ""
    print_info "Pods:"
    oc get pods -n "${NAMESPACE}" 2>/dev/null || echo "No pods found yet"
    
    echo ""
    print_info "To monitor the deployment:"
    echo "  oc get module vastnfs -n ${NAMESPACE} -w"
    echo "  oc get pods -n ${NAMESPACE} -w"
    echo "  oc logs -f -l kmm.node.kubernetes.io/module.name=vastnfs -n ${NAMESPACE}"
}

show_verification() {
    print_step "Verification commands:"
    echo ""
    echo "After deployment completes, verify VAST NFS is working:"
    echo ""
    echo "1. Check module status:"
    echo "   oc get module vastnfs -n ${NAMESPACE}"
    echo ""
    echo "2. Verify VAST NFS is loaded on nodes:"
    echo "   oc debug node/<node-name> -- chroot /host cat /sys/module/sunrpc/parameters/nfs_bundle_version"
    echo ""
    echo "3. Check signed modules:"
    echo "   oc debug node/<node-name> -- chroot /host modinfo sunrpc | grep signature"
    echo ""
    echo "4. Verify secure boot status:"
    echo "   oc debug node/<node-name> -- chroot /host mokutil --sb-state"
    echo ""
}


show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Install VAST NFS KMM with secure boot support"
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -n, --namespace NAME          Kubernetes namespace (default: $NAMESPACE)"
    echo "  -v, --version VERSION         VAST NFS version (default: $VASTNFS_VERSION)"
    echo "  -d, --dir DIRECTORY           Kustomize directory (default: $KUSTOMIZE_DIR)"
    echo "  -f, --follow-logs             Follow pod logs after installation"
    echo "  --keys PRIVATE PUBLIC         Use existing key files for signing"
    echo ""
    echo "Environment Variables:"
    echo "  NAMESPACE                     Kubernetes namespace"
    echo "  VASTNFS_VERSION               VAST NFS version"
    echo "  KUSTOMIZE_DIR                 Kustomize directory"
    echo "  PRIVATE_KEY_FILE              Path to private key file"
    echo "  PUBLIC_CERT_FILE              Path to public certificate file"
    
    show_common_help_footer
}

# Import log following functions from install_and_follow_logs.sh
wait_for_container_ready() {
    local namespace="$1"
    local pod="$2"
    local timeout=300
    local count=0
    
    print_info "Waiting for pod $pod to be ready..."
    
    while [ $count -lt $timeout ]; do
        local running_containers=$(oc get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || echo "")
        local phase=$(oc get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [[ "$running_containers" == *"true"* ]] || [[ "$phase" == "Running" ]] || oc logs "$pod" -n "$namespace" --tail=1 >/dev/null 2>&1; then
            print_success "Pod $pod is ready for log streaming"
            return 0
        fi
        
        print_info "Pod status: $phase, waiting... ($count/$timeout)"
        sleep 2
        count=$((count + 2))
    done
    
    print_warning "Timeout waiting for pod $pod to be ready, will try to get logs anyway"
    return 1
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
            fi
            sleep 2
            count=$((count + 2))
        fi
    done
    
    print_error "Timeout waiting for pods to start"
    return 1
}

follow_pod_logs() {
    local namespace="$1"
    
    print_step "Following pod logs..."
    
    local pods=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$pods" ]; then
        print_info "Found pods: $pods"
        
        for pod in $pods; do
            print_info "=== Preparing to follow logs for $pod ==="
            wait_for_container_ready "$namespace" "$pod"
            print_info "Starting log stream for $pod..."
            
            {
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
        -d|--dir)
            KUSTOMIZE_DIR="$2"
            shift 2
            ;;
        -f|--follow-logs)
            FOLLOW_LOGS=true
            shift
            ;;
        --keys)
            PRIVATE_KEY_FILE="$2"
            PUBLIC_CERT_FILE="$3"
            shift 3
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
    print_header "VAST NFS KMM Deployment with Secure Boot Support"
    check_prerequisites
    check_openshift_login
    show_deployment_configuration
    generate_keys
    create_secrets
    verify_keys
    deploy_vastnfs
    monitor_deployment
    
    # Follow logs if requested
    if [ "$FOLLOW_LOGS" = "true" ]; then
        if wait_for_pods "$NAMESPACE"; then
            follow_pod_logs "$NAMESPACE"
        else
            print_warning "Could not wait for pods, skipping log following"
        fi
    fi
    
    show_verification
    
    echo ""
    print_success "VAST NFS deployment with secure boot support completed!"
    echo ""
    print_info "Next Steps:"
    print_info "1. The signed kernel modules are now being built and deployed to cluster nodes"
    print_info "2. After the build completes, DaemonSet pods will start on each node"
    print_info "3. Each node will then load the signed VAST NFS kernel modules (modprobe)"
    print_info ""
    print_warning "IMPORTANT: Wait approximately 2-3 minutes before running verification"
    print_info "   Secure boot builds take longer due to module signing. This allows time for:"
    print_info "   - Signed module compilation to complete"
    print_info "   - DaemonSet pods to start on all nodes"  
    print_info "   - Signed kernel modules to be loaded via modprobe"
    print_info ""
    print_info "To verify installation:"
    print_info "   make verify"
    print_info "   make verify-secure-boot  # For secure boot specific checks"
    print_info ""
    print_warning "Secure Boot Important Notes:"
    print_info "1. Ensure the public key is enrolled in the MOK database on secure boot nodes"
    print_info "2. The signing process may take several minutes to complete"
    print_info "3. Monitor the deployment using the verification commands shown above"
    print_info ""
    print_info "For VAST NFS driver documentation:"
    print_info "   https://vastnfs.vastdata.com/docs/4.0/Intro.html"
    echo ""
}

# Run main function
main
