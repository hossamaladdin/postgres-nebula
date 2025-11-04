# Get the volume id - the output is wide, so for slack legibility I've added an awk
$ ec2s.sh -R ? -c 336 -g Master | awk '{print $NF}'
Volumes
===============================
vol-05a0fab4d67737c7a:/dev/sda1
vol-0b0d34d5ca417b17f:/dev/sdf

#or run on the instance itself
aws-list-volumes

# pump up sdf
aws ec2 modify-volume --volume-id vol-0b0d34d5ca417b17f --iops 6000