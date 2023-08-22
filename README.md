# Direct VPC Egress tutorial

The purpose of this tutorial is to provide a hands-on guide of the options available to connect  **Cloud Run services to private resources** that sit on a VPC network. This kind of connection is known as egress connectivity, an example of such being Cloud Run establishing a private connection to a VM running on Google Compute Engion or to a Cloud SQL instance. 

Currently, there are two ways to accomplish it:

1. **Serverless VPC Access:** This was the traditional way —and the only way available in Google Cloud Platform, until the moment of the writing of this doc. It works by setting up a connector that consists of a group of VM instances of several types that depends on the throughput needed. This connector acts as a proxy between the Cloud Run service application and the resources in the VPC network that the service wants to connect to.

2. **Direct VPC Egress:** This is a new feature launched in Public Preview on August 15th 2003. It makes it possible for the Cloud Run service to connect to resources that sit on a VPC by directly assigning them an internal IP from the VPC subnet. This enables a new direct network path for communication, which allows for more throughput, no extra hops and lower latency.

In this setup, you will cogo through the steps to configure both connectivity options. The lab materials provide network diagnostic tools to highlight the differences between Direct VPC Egress and Serverless VPC Access. 

The lab steps rely on the following architecture diagram, that includes the following components:

- VPC with a subnet in us-central1
- Cloud Run public service using the VPC Egress feature
- Cloud Run public service using the VPC Serverless Access Connector in us-central1
- Compute Engine instance acting as a webserver, where we will use tcpdump to analyze incoming network traffic

![Lab architecture](./architecture.gif)
*Lab architecture*

## Prerequisites 
Before starting make sure you have the following requirements: 
1. A Google [Cloud Project](https://cloud.google.com/resource-manager/docs/creating-managing-projects#gcloud) with a billing account associated.
2. Shell environment with `gcloud` and `git`. Cloud Shell is recommended as it already has the required tools installed.

## Initial setup

1. Make sure you are authorized to use the Google Cloud SDK:

```bash
gcloud auth login
```

2. Define the variables you will use along the lab:

```bash
export PROJECT_ID=<PROJECT_ID> # Replace with your project ID
export REGION=europe-west1 # Feel free to change it to the region of your choice where the feature is available
export ZONE=europe-west1-b # Feel free to change it to an existing zone in the region you chose before
export VPC_NAME=vpc-producer
```

3. Configure the project:

```bash
gcloud config set project $PROJECT_ID
```

4. Enable the required APIs::

```bash
gcloud services enable run.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  vpcaccess.googleapis.com
```

### Creating the VPC 

 As shown in the reference architecture, you will be creating a custom mode VPC with a subnet in `$REGION`` with a the 10.0.1.0/24 IP range.

```bash
gcloud compute networks create $VPC_NAME --subnet-mode=custom
gcloud compute networks subnets create "${VPC_NAME}-subnet-$REGION" --network=$VPC_NAME --region=$REGION --range=10.0.1.0/24
```

### Build the Tester Tool image
The lab uses the [VPC Network Tester image](https://github.com/GoogleCloudPlatform/vpc-network-tester) from the official Google Cloud GitHub Repository. This tool deploys a simple website in Cloud Run so anyone can perform connectivity tests from Cloud Run through a graphical UI.

You will need to build the image and push it to Artifact Registry:

1. Clone the repository from Github: 

```bash
git clone https://github.com/GoogleCloudPlatform/vpc-network-tester
cd vpc-network-tester/cloudrun
``` 

2. Create a Docker repository in Artifact Registry to store the image:
```bash
gcloud artifacts repositories create cloud-run-lab \
--repository-format=docker \
--location=$REGION --description="Docker repo to store the images"
```

3. Build the docker image Cloud Build and push it to Artifact Registry:
```bash
gcloud builds submit -t $REGION-docker.pkg.dev/$PROJECT_ID/cloud-run-lab/network-tester . 
```

### Deploying to Cloud Run 

#### Deploying a service using Direct VPC Egress

You'll start by deploying the Direct VPC Egress service.

As mentioned before, this feature allows the Cloud Run service to get an IP directly on the subnet without the need of having underlying VMs acting as connectors. Since the connectivity to the VPC is direct, this optionn have the folllowing benefits:

- **Lower latency and  higher throughput** by way of eliminating the need for connectors, which add extra hops in the network path.
- **Cost reduction** since there's no need to pay for underliying instance to establish the connectiion  
- **Granular network security**, thanks to using network tags directly on Cloud Run. 

>>   **Note:**
>>   As at the time of writing this guide Direct VPC Egress is in Public preview, which means you may incur some limitations if the    service is still in Preview at the time of you following these instructions.
>>
>>  Some of the current limitations are: 
>>
>>  - It is only supported in the following regions:
>>      - us-central1
>>      - us-east1
>>      - europe-west1
>>      - europe-west3
>>      - asia-northeast1
>>    - The maximum number of instances supported are 100.
>>   - **No support for Cloud NAT** yet to exit to the internet through the VPC.

Execute the following comand to deploy Cloud Run with VPC Egress setting. Requests to private address or internal DNS will henceforth routed to the VPC.

```bash
gcloud beta run deploy direct-vpc-egress-service \
  --image="${REGION}-docker.pkg.dev/${PROJECT_ID}/cloud-run-lab/network-tester" \
  --network=$VPC_NAME \
  --subnet="${VPC_NAME}-subnet-${REGION}" \
  --network-tags=service-direct-egress \
  --region=$REGION \
  --vpc-egress=private-ranges-only \
  --allow-unauthenticated
```

In case you want all the request to be directed to the VPC —not only the ones targeting private addresses— you may deploy the Cloud Run service using the setting `--vpc-egress=all` instead.

#### Deploying a service using the Serverless VPC Access Connector

As mentioned in the initial sections of this doc, Serverless VPC Access is the traditional way to connect privately to a Virtual Private Cloud (VPC) network from a GCP serverless environment such as Cloud Run.

Serverless VPC Access is based on a resource called a *connector*, which is a group of instances attached to an specific VPC and Cloud Region. Depending on the desired throughput for the connection between the service and the VPC, you may choose diferent machine type in the VPC Serverless aceess connector:

| Machine type | Estimated throughput range in Mbps |
|---|---|
| f1-micro | 100-500 |
| e2-micro | 200-1000 |
| e2-standard-4 | 43200-16000 |

You may refer to the official documentation for more information on the [Serverless VPC Access Connector](https://cloud.google.com/vpc/docs/serverless-vpc-access#scaling) and up to date information regarding throughput numbers.

Serverless VPC Access can automatically increase the number of instances in your connector as traffic increases. You can specify the minimum and maximum number of connector instances allowed. The minimum must be at least 2 and the maximum can be at most 10.

In terms of networking a **/28 CIDR range** needs to be assigned to the connector.  Make sure that it does not overlap with any other CIDR ranges that are already in use on your network. Traffic that is sent through the connector into your VPC network will originate from the subnet or CIDR range that you specify, acting as a proxy as you will see later in this guide.

1. Configure the Serverless VPC Access Connector:

```bash
gcloud compute networks vpc-access connectors create "connector-$VPC_NAME" \
--network=$VPC_NAME \
--region=$REGION \
--range=172.16.1.0/28 \
--min-instances=2 \
--max-instances=5 \
--machine-type=e2-micro 
```

2. Deploy the VPC Network Tester image in a new Cloud Run service using the serverless VPC Accesss Connector and make it publicly accessible:

```bash
gcloud run deploy vpc-access-conector-service \
--image="${REGION}-docker.pkg.dev/${PROJECT_ID}/cloud-run-lab/network-tester" \
--vpc-connector="connector-$VPC_NAME" \
--region=$REGION \
--allow-unauthenticated
```

### Create the VM in the VPC

You will now create a VM instance to serve the following purposes for the lab: 

- Act as a web server for testing HTTP requests from the two Cloud Run services.
- Run `tcpdump` to capture network traffic.

```bash
gcloud compute instances create packet-sniffer \
--tags=vpc-producer-server \
--subnet="${VPC_NAME}-subnet-${REGION}" \
--zone=$ZONE \
--metadata startup-script='#!/bin/bash
sudo su -
apt update
apt install apache2 -y
echo "<h1>Hello World</h1>" > /var/www/html/index.html'
```

### Create the firewall rules
The last step to finish the setup is to create the required firewall rules to allow ICMP (ping) and HTTP(S) between the Cloud Run service and the server running in the VPC.

1. Create the following rule to allow HTTP and ICMP connectivity between the `direct-vpc-egress-service` and the `packet-sniffer` instance. One of the main advantages you gain from using Direct VPC Egress is that we can use network tags  attached to our cloud run service to the firewall rules:

```bash
gcloud compute firewall-rules create allow-http-icmp-vpcdirect-to-gce \
  --network=$VPC_NAME \
  --action=ALLOW \
  --direction=INGRESS \
  --source-tags=service-direct-egress \
  --target-tags=vpc-producer-server \
  --rules=tcp:80,icmp \
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

3. Lastly, in order to enable administrative ssh access from the Cloud Shell to our VM instance we need to allow ssh from the IAP range:
```bash
gcloud compute firewall-rules create allow-ssh-ingress-from-iap \
  --direction=INGRESS \
  --network=$VPC_NAME \
  --action=allow \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20
```

### Test the scenario
### Conclusions





