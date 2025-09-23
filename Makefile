.EXPORT_ALL_VARIABLES:
SHELL := /usr/bin/env bash
CURRENT_TARGET := $(firstword $(MAKECMDGOALS))

# VAST NFS KMM Configuration
VASTNFS_VERSION ?= 4.0.35
NAMESPACE ?= vastnfs-kmm
KUSTOMIZE_DIR ?= k8s/base

# KMM Image Configuration
KMM_IMG_REPO ?= image-registry.openshift-image-registry.svc:5000/vastnfs-kmm/vastnfs
KMM_IMG_TAG ?= \$${KERNEL_FULL_VERSION}
KMM_PULL_SECRET ?=

# Kustomize binary location
KUSTOMIZE ?= kustomize

# Dynamic argument parsing for install commands
ifeq (install, $(firstword $(MAKECMDGOALS)))
  installargs := $(wordlist 2, $(words $(MAKECMDGOALS)), $(MAKECMDGOALS))
  $(foreach arg,$(installargs),$(eval $(arg):;@true))
endif

ifeq (install-secure-boot, $(firstword $(MAKECMDGOALS)))
  installargs := $(wordlist 2, $(words $(MAKECMDGOALS)), $(MAKECMDGOALS))
  $(foreach arg,$(installargs),$(eval $(arg):;@true))
endif

ifeq (install-secure-boot-with-keys, $(firstword $(MAKECMDGOALS)))
  installargs := $(wordlist 2, $(words $(MAKECMDGOALS)), $(MAKECMDGOALS))
  $(foreach arg,$(installargs),$(eval $(arg):;@true))
endif

define check_required_env =
	@if [ -n "$$CURRENT_TARGET" ]; then \
		printf "\033[32m[%s]\033[0m\n" "$$CURRENT_TARGET"; \
	fi; \
	missing_vars=0; \
	for var in $(strip $1); do \
		if [ -z "$${!var}" ]; then \
			printf "\033[31m!\033[36m%-30s\033[0m \033[31m<missing>\033[0m\n" $$var; \
			missing_vars=1; \
		else \
			printf "\033[31m!\033[36m%-30s\033[0m %s\n" $$var "$${!var}"; \
		fi; \
	done; \
	if [ $$missing_vars -ne 0 ]; then \
		echo "Please ensure all required environment variables are set and not empty."; \
		exit 1; \
	fi;
endef

.PHONY: check_required_env

######################
# DEPENDENCIES
######################
install-kustomize: ## Install kustomize if not present
	@if ! command -v kustomize > /dev/null 2>&1; then \
		echo "Installing kustomize..."; \
		curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash; \
		sudo mv kustomize /usr/local/bin/; \
		echo "Kustomize installed successfully"; \
	else \
		echo "Kustomize is already installed: $$(kustomize version --short)"; \
	fi

######################
# NAMESPACE MANAGEMENT
######################
create-namespace: ## Create namespace for VAST NFS KMM
	@if ! oc get namespace $(NAMESPACE) > /dev/null 2>&1; then \
		echo "Namespace $(NAMESPACE) does not exist. Creating it..."; \
		oc create namespace $(NAMESPACE); \
	else \
		echo "Namespace $(NAMESPACE) already exists."; \
	fi

######################
# BUILD TARGETS
######################
build-installer: install-kustomize ## Generate a consolidated YAML with CRDs and deployment
	@$(call check_required_env,VASTNFS_VERSION NAMESPACE)
	@mkdir -p dist
	@export VASTNFS_VERSION="$(VASTNFS_VERSION)"; \
	export KMM_IMG="$(KMM_IMG_REPO):$(KMM_IMG_TAG)"; \
	export NAMESPACE="$(NAMESPACE)"; \
	export KMM_PULL_SECRET="$(KMM_PULL_SECRET)"; \
	if [ -n "$$KMM_PULL_SECRET" ]; then \
		echo "Building with pull secret overlay: $$KMM_PULL_SECRET"; \
		$(KUSTOMIZE) build $(KUSTOMIZE_DIR)/../overlays/with-pull-secret | envsubst '$$VASTNFS_VERSION $$KMM_IMG $$NAMESPACE $$KMM_PULL_SECRET' > dist/install.yaml; \
	else \
		echo "Building base configuration (no pull secret)"; \
		$(KUSTOMIZE) build $(KUSTOMIZE_DIR) | envsubst '$$VASTNFS_VERSION $$KMM_IMG $$NAMESPACE' > dist/install.yaml; \
	fi
	@echo "Generated consolidated manifest at dist/install.yaml"

######################
# INSTALLATION TARGETS
######################
#   Install VAST NFS KMM on the cluster with optional wait functionality.
#   Usage:
#     make install                - Standard installation without waiting
#     make install wait           - Install and wait for pods to start, then follow logs
#
#   The wait option will:
#     1. Install the VAST NFS KMM module
#     2. Wait for pods to start
#     3. Follow pod logs in real-time
#     4. Continue until interrupted
#
install: create-namespace ## Install VAST NFS KMM on the cluster with optional wait
	@$(call check_required_env,VASTNFS_VERSION NAMESPACE)
	@wait_arg=$(word 1, $(installargs)); \
	export VASTNFS_VERSION="$(VASTNFS_VERSION)"; \
	export KMM_IMG="$(KMM_IMG_REPO):$(KMM_IMG_TAG)"; \
	export NAMESPACE="$(NAMESPACE)"; \
	export KMM_PULL_SECRET="$(KMM_PULL_SECRET)"; \
	export KUSTOMIZE_DIR="$(KUSTOMIZE_DIR)"; \
	if [ "$$wait_arg" = "wait" ]; then \
		./scripts/install_and_follow_logs.sh --follow-logs; \
	else \
		./scripts/install_and_follow_logs.sh; \
	fi

uninstall: ## Remove VAST NFS KMM from the cluster (handles finalizers)
	@echo "Uninstalling VAST NFS KMM from namespace $(NAMESPACE)..."
	@echo "Stopping any active builds (aggressive cleanup)..."
	@echo "Patching build finalizers..."
	@oc get builds -n $(NAMESPACE) -o name 2>/dev/null | xargs -r -I {} oc patch {} -n $(NAMESPACE) -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	@echo "Force deleting builds..."
	@oc get builds -n $(NAMESPACE) -o name 2>/dev/null | xargs -r oc delete --force --grace-period=0 -n $(NAMESPACE) 2>/dev/null || true
	@echo "Cleaning up build pods..."
	@oc delete pods -l openshift.io/build.name -n $(NAMESPACE) --force --grace-period=0 2>/dev/null || true
	@echo "Deleting Module (force removing finalizers first)..."
	@oc patch module vastnfs -n $(NAMESPACE) -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	@oc delete module vastnfs -n $(NAMESPACE) --ignore-not-found --force --grace-period=0 2>/dev/null || true
	@echo "Deleting remaining resources..."
	@oc delete clusterrole,clusterrolebinding -l app.kubernetes.io/name=vastnfs-kmm 2>/dev/null || true
	@oc delete serviceaccount,configmap -l app.kubernetes.io/name=vastnfs-kmm -n $(NAMESPACE) 2>/dev/null || true
	@echo "Cleaning up any remaining ImageStreams..."
	@oc delete imagestream vastnfs -n $(NAMESPACE) 2>/dev/null || true

######################
# SECURE BOOT TARGETS
######################
install-secure-boot: ## Install VAST NFS KMM with secure boot support (add 'wait' to follow logs)
	@$(call check_required_env,VASTNFS_VERSION NAMESPACE)
	@wait_arg=$(word 1, $(installargs)); \
	export VASTNFS_VERSION="$(VASTNFS_VERSION)"; \
	export KMM_IMG="$(KMM_IMG_REPO):$(KMM_IMG_TAG)"; \
	export NAMESPACE="$(NAMESPACE)"; \
	export KMM_PULL_SECRET="$(KMM_PULL_SECRET)"; \
	export KUSTOMIZE_DIR="$(KUSTOMIZE_DIR)"; \
	if [ "$$wait_arg" = "wait" ]; then \
		./scripts/install_with_secure_boot.sh --follow-logs; \
	else \
		./scripts/install_with_secure_boot.sh; \
	fi

install-secure-boot-with-keys: ## Install with existing secure boot keys (add 'wait' to follow logs)
	@$(call check_required_env,PRIVATE_KEY_FILE PUBLIC_CERT_FILE VASTNFS_VERSION NAMESPACE)
	@wait_arg=$(word 1, $(installargs)); \
	export VASTNFS_VERSION="$(VASTNFS_VERSION)"; \
	export KMM_IMG="$(KMM_IMG_REPO):$(KMM_IMG_TAG)"; \
	export NAMESPACE="$(NAMESPACE)"; \
	export KMM_PULL_SECRET="$(KMM_PULL_SECRET)"; \
	export KUSTOMIZE_DIR="$(KUSTOMIZE_DIR)"; \
	export PRIVATE_KEY_FILE="$(PRIVATE_KEY_FILE)"; \
	export PUBLIC_CERT_FILE="$(PUBLIC_CERT_FILE)"; \
	if [ "$$wait_arg" = "wait" ]; then \
		./scripts/install_with_secure_boot.sh --keys "$(PRIVATE_KEY_FILE)" "$(PUBLIC_CERT_FILE)" --follow-logs; \
	else \
		./scripts/install_with_secure_boot.sh --keys "$(PRIVATE_KEY_FILE)" "$(PUBLIC_CERT_FILE)"; \
	fi

generate-secure-boot-keys: ## Generate secure boot keys for kernel module signing
	@./scripts/generate_secure_boot_keys.sh

verify-secure-boot: ## Verify secure boot deployment
	@echo "=== Verifying Secure Boot Deployment ==="
	@echo "1. Checking module status..."
	@oc get module vastnfs -n $(NAMESPACE) 2>/dev/null || echo "Module not found"
	@echo ""
	@echo "2. Checking for signed modules on nodes..."
	@for node in $$(oc get nodes -o jsonpath='{.items[0].metadata.name}'); do \
		echo "--- Checking $$node ---"; \
		echo "VAST NFS Status:"; \
		oc debug node/$$node -- chroot /host cat /sys/module/sunrpc/parameters/nfs_bundle_version 2>/dev/null && echo " (VAST NFS ACTIVE)" || echo "VAST NFS not active"; \
		echo "Module signature:"; \
		oc debug node/$$node -- chroot /host modinfo sunrpc | grep signature 2>/dev/null || echo "No signature found"; \
		echo "Secure boot status:"; \
		oc debug node/$$node -- chroot /host mokutil --sb-state 2>/dev/null || echo "mokutil not available"; \
		echo ""; \
	done

verify: ## Verify VAST NFS deployment using verification script
	@echo "=== Verifying VAST NFS Deployment ==="
	@./scripts/verify_deployment.sh --namespace $(NAMESPACE)

######################
# HELP TARGET
######################
help: ## Show available targets
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

