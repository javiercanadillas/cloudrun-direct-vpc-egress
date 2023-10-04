# GCP Services
variable "gcp_services_list" {
  description = "List of required APIs for Lab1"
  type        = list(string)
  default = [
    "compute.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "vpcaccess.googleapis.com",
    "networkmanagement.googleapis.com",
    "run.googleapis.com"
  ]
}

variable "gcp_project_id" {
  description = "GCP Project ID"
}

variable "gcp_region" {
  description = "GCP Region"
  default = "europe-west1"
}

variable "compute_zone" {
  description = "GCP Zone"
  default = "europe-west1-b"
}

variable "network_name" {
  description = "value of vpc network name"
  default = "vpc-producer"
}

variable "gce_vm_private_ip" {
  description = "The private IP for the nettest GCE VM"
  default = "10.0.1.4"
}

variable "gce_subnetwork_cidr" {
  description = "The CIDR range for the subnetwork"
  default = "10.0.1.0/24"
}

variable "nettest_image_url" {
  description = "Value of nettest image AR URL"
}