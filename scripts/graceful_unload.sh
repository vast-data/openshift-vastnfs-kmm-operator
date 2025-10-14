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

# Get all nodes
nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')

print_step "Unloading VAST NFS modules from cluster nodes"

for node in $nodes; do
    print_info "Processing node: $node"
    
    # Run the unload sequence in a debug pod
    oc debug node/$node -- chroot /host bash -c '
        echo "Checking VAST NFS status..."
        
        # Check if VAST NFS is loaded
        if [[ ! -e /sys/module/sunrpc/parameters/nfs_bundle_version ]] && \
           [[ ! -e /sys/module/sunrpc/parameters/nfs_bundle_git_version ]]; then
            echo "VAST NFS modules not loaded, nothing to do"
            exit 0
        fi
        
        echo "VAST NFS is loaded, proceeding with graceful unload..."
        
        # 1. Unmount all NFS filesystems
        echo "Unmounting NFS filesystems..."
        umount -a -t nfs4 2>/dev/null || true
        umount -a -t nfs 2>/dev/null || true
        
        # 2. Stop RPC services (but preserve rpcbind.socket)
        echo "Stopping RPC services..."
        systemctl stop rpc-gssd 2>/dev/null || true
        
        # Only stop rpcbind if rpcbind.socket doesn'\''t exist
        if ! systemctl is-active rpcbind.socket >/dev/null 2>&1; then
            systemctl stop rpcbind 2>/dev/null || true
        fi
        
        # 3. Unmount rpc_pipefs
        echo "Unmounting rpc_pipefs..."
        for path in /var/lib/nfs/rpc_pipefs /run/rpc_pipefs; do
            if grep -q "${path} rpc_pipefs" /proc/mounts 2>/dev/null; then
                umount ${path} 2>/dev/null || true
            fi
        done
        
        # 4. Unload modules in reverse order
        echo "Unloading NFS kernel modules..."
        for mod in nfsv4 nfsv3 nfs nfsd rpcsec_gss_krb5 auth_rpcgss nfs_acl lockd nfs_ssc compat_nfs_ssc rpcrdma sunrpc; do
            if [[ -d /sys/module/${mod} ]]; then
                echo "  Unloading ${mod}..."
                
                # Special handling for sunrpc - drop caches first
                if [[ "${mod}" == "sunrpc" ]]; then
                    echo 2 > /proc/sys/vm/drop_caches
                    sleep 1
                fi
                
                rmmod ${mod} 2>/dev/null || true
            fi
        done
        
        echo "Module unload complete"
    ' 2>&1 | sed 's/^/  /'
    
    if [ $? -eq 0 ]; then
        print_success "Successfully unloaded modules from node: $node"
    else
        print_warning "Some errors occurred on node: $node (may be expected)"
    fi
    echo ""
done

print_success "Graceful unload complete"
print_info "You can now run 'make uninstall' safely"

