SHELL := /bin/bash
REGION := us-east-1
CLUSTER := gpu-platform-dev
TF := terraform -chdir=terraform
PY := finops/.venv/bin/python
ACCOUNT := $(shell aws sts get-caller-identity --query Account --output text)
ECR := $(ACCOUNT).dkr.ecr.$(REGION).amazonaws.com
IMAGE := $(ECR)/gpu-platform-dev/finops-collector
# Immutable tag. The ECR repository rejects re-pushes, so a tag names exactly
# one build and a rollback is unambiguous.
TAG := $(shell git rev-parse --short HEAD)
GUARDRAILS := $(HOME)/platform-guardrails

.PHONY: help venv test lint image deploy kubeconfig demo status costs destroy clean

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

venv: ## Create the collector virtualenv
	python3 -m venv finops/.venv
	finops/.venv/bin/pip install -q -r finops/requirements.txt pytest ruff

test: ## Run collector unit tests and terraform validation
	cd finops && .venv/bin/python -m pytest tests/ -q
	$(TF) fmt -check -recursive
	$(TF) validate
	conftest test --parser hcl2 --combine --policy $(GUARDRAILS)/policy terraform/*.tf
	@echo "--> policy vacuity check: the non-compliant fixture must be blocked"
	@if conftest test --parser hcl2 --combine --policy $(GUARDRAILS)/policy \
		$(GUARDRAILS)/examples/fail/main.tf >/dev/null 2>&1; then \
		echo "FAIL: the non-compliant fixture passed, so the policy gate above proved nothing."; \
		exit 1; \
	fi
	@echo "OK: non-compliant fixture was blocked."
	checkov -d terraform --framework terraform --compact --quiet

lint: ## Lint python
	cd finops && .venv/bin/ruff check collector tests

image: ## Build and push the collector image, tagged with the git SHA
	@git diff --quiet || { echo "working tree is dirty; commit before building so the tag names this code"; exit 1; }
	aws ecr get-login-password --region $(REGION) \
		| docker login --username AWS --password-stdin $(ECR)
	docker build --platform linux/amd64 -t $(IMAGE):$(TAG) finops/
	docker push $(IMAGE):$(TAG)

# The collector deployment references an image that has to exist before the
# deployment applies, and the ECR repository has to exist before the image can
# be pushed. So the ECR resource applies alone first.
deploy: ## Full deploy (ECR, image, then everything else)
	$(TF) init -input=false
	# -target does not exempt a variable from being required, so the tag has to
	# be passed here too even though nothing in this stage consumes it.
	$(TF) apply -input=false -auto-approve -var collector_image_tag=$(TAG) -target=aws_ecr_repository.collector
	$(MAKE) image
	$(TF) apply -input=false -auto-approve -var collector_image_tag=$(TAG)
	$(MAKE) kubeconfig

kubeconfig: ## Point kubectl at the cluster
	aws eks update-kubeconfig --name $(CLUSTER) --region $(REGION)

demo: ## Run all six demo acts
	./scripts/demo.sh all

status: ## Current cluster and queue state
	@echo "--- GPU nodes ---"
	@kubectl get nodes -l workload-class=gpu \
		-o custom-columns=NODE:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,CAPACITY:.metadata.labels.karpenter\\.sh/capacity-type,GPU:.status.allocatable.nvidia\\.com/gpu 2>/dev/null || echo "none"
	@echo "--- queue ---"
	@kubectl get clusterqueue gpu-queue 2>/dev/null || echo "not ready"
	@echo "--- collector ---"
	@kubectl -n finops logs -l app=finops-collector --tail=5 2>/dev/null || echo "not running"

costs: ## Recent GPU cost attribution records
	@aws dynamodb scan --region $(REGION) --table-name $(CLUSTER)-costs \
		--filter-expression 'record_type = :t' \
		--expression-attribute-values '{":t":{"S":"GPU_SAMPLE"}}' \
		--query 'Items[].{node:node.S,type:instance_type.S,life:lifecycle.S,sm_pct:sm_active_pct.N,util_pct:gpu_util_pct.N,cost:cost_usd.N,wasted:wasted_cost_usd.N}' \
		--output table

# Order matters. Karpenter nodes carry finalizers and are not owned by the EKS
# module, so they must be gone before the cluster is destroyed or the VPC
# delete hangs on ENIs that belong to instances Terraform never tracked.
destroy: ## Tear everything down, GPU nodes first
	-kubectl delete nodeclaims --all --timeout=10m
	-kubectl delete pods --all -n team-a --force --grace-period=0
	-kubectl delete pods --all -n team-b --force --grace-period=0
	$(TF) destroy -input=false -auto-approve
	@echo "verify nothing survived:"
	@aws ec2 describe-instances --region $(REGION) \
		--filters "Name=tag:Project,Values=gpu-platform" "Name=instance-state-name,Values=running,pending" \
		--query 'Reservations[].Instances[].InstanceId' --output text

clean: ## Remove local build artifacts
	rm -rf finops/.venv finops/**/__pycache__ terraform/.terraform
