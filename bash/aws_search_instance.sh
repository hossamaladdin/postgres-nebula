
total=0
for region in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
    echo "=== $region ==="
    # Get instances and all tags
    result=$(aws ec2 describe-instances --region "$region" --filters \
        "Name=tag:Role,Values=Bouncer" \
        "Name=tag:os,Values=noble" \
        --output text --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PrivateIpAddress,PublicIpAddress,Tags]')

    if [[ -z "$result" ]]; then
        echo "No matching instances found."
    else
        echo -e "InstanceId\tState\tType\tPrivateIP\tPublicIP\tTags"
        echo "$result" | while IFS=$'\t' read -r id state type priv pub tags; do
            echo -e "$id\t$state\t$type\t$priv\t$pub\t$tags"
            ((total++))
        done
    fi
    echo ""
done
echo "Total matching instances: $total"