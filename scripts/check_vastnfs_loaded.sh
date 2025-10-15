#!/bin/bash

# Check if VAST NFS is currently loaded on any cluster node
# Returns: 0 if loaded, 1 if not loaded

# Get all nodes
nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [ -z "$nodes" ]; then
    exit 1  # No nodes found, assume not loaded
fi

# Check each node for VAST NFS
for node in $nodes; do
    # Check if VAST NFS is loaded on this node
    # Filter out debug pod messages and extract only LOADED/NOT_LOADED
    result=$(oc debug node/$node -- chroot /host bash -c '
        if [[ -e /sys/module/sunrpc/parameters/nfs_bundle_version ]] || \
           [[ -e /sys/module/sunrpc/parameters/nfs_bundle_git_version ]]; then
            echo "VASTNFS_LOADED"
        else
            echo "VASTNFS_NOT_LOADED"
        fi
    ' 2>&1 | grep "VASTNFS_" | head -1)
    
    if [[ "$result" == "VASTNFS_LOADED" ]]; then
        exit 0  # VAST NFS is loaded
    fi
done

exit 1  # VAST NFS is not loaded on any node

