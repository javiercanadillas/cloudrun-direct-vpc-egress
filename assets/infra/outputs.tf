output "cloudrun_direct_vpc_egress_service_url" {
  value = google_cloud_run_service.direct-vpc-egress-service.status[0].url
}

output "cloudrun_direct_vpc_egress_service_name" {
  value = google_cloud_run_service.direct-vpc-egress-service.name
}
  
output "cloudrun_vpc_access_connector_service_url" {
  value = google_cloud_run_service.vpc-access-connector-service.status[0].url
}

output "cloudrun_vpc_access_connector_service_name" {
  value = google_cloud_run_service.vpc-access-connector-service.name
}

output "gce_vm_name" {
  value = google_compute_instance.packet-sniffer.name
}

output "gce_vm_private_ip" {
  value = google_compute_instance.packet-sniffer.network_interface[0].network_ip
}

output "gcp_region" {
  value = var.gcp_region
}

output "compute_zone" {
  value = var.compute_zone
}

output "gcp_project_id" {
  value = var.gcp_project_id
}