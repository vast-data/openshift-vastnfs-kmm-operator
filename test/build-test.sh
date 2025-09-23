#!/bin/bash

# Local VAST NFS KMM Build Test Script
# This script simulates the in-cluster build process for testing purposes

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="local/vastnfs-kmm-test"
CONTAINER_ENGINE="podman"  # Change to "docker" if you prefer

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if container engine is available
    if ! command -v $CONTAINER_ENGINE &> /dev/null; then
        print_error "$CONTAINER_ENGINE is not installed or not in PATH"
        exit 1
    fi
    
    # Check if we're on a RHEL-based system (for kernel headers)
    if [ ! -f /etc/redhat-release ]; then
        print_warning "This script is designed for RHEL-based systems"
        print_warning "Kernel headers detection may not work correctly"
    fi
    
    print_success "Prerequisites check passed"
}

# Function to get kernel version
get_kernel_version() {
    KERNEL_VERSION=$(uname -r)
    print_status "Detected kernel version: $KERNEL_VERSION"
    
    # Check if kernel headers are available
    if [ ! -d "/lib/modules/$KERNEL_VERSION/build" ]; then
        print_error "Kernel headers not found at /lib/modules/$KERNEL_VERSION/build"
        print_error "Please install kernel-devel package:"
        print_error "  sudo dnf install kernel-devel-$KERNEL_VERSION"
        exit 1
    fi
    
    print_success "Kernel headers found"
}

# Function to get DTK image
get_dtk_image() {
    print_status "Determining DTK (Driver Toolkit) image..."
    
    # For local testing, we'll use a RHEL UBI image with development tools
    # In a real OpenShift cluster, this would be the actual DTK image
    DTK_IMAGE="registry.redhat.io/ubi9/ubi:latest"
    
    print_status "Using DTK image: $DTK_IMAGE"
    
    # Pull the DTK image
    print_status "Pulling DTK image..."
    if ! $CONTAINER_ENGINE pull $DTK_IMAGE; then
        print_error "Failed to pull DTK image"
        print_error "Make sure you're logged in to registry.redhat.io:"
        print_error "  $CONTAINER_ENGINE login registry.redhat.io"
        exit 1
    fi
    
    print_success "DTK image pulled successfully"
}

# Function to build the image
build_image() {
    print_status "Building VAST NFS KMM image..."
    
    cd "$SCRIPT_DIR"
    
    # Build the image with proper build args
    BUILD_ARGS=(
        "--build-arg" "DTK_AUTO=$DTK_IMAGE"
        "--build-arg" "KERNEL_FULL_VERSION=$KERNEL_VERSION"
        "--tag" "$IMAGE_NAME:$KERNEL_VERSION"
        "--tag" "$IMAGE_NAME:latest"
    )
    
    print_status "Running: $CONTAINER_ENGINE build ${BUILD_ARGS[*]} ."
    
    if $CONTAINER_ENGINE build "${BUILD_ARGS[@]}" .; then
        print_success "Image built successfully!"
        print_success "Image tags:"
        print_success "  - $IMAGE_NAME:$KERNEL_VERSION"
        print_success "  - $IMAGE_NAME:latest"
    else
        print_error "Image build failed!"
        exit 1
    fi
}

# Function to test the built image
test_image() {
    print_status "Testing the built image..."
    
    # Run a simple test to verify the image works
    print_status "Checking image contents..."
    
    if $CONTAINER_ENGINE run --rm "$IMAGE_NAME:latest" ls -la /opt/lib/modules/; then
        print_success "Image test passed - modules directory exists"
    else
        print_warning "Image test failed - modules directory check failed"
    fi
    
    # Check if vastnfs-ctl is available
    print_status "Checking vastnfs-ctl utility..."
    if $CONTAINER_ENGINE run --rm "$IMAGE_NAME:latest" which vastnfs-ctl; then
        print_success "vastnfs-ctl utility found"
    else
        print_warning "vastnfs-ctl utility not found"
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --docker          Use Docker instead of Podman"
    echo "  --no-test         Skip image testing after build"
    echo "  --clean           Remove existing images before building"
    echo "  --help            Show this help message"
    echo ""
    echo "This script builds and tests the VAST NFS KMM image locally"
    echo "to simulate the in-cluster build process."
}

# Function to clean up existing images
cleanup_images() {
    print_status "Cleaning up existing images..."
    
    # Remove existing images
    $CONTAINER_ENGINE rmi "$IMAGE_NAME:latest" 2>/dev/null || true
    $CONTAINER_ENGINE rmi "$IMAGE_NAME:$KERNEL_VERSION" 2>/dev/null || true
    
    print_success "Cleanup completed"
}

# Main execution
main() {
    local skip_test=false
    local clean=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --docker)
                CONTAINER_ENGINE="docker"
                shift
                ;;
            --no-test)
                skip_test=true
                shift
                ;;
            --clean)
                clean=true
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    print_status "Starting VAST NFS KMM local build test..."
    print_status "Using container engine: $CONTAINER_ENGINE"
    
    # Clean up if requested
    if [ "$clean" = true ]; then
        cleanup_images
    fi
    
    # Run the build process
    check_prerequisites
    get_kernel_version
    get_dtk_image
    build_image
    
    # Test the image if not skipped
    if [ "$skip_test" = false ]; then
        test_image
    fi
    
    print_success "Local build test completed successfully!"
    print_status "You can now push this image to your registry and update the KMM configuration"
    print_status ""
    print_status "Next steps:"
    print_status "1. Tag for your registry: $CONTAINER_ENGINE tag $IMAGE_NAME:latest your-registry.com/vastnfs-kmm:$KERNEL_VERSION"
    print_status "2. Push to registry: $CONTAINER_ENGINE push your-registry.com/vastnfs-kmm:$KERNEL_VERSION"
    print_status "3. Update k8s/base/vastnfs.module.yaml with the new image reference"
}

# Run main function
main "$@"


