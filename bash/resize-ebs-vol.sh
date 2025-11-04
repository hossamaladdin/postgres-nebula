#!/usr/bin/env bash
# shrink_ebs_patroni.sh
# Safely replace a Patroni master node's data volume with a smaller EBS volume
# Requires: awscli, jq, ec2-metadata

set -euo pipefail

NEW_SIZE_GB="${1:-}"
DEVICE_PATH="${2:-/dev/xvdf}"

if [[ -z "$NEW_SIZE_GB" ]]; then
  echo "Usage: $0 <new_size_gb> [device_path]"
  exit 1
fi

echo "=== Detecting instance and attached data volume ==="
INSTANCE_ID=$(ec2-metadata -i | awk '{print $2}')
VOL_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[].Instances[].BlockDeviceMappings[?DeviceName=='$DEVICE_PATH'].Ebs.VolumeId" \
  --output text)

if [[ -z "$VOL_ID" ]]; then
  echo "❌ Could not determine EBS volume for device $DEVICE_PATH"
  exit 1
fi

echo "Current volume ID: $VOL_ID"

echo "=== Creating snapshot of current volume ==="
SNAP_ID=$(aws ec2 create-snapshot \
  --volume-id "$VOL_ID" \
  --description "Shrink Patroni data volume from $VOL_ID" \
  --query 'SnapshotId' --output text)
echo "Snapshot: $SNAP_ID"

echo "Waiting for snapshot to complete..."
aws ec2 wait snapshot-completed --snapshot-ids "$SNAP_ID"

echo "=== Capturing existing volume attributes ==="
VOL_JSON=$(aws ec2 describe-volumes --volume-ids "$VOL_ID" --output json)
AZ=$(echo "$VOL_JSON" | jq -r '.Volumes[0].AvailabilityZone')
TYPE=$(echo "$VOL_JSON" | jq -r '.Volumes[0].VolumeType')
IOPS=$(echo "$VOL_JSON" | jq -r '.Volumes[0].Iops // empty')
THROUGHPUT=$(echo "$VOL_JSON" | jq -r '.Volumes[0].Throughput // empty')
ENCRYPTED=$(echo "$VOL_JSON" | jq -r '.Volumes[0].Encrypted')
KMS_KEY=$(echo "$VOL_JSON" | jq -r '.Volumes[0].KmsKeyId // empty')
TAGS=$(echo "$VOL_JSON" | jq -c '.Volumes[0].Tags')

echo "Availability Zone: $AZ"
echo "Volume Type: $TYPE"
echo "New Size: ${NEW_SIZE_GB}GB"

echo "=== Creating smaller volume from snapshot ==="
CREATE_ARGS=(
  --snapshot-id "$SNAP_ID"
  --availability-zone "$AZ"
  --size "$NEW_SIZE_GB"
  --volume-type "$TYPE"
  --tag-specifications "ResourceType=volume,Tags=$TAGS"
)

[[ -n "$IOPS" ]] && CREATE_ARGS+=(--iops "$IOPS")
[[ -n "$THROUGHPUT" ]] && CREATE_ARGS+=(--throughput "$THROUGHPUT")
[[ "$ENCRYPTED" == "true" && -n "$KMS_KEY" ]] && CREATE_ARGS+=(--encrypted --kms-key-id "$KMS_KEY")

NEW_VOL_ID=$(aws ec2 create-volume "${CREATE_ARGS[@]}" --query 'VolumeId' --output text)
echo "New smaller volume ID: $NEW_VOL_ID"

echo "Waiting for new volume to be available..."
aws ec2 wait volume-available --volume-ids "$NEW_VOL_ID"

echo "=== Stopping Patroni ==="
sudo systemctl stop patroni || true

echo "=== Detaching old volume ==="
aws ec2 detach-volume --volume-id "$VOL_ID"
echo "Waiting for detachment..."
aws ec2 wait volume-available --volume-ids "$VOL_ID"

echo "=== Attaching new volume ==="
aws ec2 attach-volume --volume-id "$NEW_VOL_ID" --instance-id "$INSTANCE_ID" --device "$DEVICE_PATH"

echo "Waiting for new volume to attach..."
aws ec2 wait volume-in-use --volume-ids "$NEW_VOL_ID"

echo "=== Mounting and validating new data volume ==="
sudo mkdir -p /var/lib/pgsql/data
sudo mount "$DEVICE_PATH" /var/lib/pgsql/data
sudo chown -R postgres:postgres /var/lib/pgsql/data

echo "=== Restarting Patroni ==="
sudo systemctl start patroni
sleep 5
sudo systemctl status patroni --no-pager

echo "✅ Shrink operation complete."
echo "Old volume: $VOL_ID"
echo "New volume: $NEW_VOL_ID (size=${NEW_SIZE_GB}GB)"
