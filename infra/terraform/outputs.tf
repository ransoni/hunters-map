output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "api_url" {
  value = google_cloud_run_v2_service.api.uri
}

output "service_name" {
  value = google_cloud_run_v2_service.api.name
}

output "artifact_repository" {
  value = local.repository
}

output "firestore_database" {
  value = google_firestore_database.main.name
}

output "service_account" {
  value = google_service_account.api.email
}

output "ios_app_id" {
  value = google_firebase_apple_app.ios.app_id
}

# Base64 GoogleService-Info.plist; written into the iOS project by `make ios-config`.
output "ios_google_service_info_plist" {
  value = data.google_firebase_apple_app_config.ios.config_file_contents
}
