# Option 2 - Setting up the required infrastructure through Terraform

Before proceeding, make sure you've met the prerequisites and have performed the initial setup as described in the corresponding [README section](../README.md#setting-up-the-environment-and-infrastructure) where you should be coming from.

## Setting up the environment

Proceed to setup the environment variables that will be required to launch the Terraform pipeline:

1. Make sure you're in your shell and that you're already in the directory where you cloned the repository:

```bash
cd cloud-run-direct-vpc-egress
```

2. Define the GCP Project ID and source the variables you will use along the lab:

```bash
GCP_PROJECT_ID=<your project id> # Replace with your project ID
```

If you wish a different Cloud Region and Zone other than `europe-west1` and `europe-west1-b`, then setup the corresponding environment variable, otherwise you can skip this step:

```bash
export GCP_REGION=<REGION> # Replace with your desired region
export GCP_ZONE=<ZONE> # Replace with your desired zone
```

## Launching the Terraform pipeline

Launch the `bootstrap_demo.bash` script that will deploy and run a Cloud Build pipeline to create the necessary Terraform infrastructure and supporting assets:

```bash 
cd cloud-run-direct-vpc-egress/assets
./bootstrap_demo.bash
```

You can check the status of the pipeline by running the following command:

```bash
gcloud builds list --project $GCP_PROJECT_ID
gcloud builds log <BUILD_ID> --project $GCP_PROJECT_ID # Replace with the ID of the build you want to check
```

or by going to the [Cloud Build console](https://console.cloud.google.com/cloud-build/builds?project=$GCP_PROJECT_ID) and checking the status of the pipeline.

You can also check the logs of the `bootstrap_demo.bash` script by running the following command in another terminal window:

```bash
tail -f /tmp/bootstrap_demo.log
```

Once the pipeline finishes successfully, configure your environment to proceed with the demo:

```bash
source $HOME/cloud-run-direct-vpc-egress/artifacts/demo.env
```
