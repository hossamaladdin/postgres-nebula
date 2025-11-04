#!/bin/bash

usage() {
  echo "Usage:"
  echo "  $0 --tag <KEY_OR_VALUE> [--region <REGION>]"
  echo "  $0 --role <ROLE_VALUE> [--region <REGION>]"
  exit 1
}

TAG_SEARCH=""
ROLE_SEARCH=""
REGION_FILTER=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --tag)
      TAG_SEARCH="$2"
      shift; shift
      ;;
    --role)
      ROLE_SEARCH="$2"
      shift; shift
      ;;
    --region)
      REGION_FILTER="$2"
      shift; shift
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$TAG_SEARCH" && -z "$ROLE_SEARCH" ]]; then
  usage
fi

search_region() {
  local region="$1"
  local search_type="$2"
  local search_value_lower
  search_value_lower=$(echo "$3" | tr '[:upper:]' '[:lower:]')

  echo "🔎 Region: $region"

  aws ec2 describe-instances --region "$region" --output json \
  | jq -r --arg search "$search_value_lower" --arg mode "$search_type" '
    .Reservations[].Instances[] 
    | select(.Tags != null) 
    | select(
        ($mode == "tag" and (
          [.Tags[]? | (.Key, .Value) | ascii_downcase | contains($search)] | any
        )) 
        or 
        ($mode == "role" and (
          [.Tags[]? | select(.Key == "Role") | .Value | ascii_downcase | contains($search)] | any
        ))
      )
    | {
        Name: (.Tags[]? | select(.Key=="Name") | .Value // "-"),
        Cluster: (.Tags[]? | select(.Key=="Cluster") | .Value // "-"),
        DNS: (if .PublicDnsName != "" then .PublicDnsName else "private:" + .PrivateDnsName end),
        InstanceId: .InstanceId,
        IP: .PrivateIpAddress
      }
    | [.Name, .Cluster, .DNS, .InstanceId, .IP] 
    | @tsv'
}

if [[ -n "$ROLE_SEARCH" ]]; then
  if [[ -n "$REGION_FILTER" ]]; then
    search_region "$REGION_FILTER" "role" "$ROLE_SEARCH"
  else
    for region in $(aws ec2 describe-regions --query "Regions[*].RegionName" --output text); do
      search_region "$region" "role" "$ROLE_SEARCH"
    done
  fi
elif [[ -n "$TAG_SEARCH" ]]; then
  if [[ -n "$REGION_FILTER" ]]; then
    search_region "$REGION_FILTER" "tag" "$TAG_SEARCH"
  else
    for region in $(aws ec2 describe-regions --query "Regions[*].RegionName" --output text); do
      search_region "$region" "tag" "$TAG_SEARCH"
    done
  fi
fi
