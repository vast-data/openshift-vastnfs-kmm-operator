#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ROLLOUT_PLAN_FILE="${VASTNFS_NODE_PLAN_FILE:-nodes-rollout.txt}"

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Generate an editable node rollout plan for automated rolling install/upgrade."
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -o, --output FILE             Output file path (default: ${ROLLOUT_PLAN_FILE})"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -o|--output)
            ROLLOUT_PLAN_FILE="$2"
            shift 2
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

print_header "Generate Node Rollout Plan"
check_prerequisites
check_openshift_login

nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort)

if [[ -z "${nodes}" ]]; then
    print_error "No cluster nodes found"
    exit 1
fi

{
    echo "# VAST NFS automated rollout node plan"
    echo "#"
    echo "# Edit this file before running automated rollout."
    echo "# - Reorder lines to change processing order."
    echo "# - Remove lines to skip nodes."
    echo "# - Lines starting with # are ignored."
    echo ""
    echo "${nodes}"
} > "${ROLLOUT_PLAN_FILE}"

print_success "Node rollout plan created: ${ROLLOUT_PLAN_FILE}"
print_info "Review and edit node order, then run make rolling-upgrade"
