# Option 1 - Setting up the required infrastructure manually

Before proceeding, make sure you've met the prerequisites and have performed the initial setup as described in the corresponding [README section](../README.md#setting-up-the-environment-and-infrastructure) where you should be coming from.

## Setting up the environment

Define the GCP Project ID:

```bash
GCP_PROJECT_ID=<your project id> # Replace with your project ID
gcloud config set project $GCP_PROJECT_ID
```

You will be setting up the rest of environment variables as they become necessary for the configuration of the different components.

## Enabling the required GCP APIs

Enable the required APIs:

```bash
gcloud services enable run.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  vpcaccess.googleapis.com \
  networkmanagement.googleapis.com
```

## Creating the networking baseline

### Creating a VPC network and subnetwork 

As shown in the reference architecture, you will be creating a custom mode VPC with a subnet in `$REGION` with a the `10.0.1.0/24` IP range.

```bash
VPC_NAME=vpc-producer
GCP_REGION=europe-west1
gcloud compute networks create $VPC_NAME --subnet-mode=custom
gcloud compute networks subnets create "${VPC_NAME}-subnet-$GCP_REGION" --network=$VPC_NAME --region=$GCP_REGION --range=10.0.1.0/24
```

### Creating a Serverless VPC Access Connector

To know more about the Serverless VPC Access Connector, refer to the corresponding introduction section of the [README.md file](../README.md#serveless-vpc-access-connector).

To configure the Serverless VPC Access Connector, type the following command:

```bash
gcloud compute networks vpc-access connectors create "connector-$VPC_NAME" \
--network=$VPC_NAME \
--region=$GCP_REGION \
--range=172.16.1.0/28 \
--min-instances=2 \
--max-instances=10 \
--machine-type=e2-micro 
```

## Deploying the GCE VM

You will now create a VM instance with a private IP `10.0.1.4` in the subnet corresponding to the region you've chosen that will: 

- Act as a web server for testing HTTP requests from the two Cloud Run services.
- Act as iPerf destination to run network tests
- Run `tcpdump` to capture network traffic
- Act as a load testing source against the Cloud Run services through the `hey` that is installed in the VM

To create the VM instance, type the following command:
```bash
GCE_VM_NAME=packet-sniffer
GCE_VM_PRIVATE_IP="10.0.1.4"
gcloud compute instances create "$GCE_VM_NAME" \
--tags=vpc-producer-server \
--subnet="${VPC_NAME}-subnet-${GCP_REGION}" \
--zone=$GCP_ZONE \
--private-network-ip="$GCE_VM_PRIVATE_IP" \
--metadata startup-script='#!/bin/bash
sudo su -
apt update
apt install apache2 -y
apt install iperf3 -y
apt install hey -y
iperf3 -s &
echo "<h1>Hello World</h1>" > /var/www/html/index.html'
```

## Getting the base container image ready

The lab uses the [VPC Network Tester image](https://github.com/GoogleCloudPlatform/vpc-network-tester) from the official Google Cloud GitHub Repository. This tool deploys a simple website in Cloud Run so anyone can perform connectivity tests from Cloud Run through a graphical UI.

You will need to build the image and push it to Artifact Registry

### Creating a Docker repository in Artifact Registry

To build the image, first create a Docker repository in Artifact Registry to store the image:

```bash
AR_REPO_NAME=cloud-run-vpc
gcloud artifacts repositories create $AR_REPO_NAME \
--repository-format=docker \
--location=$GCP_REGION --description="Docker repo to store the images"
```

### Building and pushing the Docker image

Now, build and push the docker image using Cloud Build:

```bash
NETTEST_IMAGE_NAME=network-tester
gcloud builds submit https://github.com/willypalacin/vpc-network-tester \
  -t "$GCP_REGION-docker.pkg.dev/$GCP_PROJECT_ID/$REPO_NAME/$NETTEST_IMAGE_NAME" \
  --git-source-dir=cloudrun \
  --git-source-revision=main
```

## Deploying the services to Cloud Run

Now it's time to deploy two Cloud Run services that will be used to test the different connectivity scenarios, each one using a different method to connect to the VPC (Direct VPC Egress and Serverless VPC Access Connector).

### Deploying a service using Direct VPC Egress

You'll start by deploying the Direct VPC Egress service. 

Execute the following comand to deploy Cloud Run with VPC Egress setting. Requests to private address or internal DNS will henceforth routed to the VPC.

```bash
CR_DIRECT_SERVICE_NAME=direct-vpc-egress-service
gcloud beta run deploy $CR_DIRECT_SERVICE_NAME \
  --image="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${AR_REPO_NAME}/$NETTEST_IMAGE_NAME" \
  --network=$VPC_NAME \
  --subnet="${VPC_NAME}-subnet-${GCP_REGION}" \
  --network-tags=service-direct-egress \
  --region=$GCP_REGION \
  --vpc-egress=private-ranges-only \
  --allow-unauthenticated
```

Store the URL of the created service in an environment variable for later use:

```bash
CR_DIRECT_URL=$(gcloud run services describe direct-vpc-egress-service \
  --region=$REGION \
  --format='value(status.url)' --quiet 2>&1 >/dev/null)
```

In case you want all the request to be directed to the VPC —not only the ones targeting private addresses— you may deploy the Cloud Run service using the `--vpc-egress=all` option instead.

### Deploying a service using Serverless VPC Access Connector

Deploy a new Cloud Run service from the VPC Network Tester image in using the serverless VPC Accesss Connector that you created before, and making the service publicly accessible:

```bash
CR_CONNECTOR_SERVICE_NAME=vpc-access-connector-service
gcloud run deploy $CR_CONNECTOR_SERVICE_NAME \
--image="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${AR_REPO_NAME}/$NETTEST_IMAGE_NAME" \
--vpc-connector="connector-$VPC_NAME" \
--region=$GCP_REGION \
--allow-unauthenticated
```

Store the service URL in an environment variable for later use:

```bash
CR_CONNECTOR_URL=$(gcloud run services describe vpc-access-connector-service \
  --region=$REGION \
  --format='value(status.url)' --quiet 2>&1 >/dev/null)
```

## Finishing up the setup

The last step to finish the setup is to create the required firewall rules to allow ICMP (ping) and HTTP(S) between the Cloud Run service and the server running in the VPC.

1. Create the following rule to allow HTTP and ICMP connectivity between the `direct-vpc-egress-service` and the `packet-sniffer` instance. One of the main advantages you gain from using Direct VPC Egress is that we can use network tags  attached to our cloud run service to the firewall rules:

```bash
gcloud compute firewall-rules create allow-http-icmp-vpcdirect-to-gce \
  --network=$VPC_NAME \
  --action=ALLOW \
  --direction=INGRESS \
  --source-tags=service-direct-egress \
  --target-tags=vpc-producer-server \
  --rules=tcp:80,tcp:5201,icmp \
  --priority=900
```

In the case of the connection between the Cloud Run `vpc-access-connector-service` service and the `packet-sniffer` instance, an implicit firewall rule with priority 1000 is created on the VPC network to allow ingress from the connector's subnet or custom IP range to all destinations in the network. The implicit firewall rule is not visible in the Google Cloud console and exists only as long as the associated connector exists. 

However, the connector must be able to receive packets from the Google Cloud external IP address range 35.199.224.0/19. This rule will have to be configured explicit as a next step. Even though this range may seem like a public range, it is not publicly advertised and is used by underlying Google internal infrastructure to ensure that services from Cloud Run can send packets to the connector.

2. Configure the aforementioned firewall rule:
```bash
gcloud compute firewall-rules create internal-to-vpc-connector \
--action=ALLOW \
--rules=TCP \
--source-ranges=35.199.224.0/19 \
--target-tags=vpc-connector \
--direction=INGRESS \
--network=$VPC_NAME \
--priority=980
```

>>**Note**: `vpc-connector` is the universal connector network tag used to make the rule apply to all connectors in the VPC network.

3. Finally, in order to enable administrative SSH access from the Cloud Shell to our VM instance, as they both sit in different tenants, you need to allow ssh from the Identity Aware Proxy (IAP) range:
```bash
gcloud compute firewall-rules create allow-ssh-ingress-from-iap \
  --direction=INGRESS \
  --network=$VPC_NAME \
  --action=allow \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20
```

Now, come back to the [`README.md`](../README.md#testing-the-scenario) file to proceed with testing the different connectivity scenarios.