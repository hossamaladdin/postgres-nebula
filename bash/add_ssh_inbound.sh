#!/bin/bash


set -e


# Accept source, target, and action (enable/disable)
if [[ -n "$1" ]]; then
  SOURCE_FQDN="$1"
else
  read -p "Enter source server hostname (FQDN): " SOURCE_FQDN
fi

if [[ -n "$2" ]]; then
  TARGET_FQDN="$2"
else
  read -p "Enter target server hostname (FQDN): " TARGET_FQDN
fi

if [[ -n "$3" ]]; then
  ACTION="$3"
else
  read -p "Enable or disable rule? (enable/disable): " ACTION
fi

if [[ "$ACTION" != "enable" && "$ACTION" != "disable" ]]; then
  echo "❌ ACTION must be 'enable' or 'disable'"
  exit 1
fi

# Resolve IP address of source server (cross-platform: dig/host/getent)
resolve_ip() {
  local fqdn="$1"
  local ip=""
  if command -v dig >/dev/null 2>&1; then
    ip=$(dig +short "$fqdn" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
  fi
  if [[ -z "$ip" ]] && command -v host >/dev/null 2>&1; then
    ip=$(host "$fqdn" | awk '/has address/ { print $4; exit }')
  fi
  if [[ -z "$ip" ]] && command -v getent >/dev/null 2>&1; then
    ip=$(getent ahosts "$fqdn" | awk '/STREAM/ {print $1; exit}')
  fi
  echo "$ip"
}

SOURCE_IP=$(resolve_ip "$SOURCE_FQDN")
if [[ -z "$SOURCE_IP" ]]; then
  echo "❌ Could not resolve IP from $SOURCE_FQDN"
  exit 1
fi

# Resolve IP address of target server
TARGET_IP=$(resolve_ip "$TARGET_FQDN")
if [[ -z "$TARGET_IP" ]]; then
  echo "❌ Could not resolve IP from $TARGET_FQDN"
  exit 1
fi

# Find instance ID of target based on private IP
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=$TARGET_IP" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [[ -z "$INSTANCE_ID" ]]; then
  echo "❌ Could not find EC2 instance with IP $TARGET_IP"
  CURRENT_REGION=$(aws configure get region 2>/dev/null || echo "not set")
  echo "    Current AWS region: $CURRENT_REGION"
  echo ""
  echo "⚠️  Are you sure you are in the right AWS region?"
  echo -n "Enter the correct region (or press Enter to keep current): "
  read NEW_REGION
  
  if [[ -n "$NEW_REGION" ]]; then
    echo "🔄 Searching for instance in region: $NEW_REGION"
    INSTANCE_ID=$(aws ec2 describe-instances \
      --region "$NEW_REGION" \
      --filters "Name=private-ip-address,Values=$TARGET_IP" \
      --query "Reservations[].Instances[].InstanceId" \
      --output text)
    
    if [[ -z "$INSTANCE_ID" ]]; then
      echo "❌ Still could not find EC2 instance with IP $TARGET_IP in region $NEW_REGION"
      exit 1
    else
      echo "✅ Found instance $INSTANCE_ID in region $NEW_REGION"
      AWS_REGION="$NEW_REGION"
    fi
  else
    echo "❌ Could not find EC2 instance with IP $TARGET_IP"
    exit 1
  fi
fi

# Get security groups of target instance and filter for GroupName = dba-toolbox
SG_ID=$(aws ec2 describe-instances \
  ${AWS_REGION:+--region "$AWS_REGION"} \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[].Instances[].NetworkInterfaces[].Groups[?GroupName=='dba-toolbox'].GroupId" \
  --output text)

if [[ -z "$SG_ID" ]]; then
  echo "❌ No security group named 'dba-toolbox' attached to instance $INSTANCE_ID"
  exit 1
fi

CIDR="$SOURCE_IP/32"
if [[ -z "$SOURCE_IP" ]]; then
  echo "❌ Could not get source server's IP"
  exit 1
fi


# Shorter rule name and clear description
RULE_NAME="SSH $SOURCE_FQDN → $TARGET_FQDN"
RULE_DESC="Allow SSH (22) from $SOURCE_FQDN ($SOURCE_IP) to $TARGET_FQDN ($TARGET_IP)"

echo ""
echo "⚠️  About to $ACTION SSH (port 22) access from ${SOURCE_IP}/32"
echo "    To instance: ${INSTANCE_ID}"
echo "    Resolved from: ${TARGET_FQDN}"
echo "    Security Group: ${SG_ID} (GroupName: dba-toolbox)"
echo "    Rule Name: $RULE_NAME"
echo "    Description: $RULE_DESC"
echo -n "Proceed? [y/N]: "
read CONFIRM

if [[ "$CONFIRM" != "y" ]]; then
  echo "❌ Aborted by user."
  exit 1
fi


if [[ "$ACTION" == "enable" ]]; then
  # Check if any port 22 rule for this IP exists (check text output properly)
  SG_OUTPUT=$(aws ec2 describe-security-groups ${AWS_REGION:+--region "$AWS_REGION"} --group-ids "$SG_ID" --output text)
  RULE_EXISTS=$(echo "$SG_OUTPUT" | awk '/IPPERMISSIONS.*22.*tcp.*22/{found=1; next} found && /IPRANGES.*'${SOURCE_IP//./\\.}'\/32/{print; exit}')

  if [[ -n "$RULE_EXISTS" ]]; then
    echo "⚠️  A rule for port 22 and ${SOURCE_IP}/32 already exists in $SG_ID."
    echo "    This may have a different name/description."
    echo -n "Proceed to add another rule anyway? [y/N]: "
    read ADD_ANYWAY
    if [[ "$ADD_ANYWAY" != "y" ]]; then
      echo "❌ Aborted by user."
      exit 1
    fi
    echo "Proceeding to add rule..."
  fi
  aws ec2 authorize-security-group-ingress \
    ${AWS_REGION:+--region "$AWS_REGION"} \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr "${SOURCE_IP}/32" \
    --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=Name,Value='$RULE_NAME'},{Key=Description,Value='$RULE_DESC'}]" >/dev/null 2>&1

  if [[ $? -eq 0 ]]; then
    echo "✅ Rule added successfully to $SG_ID"
  else
    echo "❌ Failed to add rule to $SG_ID"
  fi

elif [[ "$ACTION" == "disable" ]]; then
  # Check if any port 22 rule for this IP exists (check text output properly)
  SG_OUTPUT=$(aws ec2 describe-security-groups ${AWS_REGION:+--region "$AWS_REGION"} --group-ids "$SG_ID" --output text)
  RULE_EXISTS=$(echo "$SG_OUTPUT" | awk '/IPPERMISSIONS.*22.*tcp.*22/{found=1; next} found && /IPRANGES.*'${SOURCE_IP//./\\.}'\/32/{print; exit}')

  if [[ -z "$RULE_EXISTS" ]]; then
    echo "⚠️  No port 22 rule exists for ${SOURCE_IP}/32 in $SG_ID"
    exit 0
  fi

  echo "Found port 22 rule(s) for ${SOURCE_IP}/32 in $SG_ID"
  echo -n "Proceed to remove the rule(s)? [y/N]: "
  read REMOVE_CONFIRM
  if [[ "$REMOVE_CONFIRM" != "y" ]]; then
    echo "❌ Aborted by user."
    exit 1
  fi

  # Remove the rule using the old method (simpler and more reliable)
  aws ec2 revoke-security-group-ingress \
    ${AWS_REGION:+--region "$AWS_REGION"} \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr "${SOURCE_IP}/32" >/dev/null 2>&1

  if [[ $? -eq 0 ]]; then
    echo "✅ Rule removed successfully from $SG_ID"
  else
    echo "❌ Failed to remove rule from $SG_ID"
  fi
fi

echo "🏁 Done."