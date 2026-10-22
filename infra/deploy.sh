#!/usr/bin/env bash
# Builds the backend image with Cloud Build and rolls it out to Cloud Run.
# Infrastructure (service config, IAM, Firestore) is Terraform's job; this only ships code.
# Run via `make deploy` after `make apply`.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tf() { terraform -chdir="$here/terraform" output -raw "$1"; }

project="$(tf project_id)"
region="$(tf region)"
repo="$(tf artifact_repository)"
service="$(tf service_name)"
url="$(tf api_url)"

# Tag with the commit; mark builds of uncommitted backend changes.
tag="$(git -C "$here" rev-parse --short HEAD)"
if ! git -C "$here" diff --quiet HEAD -- ../backend; then
  tag="$tag-dirty-$(date +%Y%m%d%H%M%S)"
fi
image="$repo/api:$tag"

echo "==> Building $image"
gcloud builds submit "$here/../backend" --project "$project" --tag "$image" --quiet

echo "==> Deploying to Cloud Run service $service ($region)"
gcloud run services update "$service" --project "$project" --region "$region" --image "$image" --quiet

echo "==> Health check"
curl -fsS "$url/healthz"
echo
echo "Deployed $image to $url"
