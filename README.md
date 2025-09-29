# VAST NFS KMM (Kernel Module Management) for OpenShift

This repository provides automated deployment of VAST NFS kernel modules on OpenShift using the Kernel Module Management (KMM) operator.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Installation Methods](#installation-methods)
- [Usage](#usage)
- [Verification](#verification)


## Overview

VAST NFS KMM enables automatic deployment and management of VAST NFS kernel modules across OpenShift clusters. It supports:

- **Automatic kernel module building and loading**
- **Multi-node deployment**
- **Secure boot environments**
- **Comprehensive verification**
- **Clean uninstallation**

### Architecture

![VAST NFS KMM Architecture & Workflow](img/vast_nfs_kmm_architecture_workflow.png)

## Prerequisites

### Required Tools
- `oc` or `kubectl` CLI tool
- `kustomize` (automatically installed if missing)
- OpenShift cluster with KMM operator installed
- Cluster admin privileges

### KMM Operator Installation
If KMM operator is not installed:

![KMM Operator Installation](img/kmm-operator-installation.gif)


## Quick Start

```bash
# Clone the repository
git clone https://github.com/vast-data/openshift-vastnfs-kmm-operator
cd openshift-vastnfs-kmm-operator

# Install VAST NFS KMM (includes real-time log monitoring)
make install

# Verify deployment
make verify

# Uninstall
make uninstall
```

## Installation Methods

### 1. Standard Installation

**Installation with real-time log monitoring:**
```bash
make install
```


### 2. Secure Boot Installation

**Generate keys and install (includes log monitoring):**
```bash
make install-secure-boot
```

**Using existing keys (includes log monitoring):**
```bash
export PRIVATE_KEY_FILE=/path/to/private.key
export PUBLIC_CERT_FILE=/path/to/public.crt
make install-secure-boot-with-keys
```


### 3. Custom Configuration

**Optional environment variable overrides:**
```bash
export NAMESPACE=my-namespace
export VASTNFS_VERSION=4.0.36
make install
```

### 4. Manual Manifest Generation

For fine-grained control over resources, generate and customize manifests:

```bash
# Generate consolidated manifest
make build-installer

# Review and customize the generated manifest
vi dist/install.yaml

# Apply manually
oc apply -f dist/install.yaml
```

This approach allows you to:
- Review all resources before deployment
- Customize specific configurations
- Apply manifests in stages
- Integrate with CI/CD pipelines


## Usage

### Available Make Targets

| Target | Description |
|--------|-------------|
| `make install` | Standard installation with real-time log monitoring |
| `make install-secure-boot` | Secure boot installation with real-time log monitoring |
| `make install-secure-boot-with-keys` | Secure boot with existing keys and real-time log monitoring |
| `make uninstall` | Clean removal |
| `make verify` | Deployment verification |
| `make build-installer` | Generate consolidated manifest in `dist/install.yaml` |
| `make help` | Show all targets |

### Log Monitoring

All installation commands now include real-time log monitoring by default. The installation will:

1. **Install resources** - Deploy all KMM components
2. **Wait for pods** - Monitor pod creation (up to 60 seconds)
3. **Wait for containers** - Wait for containers to be ready (up to 5 minutes)
4. **Stream logs** - Follow real-time logs with retry logic
5. **Continue until interrupted** - Press `Ctrl+C` to stop

**Example output:**
```
[STEP] Waiting for pods to start...
[SUCCESS] Found pods: vastnfs-pull-pod-f9t9h
[STEP] Following pod logs...
[INFO] === Preparing to follow logs for vastnfs-pull-pod-f9t9h ===
[INFO] Waiting for pod vastnfs-pull-pod-f9t9h to be ready...
[SUCCESS] Pod vastnfs-pull-pod-f9t9h is ready for log streaming
[INFO] Starting log stream for vastnfs-pull-pod-f9t9h...
```

## Verification

### Automatic Verification
```bash
make verify
```

### Manual Verification
```bash
# Check module status
oc get module vastnfs -n vastnfs-kmm

# Check VAST NFS version on nodes
oc debug node/<node-name> -- chroot /host cat /sys/module/sunrpc/parameters/nfs_bundle_version

# Check loaded modules
oc debug node/<node-name> -- chroot /host lsmod | grep -E "(sunrpc|rpcrdma|nfs)"
```


## Troubleshooting

### Common Issues

**1. Installation hangs during uninstall:**
```bash
# The Makefile automatically handles finalizer removal
# If still stuck, manually remove finalizers:
oc patch module vastnfs -n vastnfs-kmm -p '{"metadata":{"finalizers":[]}}' --type=merge
```

**2. Log following fails:**
```bash
# Check pod status
oc get pods -n vastnfs-kmm

# Manual log access
oc logs <pod-name> -n vastnfs-kmm
```

**3. Module loading fails:**
```bash
# Check KMM operator logs
oc logs -n openshift-kmm deployment/kmm-operator-controller

# Check node compatibility
oc debug node/<node-name> -- chroot /host uname -r
```

**4. Secure boot issues:**
```bash
# Verify secure boot status
oc debug node/<node-name> -- chroot /host mokutil --sb-state

# Check module signatures
oc debug node/<node-name> -- chroot /host modinfo sunrpc | grep signature
```

### Debug Commands

```bash
# Check all resources
oc get all -n vastnfs-kmm

# Check module details
oc describe module vastnfs -n vastnfs-kmm

# Check events
oc get events -n vastnfs-kmm --sort-by='.lastTimestamp'

# Check node status
oc get nodes
oc describe node <node-name>
```

## Configuration

All variables have sensible defaults. Override only if needed.

### Optional Environment Variable Overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `NAMESPACE` | `vastnfs-kmm` | Target namespace |
| `VASTNFS_VERSION` | `4.0.35` | VAST NFS version |
| `KMM_IMG_REPO` | Auto-generated | Container image repository |
| `KMM_IMG_TAG` | `${KERNEL_FULL_VERSION}` | Container image tag |
| `KMM_PULL_SECRET` | Empty | Optional pull secret for private registries |
| `KUSTOMIZE_DIR` | `k8s/base` | Kustomization directory |

### Customization

**Custom namespace:**
```bash
export NAMESPACE=my-vastnfs
make install
```

**Custom version:**
```bash
export VASTNFS_VERSION=4.0.36
make install
```

## Secure Boot Support

### Key Generation
```bash
# Generate new signing keys
make generate-secure-boot-keys

# Keys will be created in: secure-boot-keys/
```

### Installation with Secure Boot
```bash
# Method 1: Auto-generate keys (includes log monitoring)
make install-secure-boot

# Method 2: Use existing keys (includes log monitoring)
export PRIVATE_KEY_FILE=/path/to/signing.key
export PUBLIC_CERT_FILE=/path/to/signing.crt
make install-secure-boot-with-keys
```

### Verification
```bash
# Verify secure boot deployment
make verify-secure-boot

# Or use regular verification
make verify
```
