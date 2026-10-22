# hunters-map infrastructure. Run from this folder (infra/).
#
#   make apis        once: enable the APIs Terraform itself needs (bootstrap runs it)
#   make bootstrap   once: create the Terraform state bucket
#   make init        once per machine: connect Terraform to the state bucket
#   make plan        preview infrastructure changes
#   make apply       create/update infrastructure
#   make deploy      build the backend and roll it out to Cloud Run
#   make ios-config  write GoogleService-Info.plist into the iOS app
#   make smoke       call the deployed API without a token (expects 401)

PROJECT ?= $(shell sed -n 's/^project_id *= *"\(.*\)"/\1/p' terraform/terraform.tfvars)
STATE_BUCKET := $(PROJECT)-hunters-map-tfstate
TF := terraform -chdir=terraform

.PHONY: apis bootstrap init plan apply deploy ios-config smoke fmt validate

# The Google provider needs these APIs to read any project resource, so Terraform can't
# turn them on itself. Idempotent; Terraform then tracks them (google_project_service.base).
apis:
	gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com --project $(PROJECT)

bootstrap: apis
	terraform -chdir=bootstrap init
	terraform -chdir=bootstrap apply -var project_id=$(PROJECT)

init:
	$(TF) init -backend-config="bucket=$(STATE_BUCKET)"

plan:
	$(TF) plan -out=tfplan

apply:
	@test -f terraform/tfplan || (echo "Run 'make plan' first and review it." && exit 1)
	$(TF) apply tfplan
	rm -f terraform/tfplan

deploy:
	./deploy.sh

ios-config:
	@# Refresh-only: re-reads the app config (e.g. after enabling Google sign-in), changes nothing.
	$(TF) apply -refresh-only -auto-approve >/dev/null
	$(TF) output -raw ios_google_service_info_plist | base64 --decode > ../ios/HuntersMap/GoogleService-Info.plist
	@echo "Wrote ios/HuntersMap/GoogleService-Info.plist"

smoke:
	@url=$$($(TF) output -raw api_url); \
	curl -fsS $$url/health && echo && \
	curl -s -o /dev/null -w "GET /v1/me without token -> %{http_code} (expected 401)\n" $$url/v1/me

fmt:
	terraform fmt -recursive .

validate:
	$(TF) init -backend=false >/dev/null && $(TF) validate
