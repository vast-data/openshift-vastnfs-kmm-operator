#!/bin/bash

# Common functions and utilities for VAST NFS KMM scripts
# This file should be sourced by other scripts, not executed directly

# Exit if sourced incorrectly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script should be sourced, not executed directly"
    echo "Usage: source scripts/common.sh"
    exit 1
fi

# Color codes for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

# Common configuration defaults
export DEFAULT_NAMESPACE="vastnfs-kmm"
export DEFAULT_VASTNFS_VERSION="4.0.35"
export DEFAULT_KEYS_DIR="keys"
export DEFAULT_KEY_NAME="vastnfs_signing_key"
export DEFAULT_CERT_VALIDITY_DAYS="36500"

# Signing secrets defaults
export DEFAULT_SIGNING_KEY_SECRET="vastnfs-signing-key"
export DEFAULT_SIGNING_CERT_SECRET="vastnfs-signing-cert"
export DEFAULT_IMAGE_REPO_SECRET="vastnfs-registry-secret"

# Image configuration defaults
export DEFAULT_KMM_IMG_REPO="image-registry.openshift-image-registry.svc:5000/vastnfs-kmm/vastnfs"

# Print functions with consistent formatting
print_header() {
    local title="$1"
    echo -e "${BLUE}"
    echo "================================================================="
    echo "  $title"
    echo "================================================================="
    echo -e "${NC}"
}

print_step() {
    echo -e "${GREEN}[STEP]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Utility functions
check_command() {
    local cmd="$1"
    local install_msg="$2"
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        print_error "$cmd not found"
        if [[ -n "$install_msg" ]]; then
            echo "$install_msg"
        fi
        return 1
    fi
    return 0
}

check_openshift_login() {
    print_step "Checking OpenShift connection..."
    
    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift cluster"
        echo "Please run: oc login --server=https://your-cluster-api:6443"
        return 1
    fi
    
    local user=$(oc whoami)
    local server=$(oc whoami --show-server)
    print_info "Connected as: $user"
    print_info "Cluster: $server"
    return 0
}

check_prerequisites() {
    print_step "Checking prerequisites..."
    
    local failed=0
    
    # Check OpenShift CLI
    if ! check_command "oc" "Please install the OpenShift CLI (oc)"; then
        failed=1
    fi
    
    # Check kustomize
    if ! check_command "kustomize" "Please install kustomize or run: make install-kustomize"; then
        failed=1
    fi
    
    # Check envsubst
    if ! check_command "envsubst" "Please install gettext package:
  - RHEL/CentOS: sudo dnf install gettext
  - Ubuntu/Debian: sudo apt install gettext-base
  - macOS: brew install gettext"; then
        failed=1
    fi
    
    if [[ $failed -eq 1 ]]; then
        return 1
    fi
    
    print_info "All prerequisites met"
    return 0
}

check_openssl() {
    print_step "Checking OpenSSL..."
    
    if ! check_command "openssl" "Please install OpenSSL:
  - RHEL/CentOS: sudo dnf install openssl
  - Ubuntu/Debian: sudo apt install openssl
  - macOS: brew install openssl"; then
        return 1
    fi
    
    print_info "OpenSSL available: $(openssl version)"
    return 0
}

# Kubernetes/OpenShift utility functions
create_namespace_if_not_exists() {
    local namespace="$1"
    
    if ! oc get namespace "$namespace" &>/dev/null; then
        print_step "Creating namespace: $namespace"
        oc create namespace "$namespace"
        print_info "Created namespace: $namespace"
    else
        print_info "Namespace $namespace already exists"
    fi
}

check_secret_exists() {
    local secret_name="$1"
    local namespace="$2"
    
    oc get secret "$secret_name" -n "$namespace" &>/dev/null
}

create_secret_from_file() {
    local secret_name="$1"
    local namespace="$2"
    local key_name="$3"
    local file_path="$4"
    local overwrite="${5:-false}"
    
    if check_secret_exists "$secret_name" "$namespace"; then
        if [[ "$overwrite" == "true" ]]; then
            print_warning "Secret $secret_name already exists, overwriting..."
            oc delete secret "$secret_name" -n "$namespace"
        else
            print_warning "Secret $secret_name already exists, skipping creation"
            return 0
        fi
    fi
    
    oc create secret generic "$secret_name" \
        --from-file="$key_name=$file_path" \
        -n "$namespace"
    
    print_info "Created secret: $secret_name"
}

verify_secret_content() {
    local secret_name="$1"
    local namespace="$2"
    local key_name="$3"
    local validation_cmd="$4"
    
    print_step "Verifying secret: $secret_name"
    
    if oc get secret "$secret_name" -n "$namespace" -o yaml | \
       awk "/$key_name:/{print \$2; exit}" | base64 -d | \
       eval "$validation_cmd" >/dev/null 2>&1; then
        print_info "Secret $secret_name is valid"
        return 0
    else
        print_error "Secret $secret_name is invalid"
        return 1
    fi
}

# File and directory utilities
ensure_directory() {
    local dir="$1"
    local permissions="${2:-755}"
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        chmod "$permissions" "$dir"
        print_info "Created directory: $dir"
    fi
}

check_file_exists() {
    local file="$1"
    local description="${2:-file}"
    
    if [[ ! -f "$file" ]]; then
        print_error "$description not found: $file"
        return 1
    fi
    return 0
}

set_file_permissions() {
    local file="$1"
    local permissions="$2"
    
    chmod "$permissions" "$file"
    print_info "Set permissions $permissions on: $file"
}

# Configuration and validation
validate_required_vars() {
    local vars=("$@")
    local missing=()
    
    for var in "${vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing+=("$var")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing required environment variables:"
        for var in "${missing[@]}"; do
            echo "  - $var"
        done
        return 1
    fi
    
    return 0
}

show_configuration() {
    local title="$1"
    shift
    local vars=("$@")
    
    print_step "$title"
    for var in "${vars[@]}"; do
        echo "  $var: ${!var}"
    done
    echo ""
}

# Help and usage functions
show_common_help_footer() {
    echo ""
    echo "Common Environment Variables:"
    echo "  NAMESPACE                     Kubernetes namespace (default: $DEFAULT_NAMESPACE)"
    echo "  VASTNFS_VERSION               VAST NFS version (default: $DEFAULT_VASTNFS_VERSION)"
    echo ""
    echo "For more help, see the documentation in the project repository."
}

# Cleanup functions
cleanup_temp_files() {
    local files=("$@")
    
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            print_info "Cleaned up temporary file: $file"
        fi
    done
}

cleanup_temp_dirs() {
    local dirs=("$@")
    
    for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            print_info "Cleaned up temporary directory: $dir"
        fi
    done
}

# Signal handlers for cleanup
setup_cleanup_trap() {
    local cleanup_function="$1"
    trap "$cleanup_function" EXIT INT TERM
}

# Version and compatibility checks
check_openshift_version() {
    local min_version="${1:-4.12}"
    
    if ! oc version --client=false >/dev/null 2>&1; then
        print_warning "Could not determine OpenShift version"
        return 0
    fi
    
    # This is a simplified check - in practice you might want more sophisticated version comparison
    print_info "OpenShift cluster accessible"
    return 0
}

# Module and deployment utilities
get_module_status() {
    local module_name="$1"
    local namespace="$2"
    
    oc get module "$module_name" -n "$namespace" -o jsonpath='{.status.moduleLoader}' 2>/dev/null
}

wait_for_module_ready() {
    local module_name="$1"
    local namespace="$2"
    local timeout="${3:-300}"
    
    print_step "Waiting for module $module_name to be ready (timeout: ${timeout}s)..."
    
    local count=0
    while [[ $count -lt $timeout ]]; do
        local status=$(get_module_status "$module_name" "$namespace")
        if [[ -n "$status" ]]; then
            local available=$(echo "$status" | jq -r '.availableNumber // 0' 2>/dev/null)
            local desired=$(echo "$status" | jq -r '.desiredNumber // 0' 2>/dev/null)
            
            if [[ "$available" == "$desired" ]] && [[ "$available" -gt 0 ]]; then
                print_success "Module $module_name is ready"
                return 0
            fi
        fi
        
        sleep 5
        count=$((count + 5))
    done
    
    print_error "Module $module_name did not become ready within ${timeout}s"
    return 1
}

# Export all functions for use in other scripts
export -f print_header print_step print_info print_warning print_error print_success
export -f check_command check_openshift_login check_prerequisites check_openssl
export -f create_namespace_if_not_exists check_secret_exists create_secret_from_file verify_secret_content
export -f ensure_directory check_file_exists set_file_permissions
export -f validate_required_vars show_configuration show_common_help_footer
export -f cleanup_temp_files cleanup_temp_dirs setup_cleanup_trap
export -f check_openshift_version get_module_status wait_for_module_ready

# Indicate that common.sh has been loaded
export COMMON_SH_LOADED=1