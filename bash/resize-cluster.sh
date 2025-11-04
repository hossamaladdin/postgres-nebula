#!/usr/bin/env bash
# PostgreSQL Cluster Resize Template
# Generic template for resizing PostgreSQL cluster instances
# Supports primary, secondary, backup, and DR nodes

set -euo pipefail

# Configuration - Replace with your actual values
CLUSTER_ID="${CLUSTER_ID:-}"
NODE_ROLE="${NODE_ROLE:-}"  # primary|secondary|backup|dr
NEW_INSTANCE_TYPE="${NEW_INSTANCE_TYPE:-}"
DRY_RUN="${DRY_RUN:-0}"

# Constants
readonly WAIT_FOR_STABLE_COUNT=5
readonly SSH_RETRY_INTERVAL_SECONDS=3
readonly PROCESS_CHECK_INTERVAL_SECONDS=5
readonly REPLICATION_LAG_THRESHOLD_SECONDS=10
readonly POSTGRES_READY_TIMEOUT_SECONDS=60
readonly MUTE_DURATION_MINUTES=30

# Track performed actions for rollback
performed_actions=()

# Helper functions
die() { echo "[ERROR] $*" >&2; exit 1; }

log_info() { echo "[INFO] $*"; }

log_warn() { echo "[WARN] $*" >&2; }

confirm_yesno() {
    local prompt="$1"
    local ans
    while true; do
        read -rp "$prompt (y/n): " ans
        case "${ans,,}" in
            y) return 0 ;;
            n) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

push_action() { performed_actions+=("$1|$2"); }

cleanup_on_exit() {
    local exit_code=$?
    if ((exit_code != 0)) && ((${#performed_actions[@]} > 0)); then
        log_warn "Script exiting with error (code ${exit_code}). Reverting actions..."
        revert_actions
    fi
}

trap cleanup_on_exit EXIT ERR

revert_actions() {
    for ((i=${#performed_actions[@]}-1;i>=0;i--)); do
        local entry="${performed_actions[i]}"
        IFS='|' read -r typ data <<< "${entry}"
        case "${typ}" in
            dns)
                log_info "Reverting DNS: ${data}"
                # Implement your DNS reversion logic here
                ;;
            maintenance)
                log_info "Removing maintenance mode"
                # Implement your maintenance mode toggle here
                ;;
            monitoring)
                log_info "Un-muting monitoring"
                # Implement your monitoring un-mute here
                ;;
            *)
                log_warn "Unknown revert action: ${entry}"
                ;;
        esac
    done
    performed_actions=()
}

wait_for_ssh() {
    local host="$1"
    log_info "Waiting for SSH to ${host}..."
    while true; do
        if ssh "${host}" 'hostname -f' &>/dev/null; then
            log_info "SSH ready: ${host}"
            return 0
        fi
        sleep "${SSH_RETRY_INTERVAL_SECONDS}"
    done
}

wait_for_postgres() {
    local host="$1"
    local timeout="${POSTGRES_READY_TIMEOUT_SECONDS}"
    local elapsed=0

    log_info "Waiting for PostgreSQL on ${host}..."
    while ((elapsed < timeout)); do
        if ssh "${host}" 'pg_isready -q' &>/dev/null; then
            log_info "PostgreSQL is ready on ${host}"
            return 0
        fi
        sleep 2
        ((elapsed += 2))
    done

    die "PostgreSQL did not become ready within ${timeout}s"
}

check_replication_lag() {
    local host="$1"
    local lag_bytes

    lag_bytes=$(ssh "${host}" "psql -t -c \"SELECT COALESCE(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), 0) FROM pg_stat_replication LIMIT 1;\"" 2>/dev/null | tr -d ' ')

    if [[ -z "${lag_bytes}" ]] || [[ "${lag_bytes}" == "0" ]]; then
        return 0
    fi

    log_warn "Replication lag: ${lag_bytes} bytes"
    return 1
}

mute_monitoring() {
    local host="$1"
    local duration="${2:-${MUTE_DURATION_MINUTES}}"

    log_info "Muting monitoring for ${host} (${duration} minutes)"
    # Implement your monitoring mute command here
    # Example: monitoring-mute --host "${host}" --duration "${duration}"

    push_action "monitoring" "${host}"
}

enable_maintenance_mode() {
    log_info "Enabling maintenance mode for cluster ${CLUSTER_ID}"
    # Implement your maintenance mode toggle here
    # Example: maintenance-toggle --cluster "${CLUSTER_ID}" --mode maintenance

    push_action "maintenance" "${CLUSTER_ID}"
}

update_dns() {
    local record="$1"
    local new_value="$2"
    local old_value="$3"

    log_info "Updating DNS: ${record} -> ${new_value}"
    # Implement your DNS update logic here
    # Example: dns-update --record "${record}" --value "${new_value}"

    push_action "dns" "${record};;${old_value}"
}

resize_instance() {
    local instance_id="$1"
    local new_type="$2"

    log_info "Resizing instance ${instance_id} to ${new_type}"

    if [[ "${DRY_RUN}" == "1" ]]; then
        log_info "[DRY-RUN] Would resize ${instance_id} to ${new_type}"
        return 0
    fi

    # Stop instance
    aws ec2 stop-instances --instance-ids "${instance_id}"
    aws ec2 wait instance-stopped --instance-ids "${instance_id}"

    # Modify instance type
    aws ec2 modify-instance-attribute \
        --instance-id "${instance_id}" \
        --instance-type "${new_type}"

    # Start instance
    aws ec2 start-instances --instance-ids "${instance_id}"
    aws ec2 wait instance-running --instance-ids "${instance_id}"

    log_info "Instance ${instance_id} resized to ${new_type}"
}

resize_primary() {
    local instance_id="$1"
    local new_type="$2"

    log_info "=== Resizing Primary Node ==="

    # 1. Enable maintenance mode
    enable_maintenance_mode

    # 2. Mute monitoring
    mute_monitoring "${instance_id}"

    # 3. Check replication is healthy
    log_info "Checking replication health..."
    # Add replication checks here

    # 4. Resize instance
    resize_instance "${instance_id}" "${new_type}"

    # 5. Wait for SSH
    wait_for_ssh "$(get_instance_ip "${instance_id}")"

    # 6. Wait for PostgreSQL
    wait_for_postgres "$(get_instance_ip "${instance_id}")"

    log_info "Primary resize complete"
}

resize_secondary() {
    local instance_id="$1"
    local new_type="$2"

    log_info "=== Resizing Secondary Node ==="

    # 1. Mute monitoring
    mute_monitoring "${instance_id}"

    # 2. Resize instance
    resize_instance "${instance_id}" "${new_type}"

    # 3. Wait for SSH
    wait_for_ssh "$(get_instance_ip "${instance_id}")"

    # 4. Wait for PostgreSQL
    wait_for_postgres "$(get_instance_ip "${instance_id}")"

    # 5. Verify replication
    log_info "Verifying replication..."
    sleep 10
    check_replication_lag "$(get_instance_ip "${instance_id}")"

    log_info "Secondary resize complete"
}

get_instance_ip() {
    local instance_id="$1"
    aws ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Resize PostgreSQL cluster instances with safety checks.

OPTIONS:
    -c, --cluster CLUSTER_ID    Cluster ID
    -r, --role ROLE            Node role (primary|secondary|backup|dr)
    -t, --type INSTANCE_TYPE   New EC2 instance type
    -i, --instance INSTANCE_ID EC2 instance ID
    -d, --dry-run              Dry run mode
    -h, --help                 Show this help

EXAMPLES:
    # Resize primary node
    $0 -c 123 -r primary -t m5.2xlarge -i i-0123456789abcdef0

    # Resize secondary node (dry run)
    $0 -c 123 -r secondary -t m5.xlarge -i i-0abcdef0123456789 -d

ENVIRONMENT VARIABLES:
    CLUSTER_ID           - Cluster identifier
    NODE_ROLE            - Node role
    NEW_INSTANCE_TYPE    - Target instance type
    DRY_RUN              - Set to 1 for dry run

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--cluster) CLUSTER_ID="$2"; shift 2 ;;
        -r|--role) NODE_ROLE="$2"; shift 2 ;;
        -t|--type) NEW_INSTANCE_TYPE="$2"; shift 2 ;;
        -i|--instance) INSTANCE_ID="$2"; shift 2 ;;
        -d|--dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

# Validate required parameters
[[ -z "${CLUSTER_ID}" ]] && die "Cluster ID required (-c)"
[[ -z "${NODE_ROLE}" ]] && die "Node role required (-r)"
[[ -z "${NEW_INSTANCE_TYPE}" ]] && die "Instance type required (-t)"
[[ -z "${INSTANCE_ID:-}" ]] && die "Instance ID required (-i)"

# Main execution
log_info "Starting cluster resize:"
log_info "  Cluster: ${CLUSTER_ID}"
log_info "  Role: ${NODE_ROLE}"
log_info "  New Type: ${NEW_INSTANCE_TYPE}"
log_info "  Instance: ${INSTANCE_ID}"
[[ "${DRY_RUN}" == "1" ]] && log_warn "DRY RUN MODE"

if ! confirm_yesno "Proceed with resize?"; then
    log_info "Resize cancelled by user"
    exit 0
fi

case "${NODE_ROLE}" in
    primary)
        resize_primary "${INSTANCE_ID}" "${NEW_INSTANCE_TYPE}"
        ;;
    secondary)
        resize_secondary "${INSTANCE_ID}" "${NEW_INSTANCE_TYPE}"
        ;;
    backup|dr)
        # Backup and DR nodes can be resized similar to secondaries
        resize_secondary "${INSTANCE_ID}" "${NEW_INSTANCE_TYPE}"
        ;;
    *)
        die "Unknown role: ${NODE_ROLE}"
        ;;
esac

log_info "=== Resize Complete ==="
