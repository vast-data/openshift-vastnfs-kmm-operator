#!/bin/bash

# Gracefully unload VAST NFS modules from cluster nodes
# This should be run before 'make uninstall' to avoid stuck pods

set -e

# Import common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

print_header "VAST NFS Graceful Module Unload"

check_prerequisites
check_openshift_login

TARGET_NODE=""

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Gracefully unload VAST NFS modules from cluster nodes"
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  --node NODE_NAME              Process only a single node"
    echo ""
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --node)
            TARGET_NODE="$2"
            shift 2
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

unload_node_modules() {
    local node="$1"

    print_info "Processing node: $node"
    
    # Run the unload sequence in a debug pod
    oc debug node/$node -- chroot /host bash -c '
        echo "Checking VAST NFS status..."
        
        echo "Proceeding with graceful unload (module-state based)..."
        
        # 1. Unmount all NFS filesystems
        echo "Unmounting NFS filesystems..."
        umount -a -t nfs,nfs4 -f -l 2>/dev/null || true
        
        # 2. Stop RPC related services
        echo "Stopping RPC services..."
        systemctl stop rpcbind.socket rpcbind.service rpc-statd.service gssproxy.service rpc-gssd.service 2>/dev/null || true
        
        # 3. Unmount rpc_pipefs
        echo "Unmounting rpc_pipefs..."
        for path in /var/lib/nfs/rpc_pipefs /run/rpc_pipefs; do
            if grep -q "${path} rpc_pipefs" /proc/mounts 2>/dev/null; then
                umount ${path} 2>/dev/null || true
            fi
        done
        
        is_module_loaded() {
            local mod="$1"
            [[ -d "/sys/module/${mod}" ]]
        }

        unload_module_smart() {
            local mod="$1"
            local max_attempts=12
            local attempt=1
            local out=""
            local rc=0

            if ! is_module_loaded "${mod}"; then
                echo "  ${mod}: already not loaded"
                return 0
            fi

            while [[ ${attempt} -le ${max_attempts} ]]; do
                out="$(rmmod "${mod}" 2>&1)"
                rc=$?

                if [[ ${rc} -eq 0 ]]; then
                    echo "  ${mod}: unloaded"
                    return 0
                fi

                if echo "${out}" | grep -q "is not currently loaded"; then
                    echo "  ${mod}: already not loaded"
                    return 0
                fi

                if echo "${out}" | grep -q "builtin"; then
                    echo "  ${mod}: builtin, skipping"
                    return 0
                fi

                # Dependency release can lag behind during drain/unmount/service stop.
                echo "  ${mod}: attempt ${attempt}/${max_attempts} failed: ${out}"
                sleep 1

                if ! is_module_loaded "${mod}"; then
                    echo "  ${mod}: unloaded (confirmed by module state)"
                    return 0
                fi

                attempt=$((attempt + 1))
            done

            if is_module_loaded "${mod}"; then
                echo "  ${mod}: still loaded after ${max_attempts} attempts"
                return 1
            fi

            return 0
        }

        # 4. Unload modules in reverse order
        echo "Unloading NFS kernel modules..."
        for mod in nfsv4 nfsv3 nfs nfsd rpcsec_gss_krb5 auth_rpcgss nfs_acl lockd nfs_ssc compat_nfs_ssc rpcrdma sunrpc; do
            echo "  Processing ${mod}..."

            # Special handling for sunrpc - drop caches first
            if [[ "${mod}" == "sunrpc" ]]; then
                echo 2 > /proc/sys/vm/drop_caches 2>/dev/null || true
                sleep 1
            fi

            unload_module_smart "${mod}" || true
        done
        
        echo "Module unload complete"
    ' 2>&1 | sed 's/^/  /'
    
    if [ $? -eq 0 ]; then
        print_success "Successfully unloaded modules from node: $node"
    else
        print_warning "Some errors occurred on node: $node (may be expected)"
    fi
    echo ""
}

if [[ -n "$TARGET_NODE" ]]; then
    nodes="$TARGET_NODE"
else
    nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
fi

print_step "Unloading VAST NFS modules from cluster nodes"

for node in $nodes; do
    unload_node_modules "$node"
done

print_success "Graceful unload complete"
print_info "You can now run 'make uninstall' safely"

