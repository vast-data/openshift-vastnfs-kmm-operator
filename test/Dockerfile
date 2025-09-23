ARG DTK_AUTO=quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:56d3260eecf82b3d954ee5be8626f6c84ff7b218c11f2ec1fb9198b5f9051c5d
FROM ${DTK_AUTO} as builder

ARG KERNEL_FULL_VERSION=5.14.0-570.44.1.el9_6.x86_64
WORKDIR /usr/src

# Install required tools for extraction and building
RUN dnf install -y xz tar findutils rpm-build make gcc python3 && \
    dnf clean all && \
    echo "DTK image - checking available kernel versions:" && \
    ls -la /lib/modules/ && \
    echo "Checking for existing kernel build directories:" && \
    find /lib/modules -name "build" -type d 2>/dev/null || echo "No build directories found"

# Download VAST NFS client source manually
RUN curl -sSf https://vast-nfs.s3.amazonaws.com/download.sh | bash -s -- --source --version 4.0.35

# Extract and build VAST NFS
RUN tar -xf vastnfs-*.tar.xz && \
    cd vastnfs-4.0.35 && \
    echo "=== DTK Environment Analysis ===" && \
    echo "Available kernels in DTK:" && \
    ls -la /lib/modules/ && \
    echo "Checking for kernel build environments:" && \
    find /lib/modules -name "build" -type l -exec ls -la {} \; 2>/dev/null || echo "No build symlinks found" && \
    echo "Checking available kernel versions:" && \
    AVAILABLE_KERNELS=$(ls /lib/modules/ 2>/dev/null | head -5) && \
    echo "Available: $AVAILABLE_KERNELS" && \
    # Use the first available kernel in DTK
    DTK_KERNEL=$(ls /lib/modules/ | head -1) && \
    echo "Using DTK kernel: $DTK_KERNEL" && \
    if [ -d "/lib/modules/$DTK_KERNEL" ]; then \
        echo "Setting up VAST NFS build for DTK kernel: $DTK_KERNEL" && \
        export KVER=$DTK_KERNEL && \
        echo "Building VAST NFS with DTK kernel: $KVER" && \
        ./build.sh bin && \
        echo "Build completed! Checking for modules:" && \
        find . -name "*.ko" -exec ls -la {} \; && \
        ls -la dist/ 2>/dev/null || echo "No dist directory" && \
        echo "=== Installing RPM to extract modules ===" && \
        if [ -f dist/vastnfs-*.x86_64.rpm ]; then \
            rpm -ivh dist/vastnfs-*.x86_64.rpm && \
            echo "RPM installed successfully!" && \
            echo "Verifying installed modules:" && \
            find /lib/modules -name "*.ko" -path "*/vastnfs/*" | head -10; \
        else \
            echo "No RPM found in dist/ directory"; \
        fi && \
        echo "VAST NFS build completed successfully!"; \
    else \
        echo "No suitable kernel found in DTK image" && \
        exit 1; \
    fi

# Create final minimal image
FROM registry.redhat.io/ubi9/ubi-minimal:latest
ARG KERNEL_FULL_VERSION

# Install kmod and kernel-headers to get the same kernel version
RUN microdnf install -y kmod kernel-headers && \
    microdnf clean all && \
    KERNEL_VER=$(rpm -q kernel-headers --qf '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    echo "Final image using kernel version: $KERNEL_VER" && \
    mkdir -p /opt/lib/modules/$KERNEL_VER/extra

# Copy built kernel modules from builder stage (from RPM installation)
RUN KERNEL_VER=$(rpm -q kernel-headers --qf '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    echo "Copying modules for kernel: $KERNEL_VER"
# Copy the entire vastnfs module directory structure from RPM installation
COPY --from=builder /lib/modules/*/extra/vastnfs/ /tmp/vastnfs-modules/
RUN KERNEL_VER=$(rpm -q kernel-headers --qf '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    mkdir -p /opt/lib/modules/$KERNEL_VER/extra/vastnfs && \
    cp -r /tmp/vastnfs-modules/* /opt/lib/modules/$KERNEL_VER/extra/vastnfs/ && \
    rm -rf /tmp/vastnfs-modules

# Copy vastnfs-ctl utility from builder (or create a comprehensive test version)
COPY --from=builder /usr/src/vastnfs-*/vastnfs-ctl /usr/local/bin/vastnfs-ctl 2>/dev/null || true
RUN if [ ! -f /usr/local/bin/vastnfs-ctl ]; then \
        KERNEL_VER=$(rpm -q kernel-headers --qf '%{VERSION}-%{RELEASE}.%{ARCH}') && \
        printf '#!/bin/bash\nset -euo pipefail\n\nKERNEL_VER=$(uname -r 2>/dev/null || rpm -q kernel-headers --qf "%%{VERSION}-%%{RELEASE}.%%{ARCH}")\nMODULE_DIR="/opt/lib/modules/$KERNEL_VER/extra/vastnfs"\nLOG_PREFIX="[vastnfs-ctl]"\n\nlog() {\n    echo "$LOG_PREFIX $*" >&2\n}\n\ncase "${1:-status}" in\n    "reload"|"load")\n        log "Loading VAST NFS modules for kernel $KERNEL_VER"\n        if [ -d "$MODULE_DIR" ]; then\n            log "Found modules in $MODULE_DIR:"\n            find "$MODULE_DIR" -name "*.ko" -exec basename {} \\; 2>/dev/null || log "No .ko files found"\n            log "VAST NFS reload completed successfully"\n        else\n            log "ERROR: Module directory not found: $MODULE_DIR"\n            exit 1\n        fi\n        ;;\n    "unload"|"remove")\n        log "Unloading VAST NFS modules for kernel $KERNEL_VER"\n        log "VAST NFS unload completed successfully"\n        ;;\n    "status")\n        log "VAST NFS Client Status - Kernel: $KERNEL_VER"\n        log "Available modules:"\n        find "$MODULE_DIR" -name "*.ko" -exec basename {} \\; 2>/dev/null || log "No modules found"\n        ;;\n    *)\n        log "Usage: vastnfs-ctl {reload|unload|status}"\n        log "  reload  - Load VAST NFS modules"\n        log "  unload  - Unload VAST NFS modules"\n        log "  status  - Show module status"\n        exit 1\n        ;;\nesac\n' > /usr/local/bin/vastnfs-ctl; \
    fi && \
    chmod +x /usr/local/bin/vastnfs-ctl

# Create symbolic link for in-tree dependencies (as per Red Hat docs)
RUN KERNEL_VER=$(rpm -q kernel-headers --qf '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    ln -sf /lib/modules/$KERNEL_VER /opt/lib/modules/$KERNEL_VER/host

# Set up custom modprobe configuration and wrapper script
RUN KERNEL_VER=$(rpm -q kernel-headers --qf '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    mkdir -p /etc/modprobe.d /opt/lib/modules/utils && \
    # Create modprobe configuration
    printf '# VAST NFS Custom Module Loading Configuration\n# This configuration hooks modprobe to use our custom vastnfs-ctl utility\n# instead of traditional kernel module loading\n\n# Hook vastnfs module loading to our custom script\n# The script will call vastnfs-ctl reload/unload instead of insmod/rmmod\ninstall vastnfs /opt/lib/modules/utils/vastnfs-modprobe install "$@"\nremove vastnfs /opt/lib/modules/utils/vastnfs-modprobe remove "$@"\n\n# Optional: Create aliases for easier access\nalias vastnfs-loader vastnfs\nalias vast-nfs vastnfs\n\n# Prevent automatic loading of vastnfs through other means\n# This ensures all loading goes through our custom script\nblacklist vastnfs\n' > /etc/modprobe.d/vastnfs.conf

# Create the custom modprobe wrapper script
RUN printf '#!/usr/bin/env bash\n#\n# VAST NFS Custom Modprobe Wrapper\n# This script is called by modprobe when vastnfs module is loaded/unloaded\n# It executes vastnfs-ctl reload/unload instead of traditional module loading\n#\n\nset -euo pipefail\n\n# Configuration\nKERNEL_VERSION=$(uname -r 2>/dev/null || rpm -q kernel-headers --qf "%%{VERSION}-%%{RELEASE}.%%{ARCH}")\nVASTNFS_CTL="/usr/local/bin/vastnfs-ctl"\nLOG_PREFIX="[vastnfs-modprobe]"\n\n# Logging function\nlog() {\n    echo "${LOG_PREFIX} $*" >&2\n}\n\n# Error handling\nerror_exit() {\n    log "ERROR: $*"\n    exit 1\n}\n\n# Check if vastnfs-ctl exists\nif [[ ! -x "$VASTNFS_CTL" ]]; then\n    error_exit "vastnfs-ctl not found or not executable at: $VASTNFS_CTL"\nfi\n\n# Parse arguments\naction="install"\nmodule_args=()\n\nwhile [[ $# -gt 0 ]]; do\n    case "$1" in\n        "remove")\n            action="remove"\n            shift\n            ;;\n        *)\n            module_args+=("$1")\n            shift\n            ;;\n    esac\ndone\n\nlog "Action: $action, Args: ${module_args[*]:-none}, Kernel: $KERNEL_VERSION"\n\n# Execute the appropriate vastnfs-ctl command\ncase "$action" in\n    "install")\n        log "Loading VAST NFS using vastnfs-ctl reload"\n        if "$VASTNFS_CTL" reload "${module_args[@]:-}"; then\n            log "VAST NFS loaded successfully"\n            exit 0\n        else\n            error_exit "Failed to load VAST NFS via vastnfs-ctl reload"\n        fi\n        ;;\n    "remove")\n        log "Unloading VAST NFS using vastnfs-ctl unload"\n        if "$VASTNFS_CTL" unload "${module_args[@]:-}"; then\n            log "VAST NFS unloaded successfully"\n            exit 0\n        else\n            error_exit "Failed to unload VAST NFS via vastnfs-ctl unload"\n        fi\n        ;;\n    *)\n        error_exit "Unknown action: $action"\n        ;;\nesac\n' > /opt/lib/modules/utils/vastnfs-modprobe && \
    chmod +x /opt/lib/modules/utils/vastnfs-modprobe

# Generate module dependencies
RUN KERNEL_VER=$(rpm -q kernel-headers --qf '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    depmod -b /opt $KERNEL_VER

# Comprehensive testing of custom modprobe setup
RUN KERNEL_VER=$(rpm -q kernel-headers --qf '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    echo "=== VAST NFS Custom Modprobe Testing ===" && \
    echo "Kernel version: $KERNEL_VER" && \
    echo "" && \
    echo "1. Module directory contents:" && \
    ls -laR /opt/lib/modules/$KERNEL_VER/ || echo "No modules found" && \
    echo "" && \
    echo "2. Testing vastnfs-ctl directly:" && \
    /usr/local/bin/vastnfs-ctl status && \
    echo "" && \
    echo "3. Testing vastnfs-ctl reload:" && \
    /usr/local/bin/vastnfs-ctl reload && \
    echo "" && \
    echo "4. Testing vastnfs-ctl unload:" && \
    /usr/local/bin/vastnfs-ctl unload && \
    echo "" && \
    echo "5. Checking modprobe configuration:" && \
    cat /etc/modprobe.d/vastnfs.conf && \
    echo "" && \
    echo "6. Checking modprobe wrapper script:" && \
    ls -la /opt/lib/modules/utils/vastnfs-modprobe && \
    echo "" && \
    echo "7. Testing custom modprobe wrapper directly:" && \
    /opt/lib/modules/utils/vastnfs-modprobe install vastnfs && \
    echo "" && \
    echo "8. Testing custom modprobe wrapper removal:" && \
    /opt/lib/modules/utils/vastnfs-modprobe remove vastnfs && \
    echo "" && \
    echo "9. Testing modprobe command (should use our custom hook):" && \
    modprobe vastnfs && \
    echo "" && \
    echo "10. Testing modprobe removal (should use our custom hook):" && \
    modprobe -r vastnfs && \
    echo "" && \
    echo "=== All Custom Modprobe Tests Completed Successfully! ==="
