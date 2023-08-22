# Direct VPC Egress turorial


The purpose of this tutorial is to provide a hands-on guide of the options we have to connect  **Cloud Run services to private resources** that sit on a VPC network (egress connectivity), such as VM instances or Cloud SQL, privately in Google Cloud. 

Currently, we have two ways to accomplish it:

1. **Serverless VPC Access:** This was the traditional way —and the only way we had, until now. It works by setting up a connector that consists of a group of VM instances of several types, depending on the throughput. The connector acts as a proxy between the  Cloud Run service application and the resources in the VPC network.

2. **Direct VPC Egress:** This is a new feature that was launched in preview on August 15th. It makes it possible to connect resources that sit on a VPC by directly assigning an internal IP from the VPC subnet to the Cloud Run service. This enables a new direct network path for communication, which allows for more throughput, no extra hops and lower latency.

In this setup, we will cover the steps to configure both methods and provide network diagnostic tools to highlight the differences between Direct VPC Egress and Serverless VPC Access. 

During this lab, we will build the following architecture, which consists of:

-  VPC with a subnet in us-central1
-  Cloud Run public service using the VPC Egress feature
- Cloud Run public service using the VPC Serverless Access Connector in us-central1
- Compute Engine instance acting as a webserver, where we will use tcpdump to analyze incoming network traffic

![Lab architecture](./architecture.gif)

Lab architecture
## Prerequisites 
Before starting make sure you have the following requirements: 
1. A Google [Cloud Project](https://cloud.google.com/resource-manager/docs/creating-managing-projects#gcloud)
2. Shell environment with `gcloud` and `git`

## Setup
- Make sure you are authorized to use the Google Cloud SDK 
```
gcloud auth login
```
- Define the variables we will use along the lab
```
export PROJECT_ID=<PROJECT_ID>
export REGION=us-central1
export VPC_NAME=vpc-producer
```
- Configure the project in the shell 

```
gcloud config set project $PROJECT_ID
```

- Enable the required APIs via the console 
```
gcloud services enable run.googleapis.com
gcloud services enable compute.googleapis.com
gcloud services enable artifactregistry.googleapis.com
gcloud services enable vpcaccess.googleapis.com
```


### Create the VPC 

 As shown in the reference architecture, we will be creating a custom mode VPC with a subnet in us-central1 with a the 10.0.1.0/24 IP range.


```
gcloud compute networks create $VPC_NAME --subnet-mode=custom

gcloud compute networks subnets create $VPC_NAME-subnet-$REGION --network=$VPC_NAME --region=$REGION --range=10.0.1.0/24
```

### Build the Tester Tool image
We will be using the [VPC Network Tester image](https://github.com/GoogleCloudPlatform/vpc-network-tester)  from the **Google Cloud Repository**. This tool deploys a simple website in Cloud Run so we can perform connectivity tests from Cloud Run through a graphical UI.
- Clone the repository from github: 

```
git clone https://github.com/GoogleCloudPlatform/vpc-network-tester

cd vpc-network-tester/cloudrun
``` 

- Build the docker image using `docker build`
```
docker build -t $REGION-docker.pkg.dev/$PROJECT_ID/cloud-run-lab/network-tester . 
```
- Create a Docker repository in Artifact Registry to store the image

```
gcloud artifacts repositories create cloud-run-lab \
--repository-format=docker \
--location=$REGION --description="Docker repo to store the images"
```
- Push the image to Artifact Registry

```
docker push $REGION-docker.pkg.dev/$PROJECT_ID/cloud-run-lab/network-tester
```

### Deploy to Cloud Run 
#### Direct VPC Egress


Let's start by deploying the Direct VPC Egress service first. 

As mentioned, this feature allows the Cloud Run service to get an IP directly on the subnet without the need of having underlying VMs acting as connectors. Since the connectivity to the VPC is direct, we have the folllowing benefits:

- **Lower latency and  higher throughput:**  By eliminating the need for connectors, which add extra hops in the network path.

- **Cost reduction**: Since do not have to pay for underliying instance to establish the connectiion  

 - **Granular network security** by using network tags directly on Cloud Run. 

At the time of writing this guide, Direct VPC Egress is in private preview, which means we may incur some limitations. However, this is likely to change in the future.

Some of the current limitations are: 

- It is only supported in the following regions:
    - us-central1
    - us-east1
    - europe-west1
    - europe-west3
    - asia-northeast1


- The maximum number of instances supported are 100.

- **No support for Cloud NAT** to exit to the internet through the VPC

Execute the follwing comand to deploy Cloud Run with VPC Egress setting. Requests to private address or internal DNS are routed to the VPC.

```
gcloud beta run deploy direct-vpc-egress-service \
  --image=$REGION-docker.pkg.dev/$PROJECT_ID/cloud-run-lab/network-tester \
  --network=$VPC_NAME \
  --subnet=$VPC_NAME-subnet-$REGION \
  --network-tags=service-direct-egress \
  --region=$REGION \
  --vpc-egress=private-ranges-only \
  --allow-unauthenticated
```
In case you want all the request to be directed to the VPC —not only the ones targeting private addresses— we can configure the following setting `--vpc-egress=all`

 ### Serverless VPC Access Connector

Serverless VPC Access is the traditional way to connect privately to your Virtual Private Cloud (VPC) network from serverless environments such as Cloud Run, App Engine or Cloud Funtions.

Serverless VPC Access is based on a resource called a connector, a group of instances attached to an specific VPC and region. Depending on the throughput we may choose diferent machine type in the VPC Serverless aceess connector 

| Machine type | Estimated throughput range in Mbps |
|---|---|
| f1-micro | 100-500 |
| e2-micro | 200-1000 |
| e2-standard-4 | 43200-16000 |

Serverless VPC Access can automatically increase the number of instances in your connector as traffic increases. You can specify the minimum and maximum number of connector instances allowed. The minimum must be at least 2 and the maximum can be at most 10.

In terms of networking a **/28 CIDR range** needs to be assigned to the connector.  Make sure that it does not overlap with any other CIDR ranges that are already in use on your network. Traffic that is sent through the connector into your VPC network will originate from the subnet or CIDR range that you specify (acting as a proxy as we will see later in this guide)

- To configure Serverless VPC Access in a new Cloud Run Service, we first need to configure the connector

```
gcloud compute networks vpc-access connectors create connector-$VPC_NAME \
--network=$VPC_NAME \
--region=$REGION \
--range=172.16.1.0/28 \
--min-instances=2 \
--max-instances=5 \
--machine-type=e2-micro 
```
- Deploy the VPC Network Tester image in a new Cloud Run service using the serverless VPC Accesss Connector and make it publicly accessible

```
gcloud run deploy vpc-access-conector-service \
--image=$REGION-docker.pkg.dev/$PROJECT_ID/cloud-run-lab/network-tester \
--vpc-connector connector-$VPC_NAME \
--region=$REGION \
--allow-unauthenticated
```

### Create the VM in the VPC
A VM instance will we created to  serve the following purposes: 
- Acting as a web server for testing HTTP requests.
- Running `tcpdump` to capture network traffic.

```
gcloud compute instances create packet-sniffer \
--tags vpc-producer-server \
--subnet=$VPC_NAME-subnet-$REGION \
--zone $REGION-a \
--metadata startup-script='#!/bin/bash
sudo su -
apt update
apt install apache2 -y
echo "<h1>Hello World</h1>" > /var/www/html/index.html'
```


### Create the firewall rules
The last step to finish the setup is to create the required firewall rules to allow icmp (ping) and http(s) between the Cloud Run services and the server running in the VPC

- Create the following rule to allow http and icmp connectivity between the `direct-vpc-egress-service` and the `packet-sniffer` instance. One of the main advantages we gain from using Direct VPC Egress is that we can use network tags  attached to our cloud run service to the firewall rules  

```
gcloud compute firewall-rules create allow-http-icmp-vpcdirect-to-gce \
  --network=$VPC_NAME \
  --action=ALLOW \
  --direction=INGRESS \
  --source-tags=service-direct-egress \
  --target-tags=vpc-producer-server \
  --rules=tcp:80,icmp \
  --priority=900
``````
In the case of the connection between the Cloud Run `vpc-access-connector-service` service and the `packet-sniffer` instance, an implicit firewall rule with priority 1000 is created on the VPC network to allow ingress from the connector's subnet or custom IP range to all destinations in the network. The implicit firewall rule is not visible in the Google Cloud console and exists only as long as the associated connector exists. 

However, the connector must be able to receive packets from the Google Cloud external IP address range 35.199.224.0/19. Even though this range may seem like a public range, it is not publicly advertised and is used by underlying Google internal infrastructure to ensure that services from Cloud Run, Cloud Functions, and App Engine can send packets to the connector.

- Configure the following rule 
```
gcloud compute firewall-rules create internal-to-vpc-connector \
--action=ALLOW \
--rules=TCP \
--source-ranges=35.199.224.0/19 \
--target-tags=vpc-connector \
--direction=INGRESS \
--network=$VPC_NAME \
--priority=980
```

Note: `vpc-connector` is the universal connector network tag used to make the rule apply to all connectors in the VPC network.

- Lastly, in order to enable administrative ssh access from the GCP console to our VM instance we need to allow ssh from the IAP range
```
gcloud compute firewall-rules create allow-ssh-ingress-from-iap \
  --direction=INGRESS \
  --network=$VPC_NAME \
  --action=allow \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20
```

### Test the scenario
### Conclusions





