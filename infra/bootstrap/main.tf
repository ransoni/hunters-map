# One-time bootstrap: the GCS bucket that holds the main stack's Terraform state.
# Uses local state (terraform.tfstate in this folder, gitignored); if it's ever lost,
# re-import with: terraform import google_storage_bucket.tfstate <bucket-name>

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "europe-north1"
}

provider "google" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-hunters-map-tfstate"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  # Keep the 10 most recent non-current state versions.
  lifecycle_rule {
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

output "bucket" {
  value = google_storage_bucket.tfstate.name
}
