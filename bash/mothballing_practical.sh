#!/usr/bin/env bash
# PostgreSQL Cluster Mothballing Procedures
# Generic template for decommissioning and managing PostgreSQL clusters
# Replace placeholders with your actual values

set -euo pipefail

# Configuration - Replace with your actual values
CLUSTER_ID="${CLUSTER_ID:-123}"
INSTANCE_ID="${INSTANCE_ID:-i-0123456789abcdef0}"
DB_NAME="${DB_NAME:-mydb}"
PG_VERSION="${PG_VERSION:-14}"
MONITORING_URL="${MONITORING_URL:-https://cluster.example.com}"

# Mute monitoring before starting
#================
echo "Step 1: Mute cluster monitoring"
echo "Command: mute-cluster -r 'mothballing' -h 2 -v -c ${CLUSTER_ID}"
echo "Replace with your monitoring tool command"

# Configure secondaries with Patroni
#================
echo ""
echo "Step 2: Configure secondaries"
aws ec2 create-tags --resources "${INSTANCE_ID}" --tags Key=Patroni,Value=True
echo "Wait for ansible-local to apply changes..."
# vsleep 100 && ansible-local run

echo "Standup new database replica:"
echo "sudo standup_new_db_replica.rb --stack myapp --cluster cluster${CLUSTER_ID}"

echo ""
echo "Check Patroni cluster status:"
echo "source /etc/profile.d/patroni-env.sh"
echo "sudo -E patronictl list"

echo ""
echo "If needed, restart Patroni member:"
echo "sudo -E patronictl restart myapp-production-cluster${CLUSTER_ID} \$(hostname)-${INSTANCE_ID}"

# Rebuilding secondary from a snapshot
#================
echo ""
echo "Step 3: Rebuild secondary from snapshot"
echo "Stop Patroni:"
echo "sudo systemctl stop patroni"

echo ""
echo "Restore from snapshot:"
echo "sudo snapshot_restore --recovery --volume-type gp3 --throughput 250 --iops 3000 --dont-start --instance --lvm <snapshot-id>"

echo ""
echo "If needed, kill PostgreSQL processes:"
echo "sudo pkill -9 -u postgres"

echo ""
echo "Clean data directories:"
echo "sudo rm -rf /var/lib/postgresql/tablespaces/data1/*"
echo "sudo rm -rf /var/lib/postgresql/${PG_VERSION}/main/*"

echo ""
echo "Start PostgreSQL manually if needed:"
echo "sudo -iu postgres /usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl start \\"
echo "  -D /var/lib/postgresql/${PG_VERSION}/main -s \\"
echo "  -o '-c config_file=/etc/postgresql/${PG_VERSION}/main/postgresql.conf' \\"
echo "  -l /var/log/postgresql/postgresql-${PG_VERSION}-main.log"

echo ""
echo "Start Patroni:"
echo "sudo systemctl start patroni"

# Configure backup server
#===============
echo ""
echo "Step 4: Configure backup server"
echo "Tag instance as backup:"
echo "aws ec2 create-tags --resources '${INSTANCE_ID}' --tags 'Key=PGRole,Value=Backup'"
echo "Wait for ansible-local to apply changes..."
# vsleep 100 && ansible-local run

echo ""
echo "Bless server as backup:"
echo "yes | postgresql_sentinel --type backup bless-self"

echo ""
echo "Run backup:"
echo "sudo snapshot_pgbackup"

# Configure DR server
#=================
echo ""
echo "Step 5: Configure DR (Disaster Recovery) server"
echo "Mute monitoring:"
echo "mute-host \$(hostname -f) --why 'rebuilding' --minutes 20"

echo ""
echo "Tag instance as DR:"
echo "aws ec2 create-tags --resources ${INSTANCE_ID} --tags 'Key=PGRole,Value=DR'"

echo ""
echo "Restore from snapshot:"
echo "sudo snapshot_restore --recovery --volume-type gp3 --throughput 250 --iops 3000 \\"
echo "  --dont-start --instance --lvm <snapshot-id>"

echo ""
echo "Configure recovery settings:"
echo "sudo sed -ie 's/^primary/# &/' /etc/postgresql/${PG_VERSION}/main/conf.d/recovery.conf"
echo "sudo perl -pi -e 's/-p 100 -c 10.*-d 10/-p 2 -c 2 -r %f -a %p -d 1/' \\"
echo "  /etc/postgresql/${PG_VERSION}/main/conf.d/recovery.conf"
echo "sudo cat /etc/postgresql/${PG_VERSION}/main/conf.d/recovery.conf"

echo ""
echo "Start PostgreSQL:"
echo "sudo systemctl start postgresql"
echo "sudo tail -f /var/log/postgresql/postgresql-${PG_VERSION}-main.log"

echo ""
echo "Verify recovery status:"
echo "psql -c 'select pg_is_in_recovery();'"
echo "psql -c 'select * from pg_control_checkpoint();' -d ${DB_NAME} -h cluster${CLUSTER_ID}-primary.example.com"

echo ""
echo "Compare checkpoints between DR and primary:"
echo "for host in {localhost,cluster${CLUSTER_ID}-primary.example.com}; do"
echo "    psql -d ${DB_NAME} -h \"\${host}\" -c 'select hostname(),timeline_id,checkpoint_lsn,redo_wal_file from pg_control_checkpoint()'"
echo "done"

# Handle LVM issues
#================
echo ""
echo "Step 6: If LVM is being used by PostgreSQL"
echo "See what's using it:"
echo "sudo lsof +D /var/lib/postgresql"

echo ""
echo "Kill processes:"
echo "sudo lsof +D /var/lib/postgresql | awk 'NR>1 {print \$2}' | sort -u | xargs -r sudo kill -9"

# Perform failover
#================
echo ""
echo "Step 7: Perform failover (run from new primary)"
echo "sudo -E patronictl switchover myapp-production-cluster${CLUSTER_ID} \\"
echo "  --candidate \$(hostname)-${INSTANCE_ID} --force"

# Health checks
#================
echo ""
echo "Step 8: Perform health checks"
echo "curl ${MONITORING_URL}/readiness | jq '.components[] | select(.status != 200)'"

# Update capacity planning
#================
echo ""
echo "Step 9: Update capacity planning database"
echo "psql -h capacity-planning-db.example.com -d capacity_planning -c \\"
echo "  \"update clusters set specialty = 'buffer' where cluster_id in (${CLUSTER_ID});\""

echo ""
echo "=== Mothballing procedure complete ==="
echo "Note: This is a template. Adapt commands to your infrastructure."
