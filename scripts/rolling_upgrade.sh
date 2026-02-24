#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

NAMESPACE="${NAMESPACE:-vastnfs-kmm}"
VASTNFS_VERSION="${VASTNFS_VERSION:-4.0.35}"
MODULE_NAME="${MODULE_NAME:-vastnfs}"
ROLLOUT_PLAN_FILE="${VASTNFS_NODE_PLAN_FILE:-nodes-rollout.txt}"
AUTOMATED_ROLLING="${VASTNFS_AUTOMATED_ROLLING:-false}"
INTER_NODE_WAIT_SECONDS="${VASTNFS_INTER_NODE_WAIT_SECONDS:-300}"
NODE_RELOAD_TIMEOUT_SECONDS="${VASTNFS_NODE_RELOAD_TIMEOUT_SECONDS:-900}"
DRY_RUN=false
PLAN_NODES=()

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Run one-node-at-a-time VAST NFS automated rolling upgrade/install."
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -p, --plan FILE               Node plan file (default: ${ROLLOUT_PLAN_FILE})"
    echo "  --dry-run                     Validate and print actions without changing nodes"
    echo ""
    echo "Required Environment Variables:"
    echo "  VASTNFS_AUTOMATED_ROLLING     Must be set to true or 1"
    echo ""
    echo "Optional Environment Variables:"
    echo "  VASTNFS_INTER_NODE_WAIT_SECONDS   Wait time between nodes (default: ${INTER_NODE_WAIT_SECONDS})"
    echo "  VASTNFS_NODE_RELOAD_TIMEOUT_SECONDS Timeout waiting for node module reload (default: ${NODE_RELOAD_TIMEOUT_SECONDS})"
    echo "  NAMESPACE                         Namespace for verification (default: ${NAMESPACE})"
    echo "  VASTNFS_VERSION                   Expected VAST NFS version (default: ${VASTNFS_VERSION})"
}

is_true() {
    local value="$1"
    [[ "${value}" == "true" || "${value}" == "1" || "${value}" == "TRUE" || "${value}" == "True" ]]
}

validate_node_plan() {
    local plan_file="$1"
    local line
    if [[ ! -f "${plan_file}" ]]; then
        print_error "Node plan file not found: ${plan_file}"
        print_info "Run make generate-node-rollout-plan first"
        return 1
    fi

    PLAN_NODES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if printf '%s\n' "$line" | grep -Eq '^[[:space:]]*($|#)'; then
            continue
        fi
        PLAN_NODES+=("$line")
    done < "${plan_file}"

    if [[ "${#PLAN_NODES[@]}" -eq 0 ]]; then
        print_error "Node plan file has no nodes: ${plan_file}"
        return 1
    fi

    for node in "${PLAN_NODES[@]}"; do
        if ! oc get node "${node}" >/dev/null 2>&1; then
            print_error "Node in plan does not exist in cluster: ${node}"
            return 1
        fi
    done
}

run_node_cleanup() {
    local node="$1"
    "${SCRIPT_DIR}/graceful_unload.sh" --node "${node}"
}

restore_rpc_services() {
    local node="$1"
    print_step "Restoring RPC services on node: ${node}"
    oc debug "node/${node}" -- chroot /host /bin/sh -c "systemctl start rpcbind rpc-statd gssproxy"
}

wait_for_node_module_reload() {
    local node="$1"
    local timeout="$2"
    local elapsed=0
    local interval=10
    local node_version=""

    print_step "Waiting for node module reload: ${node} (timeout: ${timeout}s)"

    while [[ "${elapsed}" -lt "${timeout}" ]]; do
        node_version="$(oc debug "node/${node}" -- chroot /host /bin/sh -c '
            if [ -e /sys/module/sunrpc/parameters/nfs_bundle_version ]; then
                cat /sys/module/sunrpc/parameters/nfs_bundle_version
            elif [ -e /sys/module/sunrpc/parameters/nfs_bundle_git_version ]; then
                cat /sys/module/sunrpc/parameters/nfs_bundle_git_version
            fi
        ' 2>/dev/null | tr -d '\r' | awk "NF {print; exit}")"

        if [[ "${node_version}" == "${VASTNFS_VERSION}" ]]; then
            print_success "Node ${node} module reload completed (version: ${node_version})"
            return 0
        fi

        print_info "Node ${node} still reloading (current: ${node_version:-unknown}, expected: ${VASTNFS_VERSION}, elapsed: ${elapsed}s)"
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    print_error "Timed out waiting for node ${node} to reload module version ${VASTNFS_VERSION}"
    return 1
}

verify_node() {
    local node="$1"
    print_step "Verifying node upgrade state: ${node}"
    "${SCRIPT_DIR}/verify_deployment.sh" --namespace "${NAMESPACE}" --module "${MODULE_NAME}" --node "${node}" --expected-version "${VASTNFS_VERSION}"
}

process_node() {
    local node="$1"
    print_header "Processing node ${node}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        print_info "[DRY-RUN] oc adm cordon ${node}"
        print_info "[DRY-RUN] oc adm drain ${node} --ignore-daemonsets --delete-emptydir-data --force"
        print_info "[DRY-RUN] graceful unload on ${node}"
        print_info "[DRY-RUN] oc adm uncordon ${node}"
        print_info "[DRY-RUN] wait for node ${node} module version ${VASTNFS_VERSION} (timeout ${NODE_RELOAD_TIMEOUT_SECONDS}s)"
        print_info "[DRY-RUN] oc debug node/${node} -- chroot /host /bin/sh -c \"systemctl start rpcbind rpc-statd gssproxy\""
        print_info "[DRY-RUN] verify node ${node}"
        return 0
    fi

    print_step "Cordoning node: ${node}"
    oc adm cordon "${node}"

    print_step "Draining node: ${node}"
    oc adm drain "${node}" --ignore-daemonsets --delete-emptydir-data --force

    print_step "Cleaning old VAST NFS modules on node: ${node}"
    run_node_cleanup "${node}"

    print_step "Uncordoning node: ${node}"
    oc adm uncordon "${node}"

    wait_for_node_module_reload "${node}" "${NODE_RELOAD_TIMEOUT_SECONDS}"
    restore_rpc_services "${node}"

    verify_node "${node}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--plan)
            ROLLOUT_PLAN_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

print_header "VAST NFS Node-by-Node Rolling Upgrade"
check_prerequisites
check_openshift_login

if ! is_true "${AUTOMATED_ROLLING}"; then
    print_error "Automation gate is disabled. Set VASTNFS_AUTOMATED_ROLLING=true to proceed."
    exit 1
fi

if ! [[ "${INTER_NODE_WAIT_SECONDS}" =~ ^[0-9]+$ ]]; then
    print_error "VASTNFS_INTER_NODE_WAIT_SECONDS must be an integer, got: ${INTER_NODE_WAIT_SECONDS}"
    exit 1
fi

if ! [[ "${NODE_RELOAD_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]]; then
    print_error "VASTNFS_NODE_RELOAD_TIMEOUT_SECONDS must be an integer, got: ${NODE_RELOAD_TIMEOUT_SECONDS}"
    exit 1
fi

validate_node_plan "${ROLLOUT_PLAN_FILE}"

print_step "Using node rollout plan: ${ROLLOUT_PLAN_FILE}"
print_info "Nodes in order: ${PLAN_NODES[*]}"
print_info "Inter-node wait: ${INTER_NODE_WAIT_SECONDS}s"

for i in "${!PLAN_NODES[@]}"; do
    node="${PLAN_NODES[$i]}"
    process_node "${node}"

    if [[ "${i}" -lt "$(( ${#PLAN_NODES[@]} - 1 ))" ]]; then
        print_info "Waiting ${INTER_NODE_WAIT_SECONDS}s before next node..."
        if [[ "${DRY_RUN}" == "true" ]]; then
            print_info "[DRY-RUN] sleep ${INTER_NODE_WAIT_SECONDS}"
        else
            sleep "${INTER_NODE_WAIT_SECONDS}"
        fi
    fi
done

print_step "Running final cluster-wide verification"
"${SCRIPT_DIR}/verify_deployment.sh" --namespace "${NAMESPACE}" --module "${MODULE_NAME}" --expected-version "${VASTNFS_VERSION}"

print_success "Automated rolling upgrade finished for ${#PLAN_NODES[@]} node(s)"
