# Copyright 2020 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

provider "google" {
  project = var.project
  region  = var.region
}

# For beta-only resources like secrets-manager
provider "google-beta" {
  project = var.project
  region  = var.region
}

# To generate passwords.
provider "random" {}

data "google_project" "project" {
  project_id = var.project
}

resource "google_project_service" "services" {
  project = data.google_project.project.project_id
  for_each = toset(["run.googleapis.com", "cloudkms.googleapis.com", "secretmanager.googleapis.com", "storage-api.googleapis.com", "cloudscheduler.googleapis.com",
  "sql-component.googleapis.com", "cloudbuild.googleapis.com", "servicenetworking.googleapis.com", "compute.googleapis.com", "sqladmin.googleapis.com"])
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_global_address" "private_ip_address" {
  provider = google-beta

  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = "default"

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

resource "google_service_networking_connection" "private_vpc_connection" {
  provider = google-beta

  network                 = "default"
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

# This step automatically runs a build as well, so everything that uses an image depends on it.
resource "google_cloudbuild_trigger" "build-and-publish" {
  provider = google-beta
  count    = var.use_build_triggers ? 1 : 0

  name        = "build-containers"
  description = "Build the containers for the exposure notification service and deploy them to cloud run"
  filename    = "builders/deploy.yaml"
  github {
    owner = var.repo_owner
    name  = var.repo_name
    push {
      branch = "^master$"
    }
  }

  depends_on = [google_project_service.services["cloudbuild.googleapis.com"]]
}

# "build" does first time setup - it is different from "deploy" which we set up to trigger for later.
resource "null_resource" "submit-build-and-publish" {
  provisioner "local-exec" {
    command = "gcloud builds submit ../ --config ../builders/build.yaml --project ${data.google_project.project.project_id}"
  }

  depends_on = [
    google_project_iam_member.cloudbuild-secrets,
    google_project_iam_member.cloudbuild-sql,
  ]
}

locals {
  common_cloudrun_env_vars = [
    {
      name  = "DB_POOL_MIN_CONNS"
      value = "2"
    },
    {
      name  = "DB_POOL_MAX_CONNS"
      value = "10"
    },
    {
      name  = "DB_PASSWORD"
      value = "secret://${google_secret_manager_secret_version.db-pwd-initial.name}"
    },
    {
      # NOTE: We disable SSL here because the Cloud Run services use the Cloud
      # SQL proxy which runs on localhost. The proxy still uses a secure
      # connection to Cloud SQL.
      name  = "DB_SSLMODE"
      value = "disable"
    },
    {
      name  = "DB_HOST"
      value = "/cloudsql/${data.google_project.project.project_id}:${var.region}:${google_sql_database_instance.db-inst.name}"
    },
    {
      name  = "DB_USER"
      value = google_sql_user.user.name
    },
    {
      name  = "DB_NAME"
      value = google_sql_database.db.name
    },
  ]
}

data "google_iam_policy" "noauth" {
  binding {
    role = "roles/run.invoker"
    members = [
      "allUsers",
    ]
  }
}

# Cloud Scheduler requires AppEngine projects!
resource "google_app_engine_application" "app" {
  project     = data.google_project.project.project_id
  location_id = var.appengine_location
}
