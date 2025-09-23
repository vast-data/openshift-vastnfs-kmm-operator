#!/bin/bash

# Generate Secure Boot Keys for VAST NFS Kernel Module Signing
# This script creates a public/private key pair for signing kernel modules

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Default configuration (using common.sh defaults)
KEYS_DIR=${KEYS_DIR:-$DEFAULT_KEYS_DIR}
KEY_NAME=${KEY_NAME:-$DEFAULT_KEY_NAME}
CERT_VALIDITY_DAYS=${CERT_VALIDITY_DAYS:-$DEFAULT_CERT_VALIDITY_DAYS}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Generate secure boot keys for VAST NFS kernel module signing"
    echo ""
    echo "Options:"
    echo "  -h, --help                    Show this help message"
    echo "  -d, --keys-dir DIR            Keys output directory (default: keys)"
    echo "  -n, --key-name NAME           Key name prefix (default: vastnfs_signing_key)"
    echo "  -v, --validity DAYS           Certificate validity in days (default: 36500)"
    echo "  -f, --force                   Overwrite existing keys"
    echo ""
    echo "Environment Variables:"
    echo "  KEYS_DIR                      Keys output directory"
    echo "  KEY_NAME                      Key name prefix"
    echo "  CERT_VALIDITY_DAYS            Certificate validity in days"
    echo ""
    echo "Examples:"
    echo "  $0                            # Generate keys in ./keys/"
    echo "  $0 -d /secure/keys            # Generate in custom directory"
    echo "  $0 -n production_key -v 3650  # Custom name and 10-year validity"
    
    show_common_help_footer
}

create_cert_config() {
    local config_file="$1"
    
    print_step "Creating certificate configuration..."
    
    cat > "$config_file" << 'EOF'
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = VAST NFS Kernel Module Signing Key
O = VAST Data
OU = Engineering
C = US

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
subjectKeyIdentifier = hash
EOF
    
    print_info "Certificate configuration created"
}

generate_keys() {
    local keys_dir="$1"
    local key_name="$2"
    local validity_days="$3"
    local force="$4"
    
    local private_key="${keys_dir}/${key_name}.priv"
    local public_cert="${keys_dir}/${key_name}.der"
    local config_file="${keys_dir}/cert.config"
    
    # Check if keys already exist
    if [[ -f "$private_key" || -f "$public_cert" ]] && [[ "$force" != "true" ]]; then
        print_warning "Keys already exist:"
        [[ -f "$private_key" ]] && echo "  Private Key: $private_key"
        [[ -f "$public_cert" ]] && echo "  Public Cert: $public_cert"
        echo ""
        echo "Use --force to overwrite existing keys"
        exit 1
    fi
    
    print_step "Generating secure boot keys..."
    
    # Create keys directory
    ensure_directory "$keys_dir" 700
    
    # Create certificate configuration
    create_cert_config "$config_file"
    
    # Generate keys
    print_info "Generating public/private key pair..."
    openssl req -x509 -new -nodes -utf8 -sha256 -days "$validity_days" -batch \
        -config "$config_file" \
        -outform DER -out "$public_cert" \
        -keyout "$private_key"
    
    # Set appropriate permissions
    set_file_permissions "$private_key" 600
    set_file_permissions "$public_cert" 644
    
    # Clean up config file
    cleanup_temp_files "$config_file"
    
    print_success "Keys generated successfully!"
}

show_results() {
    local keys_dir="$1"
    local key_name="$2"
    
    local private_key="${keys_dir}/${key_name}.priv"
    local public_cert="${keys_dir}/${key_name}.der"
    
    print_success "Key Generation Complete!"
    echo ""
    print_info "Keys Location: $keys_dir"
    print_info "Private Key: $private_key"
    print_info "Public Cert: $public_cert"
    echo ""
    
    # Show key details
    print_info "Certificate Details:"
    openssl x509 -inform der -in "$public_cert" -text -noout | grep -E "(Subject:|Not Before|Not After)" | sed 's/^/  /'
    echo ""
    
    print_warning "IMPORTANT SECURITY NOTES:"
    echo "1. Keep the private key secure and limit access"
    echo "2. The public key must be enrolled in the MOK database on secure boot nodes"
    echo "3. Backup both keys securely"
    echo "4. Plan for key rotation in production environments"
    echo ""
    
    print_step "Next Steps:"
    echo "1. Enroll public key in secure boot nodes:"
    echo "   mokutil --import $public_cert"
    echo ""
    echo "2. Use keys for VAST NFS deployment:"
    echo "   PRIVATE_KEY_FILE=$private_key \\"
    echo "   PUBLIC_CERT_FILE=$public_cert \\"
    echo "   make install-secure-boot-with-keys"
    echo ""
    echo "   Or:"
    echo "   ./scripts/install_with_secure_boot.sh -k $private_key -c $public_cert"
    echo ""
}

# Parse command line arguments
FORCE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -d|--keys-dir)
            KEYS_DIR="$2"
            shift 2
            ;;
        -n|--key-name)
            KEY_NAME="$2"
            shift 2
            ;;
        -v|--validity)
            CERT_VALIDITY_DAYS="$2"
            shift 2
            ;;
        -f|--force)
            FORCE=true
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
    print_header "VAST NFS Secure Boot Key Generation"
    check_openssl
    generate_keys "$KEYS_DIR" "$KEY_NAME" "$CERT_VALIDITY_DAYS" "$FORCE"
    show_results "$KEYS_DIR" "$KEY_NAME"
}

# Run main function
main
