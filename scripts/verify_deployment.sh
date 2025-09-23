#!/bin/bash

# VAST NFS Deployment Verification Script
# This script verifies that VAST NFS is properly deployed and working

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Configuration
NAMESPACE=${NAMESPACE:-$DEFAULT_NAMESPACE}
MODULE_NAME=${MODULE_NAME:-vastnfs}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Verify VAST NFS deployment status"
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -n, --namespace NAME          Kubernetes namespace (default: $DEFAULT_NAMESPACE)"
    echo "  -m, --module NAME             Module name (default: vastnfs)"
    echo "  -w, --wait SECONDS            Wait for module to be ready (default: no wait)"
    echo ""
    echo "Environment Variables:"
    echo "  NAMESPACE                     Kubernetes namespace"
    echo "  MODULE_NAME                   Module name to verify"
    
    show_common_help_footer
}

check_module_status() {
    print_step "Checking KMM Module Status"
    
    if ! oc get module "$MODULE_NAME" -n "$NAMESPACE" &>/dev/null; then
        print_error "Module '$MODULE_NAME' not found in namespace '$NAMESPACE'"
        return 1
    fi
    
    print_info "Module found: $MODULE_NAME"
    oc get module "$MODULE_NAME" -n "$NAMESPACE" -o wide
    
    # Get detailed status
    local status=$(get_module_status "$MODULE_NAME" "$NAMESPACE")
    if [[ -n "$status" ]]; then
        echo ""
        print_info "Module Status Details:"
        echo "$status" | jq '.' 2>/dev/null || echo "$status"
    fi
    
    return 0
}

check_vast_nfs_active() {
    print_step "Verifying VAST NFS is Active on Nodes"
    
    local nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
    local active_count=0
    local total_count=0
    
    for node in $nodes; do
        total_count=$((total_count + 1))
        print_info "Checking node: $node"
        
        # Check VAST NFS version using the same logic as vastnfs-ctl status
        local version_check=$(oc debug node/$node -- chroot /host bash -c '
            nfs_bundle_git_version=""
            nfs_bundle_version=""
            nfs_bundle_base_git_version=""
            
            if [[ -e /sys/module/sunrpc/parameters/nfs_bundle_version ]] ; then
                nfs_bundle_version=$(cat /sys/module/sunrpc/parameters/nfs_bundle_version)
            elif [[ -e /sys/module/sunrpc/parameters/nfs_bundle_git_version ]] ; then
                nfs_bundle_git_version=$(cat /sys/module/sunrpc/parameters/nfs_bundle_git_version)
            fi
            
            if [[ -e /sys/module/sunrpc/parameters/nfs_bundle_base_git_version ]] ; then
                nfs_bundle_base_git_version=$(cat /sys/module/sunrpc/parameters/nfs_bundle_base_git_version)
            fi
            
            # Output status like vastnfs-ctl status
            if [[ "${nfs_bundle_git_version}" == "" ]] && [[ "${nfs_bundle_version}" == "" ]] ; then
                echo "patched version not running"
            elif [[ "${nfs_bundle_git_version}" != "" ]] ; then
                echo "version: ${nfs_bundle_git_version}"
                if [[ "${nfs_bundle_git_version}" != "${nfs_bundle_base_git_version}" ]] ; then
                    echo "build-version: ${nfs_bundle_base_git_version}"
                fi
            else
                echo "version: ${nfs_bundle_version}"
            fi
        ' 2>/dev/null || echo "check failed")
        
        if [[ "$version_check" == "patched version not running" ]] || [[ "$version_check" == "check failed" ]]; then
            print_warning "VAST NFS NOT ACTIVE - Using default kernel NFS"
        else
            print_success "VAST NFS ACTIVE - $version_check"
            active_count=$((active_count + 1))
        fi
    done
    
    echo ""
    print_info "Summary: $active_count/$total_count nodes have VAST NFS active"
    
    if [[ $active_count -eq 0 ]]; then
        print_error "VAST NFS is not active on any nodes"
        return 1
    elif [[ $active_count -lt $total_count ]]; then
        print_warning "VAST NFS is not active on all nodes"
        return 1
    else
        print_success "VAST NFS is active on all nodes"
        return 0
    fi
}

check_pods() {
    print_step "Checking Pods in Namespace"
    
    local pods=$(oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null || echo "")
    
    if [[ -n "$pods" ]]; then
        print_info "Current pods:"
        oc get pods -n "$NAMESPACE"
        
        echo ""
        print_info "Recent events in namespace:"
        oc get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -5 2>/dev/null || echo "No events found"
    fi
}


check_secure_boot() {
    print_step "Checking Secure Boot Status (if applicable)"
    
    local nodes=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
    local node=$(echo $nodes | awk '{print $1}')
    
    print_info "Checking secure boot status on node: $node"
    
    # Check if modules are signed
    local signature=$(oc debug node/$node -- chroot /host modinfo sunrpc | grep signature 2>/dev/null || echo "")
    
    if [[ -n "$signature" ]]; then
        print_success "Module signature found:"
        echo "  $signature"
    else
        print_info "No module signature found (not using secure boot or unsigned modules)"
    fi
    
    # Check secure boot status
    local sb_state=$(oc debug node/$node -- chroot /host mokutil --sb-state 2>/dev/null || echo "")
    
    if [[ -n "$sb_state" ]]; then
        print_info "Secure boot status: $sb_state"
    else
        print_info "Could not determine secure boot status"
    fi
}

show_troubleshooting() {
    print_step "Troubleshooting Commands"
    echo ""
    echo "If VAST NFS is not working, try these commands:"
    echo ""
    echo "1. Check module logs:"
    echo "   oc logs -l kmm.node.kubernetes.io/module.name=$MODULE_NAME -n $NAMESPACE"
    echo ""
    echo "2. Check KMM operator logs:"
    echo "   oc logs -n openshift-kmm deployment/kmm-operator-controller | grep -i $MODULE_NAME"
    echo ""
    echo "3. Restart module deployment:"
    echo "   oc delete module $MODULE_NAME -n $NAMESPACE"
    echo "   # Then redeploy using make install or scripts"
    echo ""
    echo "4. Check node kernel version compatibility:"
    echo "   oc debug node/<node-name> -- chroot /host uname -r"
    echo ""
}

# Parse command line arguments
WAIT_TIMEOUT=""
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
        -m|--module)
            MODULE_NAME="$2"
            shift 2
            ;;
        -w|--wait)
            WAIT_TIMEOUT="$2"
            shift 2
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
    print_header "VAST NFS Deployment Verification"
    
    check_prerequisites
    check_openshift_login
    
    show_configuration "Verification Configuration" "NAMESPACE" "MODULE_NAME"
    
    # Wait for module if requested
    if [[ -n "$WAIT_TIMEOUT" ]]; then
        wait_for_module_ready "$MODULE_NAME" "$NAMESPACE" "$WAIT_TIMEOUT"
    fi
    
    local overall_status=0
    
    # Run all checks
    check_module_status || overall_status=1
    echo ""
    
    check_vast_nfs_active || overall_status=1
    echo ""
    
    check_pods
    echo ""
    
    echo ""
    
    check_secure_boot
    echo ""
    
    if [[ $overall_status -eq 0 ]]; then
        print_success "✅ VAST NFS deployment verification PASSED"
        print_info "VAST NFS is properly deployed and active"
    else
        print_error "❌ VAST NFS deployment verification FAILED"
        show_troubleshooting
        exit 1
    fi
}

# Run main function
main
