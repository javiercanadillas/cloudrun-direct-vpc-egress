#!/usr/bin/env bash
## bootstrap_artifacts: sets necessary artifacts for Cloud Run, Cloud Build and Cloud Deploy

## Prevent this script from being sourced
#shellcheck disable=SC2317
return 0  2>/dev/null || :

set -uo pipefail

## Main Script vars
# shellcheck disable=SC2128
script_name=$(basename "$BASH_SOURCE")
#shellcheck disable=SC2128
if [[ "$OSTYPE" == "darwin"* ]]; then
  hash greadlink || { echo "Please, install greadlink and try again."; exit 1; }
  script_dir=$(dirname "$(greadlink -f "$BASH_SOURCE")")
else # assume Linux
  script_dir=$(dirname "$(readlink --canonicalize --no-newline "$BASH_SOURCE")")
fi
workdir="$(dirname "$script_dir")"
log_file="/tmp/${script_name}.log"
# Redirect stderr only to logfile and duplicate stdout to file
exec 3>&1 &>"$log_file" 1> >(tee >(cat >&3))
echo "======= Starting log file on $(date -u) =======" >&2

## Default vars
skip_init=false
artifacts_subdir="artifacts"
infra_subdir="infra"
tf_command="apply"
get_artifacts_only=false

## Look & feel related vars
red=$(tput setaf 1)
green=$(tput setaf 2)
reset=$(tput sgr0)

## Format info messages with script name in green
info() {
  echo "${green}${script_name}${reset}: ${1}"
}

## Format error messages with script name in red
error() {
  echo "${red}${script_name}${reset}: ${1}"
}

show_help() {
  echo "
Name:         $script_name
Description:  Prepares the lab environment
Requires:     Running \"gcloud auth login\" first to loging with the GCP credentials and setting up
              GCP_PROJECT_ID and GCP_REGION environment variables
Options:      -h,   --help                              Show this help
              -ss, --skip-initial-setup                 Skip nettest container image building
              -dt, --destroy-terraform                  Destroy the Terraform configuration
              -ga,  --get-artifacts-only                Only get final artifacts and finish the local configuration"
}

## Check that project ID and region have been set by the student
check_env() {
  info "Checking environment configuration..."
  [[ -z ${GCP_PROJECT_ID+x} ]] &&
    { error "Project ID has not been set. Please, run \"export GCP_PROJECT_ID=<project_id>\" and try again."
      exit 1
    }
  gcloud config set project "$GCP_PROJECT_ID" --quiet || 
    {
      error "Error trying to read Project ID."
      exit 1
    }
  GCP_REGION=${GCP_REGION:-europe-west1}
  ZONE=${ZONE:-europe-west1-b}
}

## Set permissions for Cloud Build SA
set_cloudbuild_iam() {
  info "Setting the right permissions for Cloud Build..."
  
  gcloud services enable \
    cloudbuild.googleapis.com \
    cloudresourcemanager.googleapis.com \
    artifactregistry.googleapis.com \
    --quiet 1>&2 || {
  error "Failed to enable Cloud Build API"
    exit 1
  }

  local -r cloudbuild_sa="$(gcloud projects describe "$GCP_PROJECT_ID" \
    --format 'value(projectNumber)')@cloudbuild.gserviceaccount.com"
  
  declare -a roles_list=( 'editor'
                          'run.admin'
                          'resourcemanager.projectIamAdmin'
                          'iam.serviceAccountUser'
                          'artifactregistry.admin' )
  
  for role in "${roles_list[@]}"; do
    gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
    --member serviceAccount:"$cloudbuild_sa" \
    --role "roles/${role}" --quiet 1>&2 || {
      error "Failed to assign role $role to Cloud Build Service Account"
      exit 1
    }
  done
}

## Hydrate Terraform configuration
hydrate_terraform_config() {
  info "Hydrating terraform.tfvars.dist into terraform.tfvars..."
  envsubst < "$script_dir/$infra_subdir/terraform.tfvars.dist" > "/$script_dir/$infra_subdir/terraform.tfvars"
}

## Launch the Cloud Build pipeline
launch_pipeline() {
  info "Launching pipeline, this may take a while..."
  local -r tf_command="${1:-apply}" && shift

  gcloud builds submit "$script_dir/$infra_subdir" \
    --substitutions=_GCP_PROJECT_ID="$GCP_PROJECT_ID",_GCP_REGION="$GCP_REGION",_TF_COMMAND="$tf_command",_SKIP_INIT="$skip_init",_GET_ARTIFACTS_ONLY="$get_artifacts_only",_ARTIFACTS_SUBDIR="$artifacts_subdir" \
    --config "$script_dir/cloudbuild.yaml" --quiet 1>&2 || {
      error "Failed to launch pipeline"
      exit 1
    }
}

## Get resulting artifacts from GCS bucket
get_artifacts() {
  info "Getting artifacts from GCS bucket..."
  gsutil cp -r gs://"${GCP_PROJECT_ID}-${artifacts_subdir}"/* "$workdir"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_help "$@"
        exit 0
        ;;
      -ss|--skip-init-setup)
        skip_init=true
        shift
        ;;
      -ga|--get-artifacts-only)
        get_artifacts_only=true
        skip_init=true
        shift
        ;;
      -dt|--destroy-terraform)
        tf_command="destroy"
        shift
        ;;
      *)
        error "Unknown option: $1"
        show_help "$@"
        exit 1
        ;;
    esac
  done
}

## Main routine, follow configuration in sequential order
main() {
  info "Logging output to $log_file..."
  parse_args "${@}"
  check_env
  [[ $skip_init = false || $get_artifacts_only = false ]] && set_cloudbuild_iam
  hydrate_terraform_config
  launch_pipeline "$tf_command"
  get_artifacts
}

main "${@}"