#!/usr/bin/env bash

set -euo pipefail

# Verify AWS tags for instances listed in clusters_expected.csv
# Input CSV columns: RegionShort,Cluster,Primary,Secondary,Backup,DR,Test,Beta
# Output CSV: clusters_verified.csv with columns:
# Cluster,InstanceId,RegionQueried,Tag:Cluster,Tag:Role,Tag:PGRole,Tag:Environment,Status

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expect_file="${script_dir}/clusters_expected.csv"
output_file="${script_dir}/clusters_verified.csv"

# mapping of shortname to aws region
map_region() {
  case "$1" in
    pdx) echo "us-west-2" ;;
    iad) echo "us-east-1" ;;
    cmh) echo "us-east-2" ;;
    yul) echo "ca-central-1" ;;
    sin) echo "ap-southeast-1" ;;
    syd) echo "ap-southeast-2" ;;
    fra) echo "eu-central-1" ;;
    dub) echo "eu-west-1" ;;
    *) echo "" ;;
  esac
}

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not found in PATH"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found in PATH"
  exit 1
fi

# write header
printf 'Cluster,InstanceId,RegionQueried,Tag:Cluster,Tag:Role,Tag:PGRole,Tag:Environment,Status,Volumes\n' > "$output_file"

# helper to normalize cluster tag (accept '368' or 'c368')
normalize_cluster() {
  local v="$1"
  [[ -z "$v" ]] && echo "" && return
  if [[ "$v" =~ ^c[0-9]+$ ]]; then
    echo "$v"
  elif [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "c${v}"
  else
    echo "$v"
  fi
}

# mapping column index -> expected role and environment
get_expected() {
  local col="$1"
  case "$col" in
    1) printf '%s\t%s' "Master" "Production" ;;
    2) printf '%s\t%s' "Slave" "Production" ;;
    3) printf '%s\t%s' "Backup" "Production" ;;
    4) printf '%s\t%s' "DR" "Production" ;;
    5) printf '%s\t%s' "Standalone" "Test" ;;
    6) printf '%s\t%s' "Standalone" "Beta" ;;
    *) printf '%s\t%s' "" "" ;;
  esac
}

# Read CSV with RegionShort column. Skip header. Use while-read that preserves commas properly.
 tail -n +2 "$expect_file" | while IFS=, read -r region_short cluster primary secondary backup dr test beta; do
  aws_region=$(map_region "$region_short")
  if [[ -z "$aws_region" ]]; then
    echo "Unknown region shortname: $region_short for cluster $cluster" >&2
    aws_region=""
  fi

  cols=("$primary" "$secondary" "$backup" "$dr" "$test" "$beta")
  for idx in "${!cols[@]}"; do
    inst="${cols[$idx]}"
    [[ -z "$inst" ]] && continue
    col_index=$((idx+1))

    # describe in the specified region
    if [[ -n "$aws_region" ]]; then
      out=$(AWS_DEFAULT_REGION="$aws_region" aws ec2 describe-instances --instance-ids "$inst" --query 'Reservations[].Instances[]' --output json 2>/dev/null) || {
        printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$cluster" "$inst" "$aws_region" "<not-found>" "<not-found>" "<not-found>" "<not-found>" "describe-failed" >> "$output_file"
        continue
      }
    else
      out=$(aws ec2 describe-instances --instance-ids "$inst" --query 'Reservations[].Instances[]' --output json 2>/dev/null) || {
        printf '%s,%s,,%s,%s,%s,%s,%s\n' "$cluster" "$inst" "<not-found>" "<not-found>" "<not-found>" "<not-found>" "describe-failed" >> "$output_file"
        continue
      }
    fi

    # extract tags
    cluster_tag=$(jq -r '.[0].Tags[]? | select(.Key=="Cluster") | .Value' <<<"$out" || true)
    role_tag=$(jq -r '.[0].Tags[]? | select(.Key=="Role") | .Value' <<<"$out" || true)
    pgrole_tag=$(jq -r '.[0].Tags[]? | select(.Key=="PGRole") | .Value' <<<"$out" || true)
    env_tag=$(jq -r '.[0].Tags[]? | select(.Key=="Environment") | .Value' <<<"$out" || true)

    [[ -z "$cluster_tag" ]] && cluster_tag="<missing>"
    [[ -z "$role_tag" ]] && role_tag="<missing>"
    [[ -z "$pgrole_tag" ]] && pgrole_tag="<missing>"
    [[ -z "$env_tag" ]] && env_tag="<missing>"

    expected_role_env=$(get_expected "$col_index")
    expected_role=$(awk -F"\t" '{print $1}' <<<"$expected_role_env")
    expected_env=$(awk -F"\t" '{print $2}' <<<"$expected_role_env")

    expected_norm=$(normalize_cluster "$cluster")
    actual_norm=$(normalize_cluster "$cluster_tag")

    # role matching with synonyms and PGRole acceptance
    role_ok=0
    if [[ -n "$expected_role" ]]; then
      if [[ "$role_tag" == "$expected_role" || "$pgrole_tag" == "$expected_role" ]]; then
        role_ok=1
      else
        case "$expected_role" in
          Master)
            if [[ "$role_tag" == "Primary" || "$pgrole_tag" == "Primary" ]]; then role_ok=1; fi
            ;;
          Slave)
            if [[ "$role_tag" == "Secondary" || "$pgrole_tag" == "Secondary" ]]; then role_ok=1; fi
            ;;
          Standalone)
            if [[ "$pgrole_tag" == "Standalone" || "$role_tag" == "Standalone" ]]; then
              role_ok=1
            fi
            ;;
        esac
      fi
    else
      role_ok=1
    fi

    env_ok=0
    if [[ -z "$expected_env" ]]; then env_ok=1; else [[ "$env_tag" == "$expected_env" ]] && env_ok=1; fi

    status_parts=()
    [[ "$actual_norm" != "$expected_norm" ]] && status_parts+=("cluster-mismatch")
    if [[ "$role_tag" == "<missing>" && "$pgrole_tag" == "<missing>" ]]; then
      status_parts+=("role-missing")
    elif [[ $role_ok -eq 0 ]]; then
      status_parts+=("role-wrong")
    fi
    if [[ $env_ok -eq 0 ]]; then status_parts+=("env-wrong"); fi
    [[ ${#status_parts[@]} -eq 0 ]] && status="ok" || status="$(IFS=';'; echo "${status_parts[*]}")"

    # Gather volume information: DeviceName, VolumeId, Size, Iops, VolumeType
    volumes_field=""
    # extract device:vid pairs from instance JSON
    vol_pairs=$(jq -r '.[0].BlockDeviceMappings[]? | "\(.DeviceName)\t\(.Ebs.VolumeId)"' <<<"$out" 2>/dev/null || true)
    if [[ -n "$vol_pairs" ]]; then
      vol_entries=()
      while IFS=$'\t' read -r dev vid; do
        [[ -z "$vid" || "$vid" == "null" ]] && continue
        if [[ -n "$aws_region" ]]; then
          vinfo=$(AWS_DEFAULT_REGION="$aws_region" aws ec2 describe-volumes --volume-ids "$vid" --query 'Volumes[0].[VolumeId,Size,(Iops||`0`),VolumeType]' --output text 2>/dev/null) || vinfo="${vid} <vol-not-found>"
        else
          vinfo=$(aws ec2 describe-volumes --volume-ids "$vid" --query 'Volumes[0].[VolumeId,Size,(Iops||`0`),VolumeType]' --output text 2>/dev/null) || vinfo="${vid} <vol-not-found>"
        fi
        # vinfo format: vol-..., size, iops, type (tab/space separated)
        if [[ "$vinfo" == *"<vol-not-found>"* ]]; then
          vol_entries+=("${dev}:${vid}:<not-found>")
        else
          # ensure we have four fields
          read -r v_id v_size v_iops v_type <<<"$vinfo"
          # human-friendly size (GB) keep numeric
          vol_entries+=("${dev}:${v_id}:${v_size}GB:${v_iops}iops:${v_type}")
        fi
      done <<<"$vol_pairs"
      # join entries by '; '
      volumes_field=$(IFS='; '; echo "${vol_entries[*]}")
    else
      volumes_field=""
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$cluster" "$inst" "$aws_region" "$cluster_tag" "$role_tag" "$pgrole_tag" "$env_tag" "$status" "$volumes_field" >> "$output_file"

  done
done

printf 'Wrote %s\n' "$output_file"
