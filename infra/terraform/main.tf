# hunters-map backend: Cloud Run API + Firestore + Firebase Authentication.
#
# The project is shared with spotify-mcp, so this stack only adds hunters-map-* resources
# and never disables APIs on destroy.

locals {
  services = [
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "firebase.googleapis.com",
    "firebaserules.googleapis.com",
    "firestore.googleapis.com",
    "iam.googleapis.com",
    "identitytoolkit.googleapis.com", # Firebase Authentication
    "run.googleapis.com",
    "serviceusage.googleapis.com",
  ]
  repository = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.api.repository_id}"
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  service            = each.value
  disable_on_destroy = false # other workloads in the project may use them
}

# ---------------------------------------------------------------------------- Firebase

# Adds Firebase to the project (needed for Firebase Authentication and the iOS app config).
# Removing Firebase from a project isn't possible, so destroy leaves it in place.
resource "google_firebase_project" "this" {
  provider = google-beta

  depends_on = [google_project_service.this]
}

resource "google_firebase_apple_app" "ios" {
  provider = google-beta

  display_name    = "Riistakartta iOS"
  bundle_id       = var.ios_bundle_id
  team_id         = var.apple_team_id != "" ? var.apple_team_id : null
  deletion_policy = "DELETE"

  depends_on = [google_firebase_project.this]
}

# GoogleService-Info.plist for the app (make ios-config). Re-run after enabling the
# Google sign-in provider, which adds the iOS OAuth client id to it.
data "google_firebase_apple_app_config" "ios" {
  provider = google-beta

  app_id = google_firebase_apple_app.ios.app_id
}

# ---------------------------------------------------------------------------- Firestore

resource "google_firestore_database" "main" {
  name                    = var.firestore_database
  location_id             = var.region
  type                    = "FIRESTORE_NATIVE"
  delete_protection_state = "DELETE_PROTECTION_ENABLED"
  deletion_policy         = "ABANDON" # terraform destroy never deletes the data

  depends_on = [google_project_service.this]
}

# TTL: Firestore deletes shared positions after sharing has ended, and expired invites.
resource "google_firestore_field" "location_ttl" {
  database   = google_firestore_database.main.name
  collection = "locations"
  field      = "expireAt"

  ttl_config {}
}

resource "google_firestore_field" "invite_ttl" {
  database   = google_firestore_database.main.name
  collection = "invites"
  field      = "expiresAt"

  ttl_config {}
}

# Security rules: phones may only read their own groups; all writes go through the API.
resource "google_firebaserules_ruleset" "firestore" {
  source {
    files {
      name    = "firestore.rules"
      content = file("${path.module}/../firestore.rules")
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [google_firebase_project.this]
}

resource "google_firebaserules_release" "firestore" {
  # Named databases use "cloud.firestore/<database>".
  name         = "cloud.firestore/${google_firestore_database.main.name}"
  ruleset_name = "projects/${var.project_id}/rulesets/${google_firebaserules_ruleset.firestore.name}"

  lifecycle {
    replace_triggered_by = [google_firebaserules_ruleset.firestore]
  }
}

# ---------------------------------------------------------------------------- Container images

resource "google_artifact_registry_repository" "api" {
  location      = var.region
  repository_id = "hunters-map"
  format        = "DOCKER"
  description   = "hunters-map backend images"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      tag_state  = "ANY"
      older_than = "2592000s" # 30 days; the 10 most recent are kept regardless
    }
  }

  depends_on = [google_project_service.this]
}

# ---------------------------------------------------------------------------- Runtime identity

resource "google_service_account" "api" {
  account_id   = "hunters-map-api"
  display_name = "hunters-map API (Cloud Run)"
}

# Read/write only the hunters-map database, not the project's other Firestore data.
resource "google_project_iam_member" "api_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = google_service_account.api.member

  condition {
    title      = "hunters-map database only"
    expression = "resource.name == \"projects/${var.project_id}/databases/${google_firestore_database.main.name}\""
  }
}

# Deleting the sign-in account on DELETE /v1/me. (Verifying tokens needs no IAM role.)
resource "google_project_iam_member" "api_firebase_auth" {
  project = var.project_id
  role    = "roles/firebaseauth.admin"
  member  = google_service_account.api.member
}

# ---------------------------------------------------------------------------- Cloud Run

resource "google_cloud_run_v2_service" "api" {
  name                = var.service_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account                  = google_service_account.api.email
    timeout                          = "30s"
    max_instance_request_concurrency = 80

    scaling {
      min_instance_count = 0 # scale to zero between hunting trips
      max_instance_count = var.max_instances
    }

    containers {
      image = var.initial_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
        cpu_idle          = true # CPU billed only while handling requests
        startup_cpu_boost = true
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "FIRESTORE_DATABASE"
        value = google_firestore_database.main.name
      }
    }
  }

  # infra/deploy.sh rolls out new images; Terraform owns everything else.
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_project_service.this,
    google_project_iam_member.api_firestore,
    google_project_iam_member.api_firebase_auth,
  ]
}

# Public endpoint: every /v1 route checks the Firebase ID token itself.
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
