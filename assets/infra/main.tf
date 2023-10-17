terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.81.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 4.81.0"
    }
  }

  backend "gcs" {
    prefix = "terraform/state"
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "google-beta" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

locals {
  subnetwork_name = "${var.network_name}-subnet-${var.gcp_region}"
}

## GCP Services
resource "google_project_service" "enabled_services" {
  project            = var.gcp_project_id
  service            = each.key
  for_each           = toset(var.gcp_services_list)
  disable_on_destroy = false
}

## GCE Networking
resource "google_compute_network" "network" {
  name                    = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnetwork" {
  name                     = local.subnetwork_name
  ip_cidr_range            = var.gce_subnetwork_cidr
  region                   = var.gcp_region
  network                  = google_compute_network.network.id
  private_ip_google_access = true
}

## Compute Engine Resources
# Serverless VPC Access Connector
resource "google_vpc_access_connector" "connector" {
  name          = "connector-${var.network_name}"
  region        = var.gcp_region
  ip_cidr_range = "172.16.1.0/28"
  network       = var.network_name
  min_instances = 2
  max_instances = 10
  machine_type  = "e2-micro"
  max_throughput = 1000
  depends_on = [
    google_project_service.enabled_services,
    google_compute_network.network
  ]
}

# GCE Instance
resource "google_compute_instance" "packet-sniffer" {
  name         = "packet-sniffer"
  machine_type = "e2-standard-4"
  zone         = var.compute_zone
  tags         = ["vpc-producer-server"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  network_interface {
    network    = google_compute_network.network.id
    subnetwork = google_compute_subnetwork.subnetwork.id
    network_ip = var.gce_vm_private_ip
    access_config {
    }
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    sudo su -
    apt update
    apt install apache2 -y
    apt install iperf3 -y
    apt install hey -y
    iperf3 -s &
    echo "<h1>Hello World</h1>" > /var/www/html/index.html
  EOF
}

# Firewall Rules
resource "google_compute_firewall" "allow_required" {
  name      = "allow-http-icmp-vpcdirect-to-gce"
  network   = google_compute_network.network.id
  direction = "INGRESS"
  priority  = 900

  allow {
    protocol = "tcp"
    ports    = ["80", "5201"]
  }

  allow {
    protocol = "icmp"
  }

  source_tags = ["service-direct-egress"]
  target_tags = ["vpc-producer-server"]

}

resource "google_compute_firewall" "internal-to-vpc-connector" {
  name      = "allow-internal-to-vpc-connector"
  network   = google_compute_network.network.id
  direction = "INGRESS"
  priority  = 900

  allow {
    protocol = "all"
  }

  source_ranges = ["35.199.224.0/19"]
  target_tags   = ["vpc-connector"]
}

resource "google_compute_firewall" "allow-iap" {
  name      = "allow-ssh-ingress-from-iap"
  network   = google_compute_network.network.id
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
}

## Cloud Run
resource "google_cloud_run_service" "vpc-access-connector-service" {
  project    = var.gcp_project_id
  name       = "vpc-access-connector-service"
  location   = var.gcp_region
  depends_on = [google_vpc_access_connector.connector]

  metadata {
    labels = {
      "cloud.googleapis.com/location" = var.gcp_region
    }
  }

  template {
    metadata {
      annotations = {
        "run.googleapis.com/vpc-access-connector" = google_vpc_access_connector.connector.name
        "run.googleapis.com/vpc-access-egress"    = "private-ranges-only"
        "autoscaling.knative.dev/maxScale"        = 5
        "run.googleapis.com/startup-cpu-boost"    = true
      }
    }
    spec {
      containers {
        image = var.nettest_image_url
      }
      timeout_seconds = "600s"
    }
  }
}

resource "google_cloud_run_service" "direct-vpc-egress-service" {
  project  = var.gcp_project_id
  name     = "direct-vpc-egress-service"
  location = var.gcp_region
  provider = google-beta
  depends_on = [
    google_cloud_run_service.vpc-access-connector-service
  ]

  metadata {
    labels = {
      "cloud.googleapis.com/location" = var.gcp_region
    }
    annotations = {
      "run.googleapis.com/launch-stage" = "BETA"
    }
  }

  template {
    metadata {
      annotations = {
        "run.googleapis.com/network-interfaces" = jsonencode(
          [
            {
             "network"    = google_compute_network.network.name,
             "subnetwork" = google_compute_subnetwork.subnetwork.name,
             "tags" = [
              "service-direct-egress"]
            }
          ]
        )
        "run.googleapis.com/vpc-access-egress" = "private-ranges-only"
        "autoscaling.knative.dev/maxScale"     = 5
        "run.googleapis.com/startup-cpu-boost" = true
      }
    }
    spec {
      containers {
        image = var.nettest_image_url
      }
      timeout_seconds = "600s"
    }
  }
}

# Allow unauthenticated
data "google_iam_policy" "noauth" {
  binding {
    role = "roles/run.invoker"
    members = [
      "allUsers",
    ]
  }
}

resource "google_cloud_run_service_iam_policy" "vpc-access-connector-noauth" {
  location = google_cloud_run_service.vpc-access-connector-service.location
  project  = google_cloud_run_service.vpc-access-connector-service.project
  service  = google_cloud_run_service.vpc-access-connector-service.name

  policy_data = data.google_iam_policy.noauth.policy_data
}

resource "google_cloud_run_service_iam_policy" "direct-vpc-egress-noauth" {
  location = google_cloud_run_service.direct-vpc-egress-service.location
  project  = google_cloud_run_service.direct-vpc-egress-service.project
  service  = google_cloud_run_service.direct-vpc-egress-service.name

  policy_data = data.google_iam_policy.noauth.policy_data
}
