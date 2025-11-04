#!/usr/bin/env bash

#extracted from the following command

set -euo pipefail

# 1) grab all regions
regions=$(aws ec2 describe-regions --output text --query 'Regions[*].RegionName')

for region in $regions; do
  # 2) fetch only Master+Slave instances, any cluster
  data=$(aws ec2 --region "$region" describe-instances --filters \
    Name=tag:Role,Values=PostgreSQL \
    Name=tag:Environment,Values=Production \
    Name=instance-state-name,Values=running \
    Name=tag:PGRole,Values=Master,Slave \
    --output json | jq -r '
      def getTag(t): .Tags[]? | select(.Key==t) | .Value;
      [ .Reservations[].Instances[]
        | { cluster:getTag("Cluster")
          , role:getTag("PGRole")
          , name:getTag("Name")
          , az:.Placement.AvailabilityZone
          }
      ]
      | group_by(.cluster)[]
      | select((map(.role)|sort==["Master","Slave"]) and (map(.az)|unique|length==1))
      | sort_by(.role)       # Slave first
      | .[] 
      | "\(.cluster)\t\(.role)\t\(.name)\t\(.az)"'
  )

  # 3) if we got any rows, print region + header + data
  if [[ -n "$data" ]]; then
    echo "Region: $region"
    printf "%-25s %-6s %s\n" "Name" "Role" "AZ"
    printf "%-25s %-6s %s\n" "----" "----" "---"

    # format columns, blank line between clusters
    echo "$data" | awk -F'\t' '
      {
        if ($1 != prev) {
          if (NR>1) print ""
          prev = $1
        }
        printf "%-25s %-6s %s\n", $3, $2, $4
      }'
    echo
  fi
done
