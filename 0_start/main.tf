

// Configure the Google Cloud provider
provider "google" {
 project     = var.project_id
 region      = var.project_region
}

provider "google-beta" {
  project     = var.project_id
  region      = var.project_region
}

// service account
resource "google_service_account" "cicd_account" {
  account_id   = "cicd-service-account-id"
  display_name = "Service Account for CI CD"
}

resource "google_project_iam_member" "cicd_account_editor_member" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.cicd_account.email}"
}

resource "google_project_iam_member" "cicd_account_container_adm_member" {
  project = var.project_id
  role    = "roles/container.admin"
  member  = "serviceAccount:${google_service_account.cicd_account.email}"
}

//