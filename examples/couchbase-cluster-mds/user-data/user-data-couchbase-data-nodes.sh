#!/bin/bash

set -e

# Send the log output from this script to user-data.log, syslog, and the console
# From: https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee /opt/couchbase/var/lib/couchbase/logs/mock-user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

source "/opt/couchbase-commons/couchbase-common.sh"
source "/opt/couchbase-commons/mount-volume.sh"

function mount_volumes {
  local readonly data_volume_device_name="$1"
  local readonly data_volume_mount_point="$2"
  local readonly volume_owner="$3"

  echo "Mounting EBS Volume for the data directory"
  mount_volume "$data_volume_device_name" "$data_volume_mount_point" "$volume_owner"
}

function run_couchbase {
  local readonly cluster_asg_name="$1"
  local readonly cluster_username="$2"
  local readonly cluster_password="$3"
  local readonly cluster_port="$4"
  local readonly data_dir="$5"
  local readonly data_ramsize="$6"
  local readonly index_ramsize="$7"
  local readonly fts_ramsize="$8"

  echo "Starting Couchbase data nodes"

  /opt/couchbase/bin/run-couchbase-server \
    --cluster-name "$cluster_asg_name" \
    --cluster-username "$cluster_username" \
    --cluster-password "$cluster_password" \
    --rest-port "$cluster_port" \
    --data-dir "$data_dir" \
    --node-services "data" \
    --use-public-hostname \
    --manage-memory-manually \
    --data-ramsize "$data_ramsize" \
    --index-ramsize "$index_ramsize" \
    --fts-ramsize "$fts_ramsize" \
    --wait-for-all-nodes
}

function create_test_resources {
  local readonly cluster_username="$1"
  local readonly cluster_password="$2"
  local readonly cluster_port="$3"
  local readonly user_name="$4"
  local readonly user_password="$5"
  local readonly bucket_name="$6"

  local readonly max_retries=120
  local readonly sleep_between_retries_sec=5

  echo "Creating user $user_name"

  run_couchbase_cli_with_retry \
    "Create RBAC user $user_name" \
    "SUCCESS:" \
    "$max_retries" \
    "$sleep_between_retries_sec" \
    "user-manage" \
    "--cluster=127.0.0.1:$cluster_port" \
    "--username=$cluster_username" \
    "--password=$cluster_password" \
    "--set" \
    "--rbac-username=$user_name" \
    "--rbac-password=$user_password" \
    "--rbac-name=$user_name" \
    "--roles=admin" \
    "--auth-domain=local"

  echo "Creating bucket $bucket_name"

  run_couchbase_cli_with_retry \
    "Create bucket $bucket_name" \
    "SUCCESS:" \
    "$max_retries" \
    "$sleep_between_retries_sec" \
    "bucket-create" \
    "--cluster=127.0.0.1:$cluster_port" \
    "--username=$user_name" \
    "--password=$user_password" \
    "--bucket=$bucket_name" \
    "--bucket-type=couchbase" \
    "--bucket-ramsize=100"
}

function run {
  local readonly cluster_asg_name="$1"
  local readonly cluster_port="$2"
  local readonly data_volume_device_name="$3"
  local readonly data_volume_mount_point="$4"
  local readonly volume_owner="$5"
  local readonly data_ramsize="$6"
  local readonly index_ramsize="$7"
  local readonly fts_ramsize="$8"

  # To keep this example simple, we are hard-coding all credentials in this file in plain text. You should NOT do this
  # in production usage!!! Instead, you should use tools such as Vault, Keywhiz, or KMS to fetch the credentials at
  # runtime and only ever have the plaintext version in memory.

  #
  # SECRET_VALUE=$(aws secretsmanager get-secret-value --secret-id \"${SECRET}\" --version-stage AWSCURRENT --region \"$region\" | jq -r .SecretString)\n
  # USERNAME=$(echo \"$SECRET_VALUE\" | jq -r .username)
  # PASSWORD=$(echo \"$SECRET_VALUE\" | jq -r .password)

  # local readonly cluster_username="$USERNAME"
  # local readonly cluster_password="$PASSWORD"

  mount_volumes "$data_volume_device_name" "$data_volume_mount_point" "$volume_owner"
  run_couchbase "$cluster_asg_name" "$cluster_username" "$cluster_password" "$cluster_port" "$data_volume_mount_point" "$data_ramsize" "$index_ramsize" "$fts_ramsize"

  local node_hostname
  local rally_point_hostname
  read _ node_hostname _ rally_point_hostname < <(/opt/couchbase-commons/couchbase-rally-point --cluster-name "$cluster_asg_name" --use-public-hostname "true")

  if [[ "$node_hostname" == "$rally_point_hostname" ]]; then
    echo "This node is the rally point for this cluster"

    # To keep this example simple, we are hard-coding all credentials in this file in plain text. You should NOT do this
    # in production usage!!! Instead, you should use tools such as Vault, Keywhiz, or KMS to fetch the credentials at
    # runtime and only ever have the plaintext version in memory.
    local readonly test_user_name="test-user"
    local readonly test_user_password="password"
    local readonly test_bucket_name="test-bucket"

    create_test_resources "$cluster_username" "$cluster_password" "$cluster_port" "$test_user_name" "$test_user_password" "$test_bucket_name"
  fi
}

# The variables below are filled in via Terraform interpolation
run \
  "${cluster_asg_name}" \
  "${cluster_port}" \
  "${data_volume_device_name}" \
  "${data_volume_mount_point}" \
  "${volume_owner}" \
  "${data_ramsize}" \
  "${index_ramsize}" \
  "${fts_ramsize}"

