variable "project_id" {
  description = "GCP project (shared with spotify-mcp for the POC; every resource here is prefixed hunters-map)."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run, Firestore and Artifact Registry. europe-north1 = Hamina, Finland."
  type        = string
  default     = "europe-north1"
}

variable "firestore_database" {
  description = "Named Firestore database, separate from the project's (default) database."
  type        = string
  default     = "hunters-map"
}

variable "service_name" {
  description = "Cloud Run service name."
  type        = string
  default     = "hunters-map-api"
}

variable "max_instances" {
  description = "Upper bound for Cloud Run instances (cost guard)."
  type        = number
  default     = 3
}

variable "ios_bundle_id" {
  description = "Bundle id of the iPhone app, registered as a Firebase Apple app."
  type        = string
  default     = "fi.ridefree.huntersmap"
}

variable "apple_team_id" {
  description = "Apple Developer team id (optional until Sign in with Apple / App Store)."
  type        = string
  default     = ""
}

variable "initial_image" {
  description = <<-EOT
    Image for the first deploy only. Releases are rolled out by infra/deploy.sh, and
    Terraform ignores image changes afterwards.
  EOT
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}
