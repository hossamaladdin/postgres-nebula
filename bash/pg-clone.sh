#!/usr/bin/env bash


# Load shared helpers
# shellcheck disable=SC1091
. /usr/local/lib/bash-helpers/load || exit 1

# Load server-meta-info
# shellcheck disable=SC1091
. /etc/server-meta-info || die 1 "There is no server-meta-info?!"

# Global config
lock_file="/var/run/pg-clone.lock"
aws_temp_volume_device='/dev/sdz'
real_temp_volume_device='' # is set after aws-add-volume call in add_temp_volume function
min_temp_volume_size=50
clone_port=5566
max_wait_time=600 # How long, in seconds to wait for cloned pg to accept connections.
new_line=$'\n'    # This is just so I can output multi line strings a bit easier.
cleanup_only=0
status_only=0
debug_mode=

### Functions that implement most of the functionality ###

# Output given message, with timestamp, but only if debug_mode variable is set
debug_info() {
    [[ -n "${debug_mode}" ]] && printf '%(%Y-%m-%d %H:%M:%S)T : %s\n' -1 "${*//$'\n'/$'\n    '}"
}


# Remove potentially existing "leftovers" from previous runs - pg itself, mounted data, snapshot, snapshot volume
cleanup_existing_leftovers() {
    local volume_dev pv_name vg_name tmp_out

    # Stop 14/clone Pg if it exists
    if [[ -f /mnt/pg-clone/14/main/postmaster.pid ]]
    then
        sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /mnt/pg-clone/14/main/ -m immedaite stop &>/dev/null
    fi

    # Remove leftover 14/clone configuration
    [[ -e /etc/postgresql/14/clone ]] && rm -rf /etc/postgresql/14/clone

    # Unmount snapshot, if it's mounted
    if grep -qP '\s/mnt/pg-clone\s' /proc/mounts
    then
        debug_info '/mnt/pg-clone is mounted, unmounting'
        debug_info 'Killing potential processes in there, so that umount will not break'
        # fuser can't be called via safe_run, because if there are no processes there, it ends with !=0 status, and this would break
        # pg-clone itself.
        tmp_out="$( fuser -v -m /mnt/pg-clone -k -9 2>&1 )"
        debug_info "Fuser/kill output:${new_line}${tmp_out}"
        safe_run umount /mnt/pg-clone
    fi

    # Destroy clone snapshot, if it exists
    if lvs pg | grep -qP '^\s*pgclone\s'
    then
        debug_info 'pgclone snapshot exists, getting rid of it'
        safe_run lvremove -f /dev/pg/pgclone
    fi

    # Check if the temp volume exists
    volume_dev="$( aws-list-volumes -ft | awk -v "d=${aws_temp_volume_device}" '$2==d {print $1}' )"
    # If it doesn't return, state looks to be clear.
    [[ -z "${volume_dev}" ]] && return

    # Check if temp volume is part of lvm
    IFS=$'\t' read -r pv_name vg_name < <(
        pvs --reportformat json |
            jq --arg v "/dev/${volume_dev}" -r '.report[].pv[] | select( .pv_name == $v ) | [ .pv_name, .vg_name ] | @tsv'
    )
    if [[ -n "${vg_name}" ]]
    then
        debug_info "Volume ${pv_name} is part of ${vg_name} VG. Reducing…"
        safe_run vgreduce "${vg_name}" "${pv_name}"
    fi
    if [[ -n "${pv_name}" ]]
    then
        debug_info "Volume ${pv_name} is active PV for LVM on this host. Removing…"
        safe_run pvremove "${pv_name}"
    fi

    # All ready to drop the EBS volume
    safe_run aws-drop-volume -q -y "${volume_dev}"
}


# Runs given command, exiting if it failed.
safe_run() {
    local cmd=( "$@" )
    local temp_output
    debug_info "Running: ${cmd[*]}"
    if ! temp_output="$( "${cmd[@]}" 2>&1 9>&- )"
    then
        die 1 "Running [${cmd[*]}] failed:${new_line}${temp_output}"
    fi
    [[ -n "${temp_output}" ]] && debug_info "Result:${new_line}${temp_output}"
}


# Adds new volume to be used as snapshot buffer
add_temp_volume() {
    local want_size
    want_size="$(
        df -P -BG /var/lib/postgresql/ |
            awk -v "min=${min_temp_volume_size}" '
                $NF=="/var/lib/postgresql" {
                    z=$(NF-3);
                    sub(/G$/, "", z);
                    new_size = z / 3;
                    if (new_size < min) {
                        new_size = min;
                    }
                    printf "%d\n", new_size;
                }
            '
    )"

    safe_run timeout 2m aws-add-volume -y -q -l "${aws_temp_volume_device:(-1)}" "${want_size}"

    real_temp_volume_device="/dev/$( aws-list-volumes -ft | awk -v "d=${aws_temp_volume_device}" '$2==d {print $1}' )"

    safe_run pvcreate "${real_temp_volume_device}"

    safe_run vgextend pg "${real_temp_volume_device}"
}


# Makes snapshot of pg volume using newly made buffer volume
make_pg_snapshot() {
    local tablespace_link tablespace_path tmp_out
    safe_run lvcreate -l 100%PVS -s -n pgclone /dev/pg/pgdata "${real_temp_volume_device}"
    safe_run mkdir -p /mnt/pg-clone
    safe_run mount -t xfs -o rw,nouuid,noatime,nofail,allocsize=1m /dev/pg/pgclone /mnt/pg-clone

    debug_info 'Re-linking data1 tablespace in cloned pg'
    while IFS=$'\t' read -r tablespace_link tablespace_path
    do
        [[ "${tablespace_path}" == "/var/lib/postgresql/tablespaces/data1" ]] || continue
        rm -f "${tablespace_link}"
        ln -s /mnt/pg-clone/tablespaces/data1/ "${tablespace_link}"
    done < <( find /mnt/pg-clone/14/main/pg_tblspc -type l -printf '%p\t' -exec readlink {} + )

    debug_info 'Preparing configuration for 14/clone Pg'
    rsync -a --delete /etc/postgresql/14/main/ /etc/postgresql/14/clone/
    cat /etc/postgresql/14/clone/postgresql.base.conf > /etc/postgresql/14/clone/postgresql.conf
    perl -pi -e 's#14([-/])main#14${1}clone#g' /etc/postgresql/14/clone/*.conf /etc/postgresql/14/clone/conf.d/*.conf
    perl -pi -e 's/-p 100 -c 10.*-d 10/-p 2 -c 2 -r %f -a %p -d 1/' /etc/postgresql/14/clone/conf.d/recovery.conf
    cat > /etc/postgresql/14/clone/conf.d/99-zz-clone.conf << _END_OF_CONFIG_
log_autovacuum_min_duration = -1
log_checkpoints             = off
log_connections             = off
log_destination             = stderr
log_disconnections          = off
log_duration                = off
log_lock_waits              = off
log_min_duration_sample     = -1
log_min_duration_statement  = -1
log_statement               = none
log_statement_sample_rate   = 0
log_statement_stats         = off
log_temp_files              = -1
log_transaction_sample_rate = 0
log_directory               = 'log'
recovery_target             = 'immediate'
port                        = ${clone_port}
data_directory              = '/mnt/pg-clone/14/main/'
shared_buffers              = 128MB
_END_OF_CONFIG_

    debug_info 'Making sure that pid file in clone is gone.'
    rm -f /mnt/pg-clone/14/main/postmaster.pid

    debug_info 'Starting cloned Pg'
    tmp_out="$(
        sudo -u postgres /usr/lib/postgresql/14/bin/pg_ctl -D /mnt/pg-clone/14/main/ -l /var/log/postgresql/postgresql-14-clone.log -o "-c config_file=/etc/postgresql/14/clone/postgresql.conf" -s -w start
    )"
    [[ -n "${tmp_out}" ]] && debug_info "Starting pg output:${new_line}${tmp_out}"

    # Check if the pg backend seems to exist
    # We have to do it that way, instead of checking pg_ctl status, as not always Pg is "up" within pg_ctl timeout
    fuser -m /mnt/pg-clone &>/dev/null || die 1 "There is no Pg running in /mnt/pg-clone!"

    debug_info "Pg seems to be running there, it might take a while to fully start…"
}


# Wait, up to configured time (max_wait_time), for cloned pg to accept connections
wait_for_working_cloned_pg() {
    local stop_waiting_at
    stop_waiting_at="$(( EPOCHSECONDS + max_wait_time ))"
    local is_ok=no
    local tmp_out

    while true
    do
        (( EPOCHSECONDS > stop_waiting_at )) && break
        tmp_out="$( sudo -u postgres psql -p "${clone_port}" -d postgres -U postgres -c 'select 123' -qAtX 2>&1 )"
        if [[ "${tmp_out}" == "123" ]]
        then
            is_ok=yes
            break
        fi
        sleep 5
    done

    [[ "${is_ok}" == "no" ]] && die 1 "Cannot get working psql connection after ${max_wait_time} seconds…"
}


# All cleanup that might be needed on exit. Wee need shellcheck disable, because it's handling of trap's is broken-ish.
# shellcheck disable=SC2317
exit_cleanup() {
    local ret=$?

    if (( ret != 0 ))
    then
        # This exit was with non-zero status code - which means some error happened.
        # Make sure that we'd try to not leave anything behind

        # Avoid trap loops, they shouldn't happen, but better be safe
        trap - EXIT
        # This is edge-case situation, make sure we output some info"
        debug_mode="yes"

        debug_info "Program ended with error ${ret}, calling forced cleanup!"
        cleanup_existing_leftovers 9>&-
    fi

    # Make sure we don't leave lock file behind
    [[ -e "${lock_file}" ]] && rm -f "${lock_file}"

    # Exit keeping the retcode that was supposed to happen
    exit "${ret}"
}


# Shows help page and exits. Optionally shows error message, if given.
show_help_and_die() {
    # Print error message if given.
    local error_message="${1:-}"
    [[ -n "${error_message}" ]] && printf "Error: %s\n\n" "${error_message}" >&2

    # Print help page.
    cat << _EOH_
Syntax:
    $0 [ -c | -s ] [ -d ] [ -h ]

Options:
    -c - Just cleanup - get rid of extra pg, volume, snapshot, …
    -s - Show current status
    -d - Debug mode - prints various progress/debug information while working
    -h - This help page
_EOH_

    # Exit program with status OK if there was no error message, otherwise - not OK (1).
    [[ -n "${error_message}" ]] && exit 1
    exit
}


# Parses potential command line arguments and sets important variables.
process_cmdline() {
    local optname
    while getopts ':cdhs' optname
    do
        case "${optname}" in
            c)  cleanup_only=1                             ;;
            s)  status_only=1                              ;;
            d)  debug_mode="yes"                           ;;
            h)  show_help_and_die                          ;;
            *)  show_help_and_die "Bad option: -${OPTARG}" ;;
        esac
    done
    (( cleanup_only == 1 )) && (( status_only == 1 )) && show_help_and_die "You can't have both -s and -c!"
}


# All checks to make sure that environment is OK to make pg clone.
sanity_checks() {
    (( EUID == 0 )) || die 1 'This program has to run from root account.'
    [[ "${smi_aws_tag_pgrole:-}" == backup ]] || die 1 'This program is only to be run on backup nodes.'
}


# Helper function for show_current_status that simply outputs given data using standardized format.
status_line() {
    printf "%-40s : %s\n" "$1" "$2"
    shift 2
    local l
    for l in "$@"
    do
        printf "    %s\n" "$l"
    done
}


# Shows current status of cloned Pg
show_current_status() {
    local tmp_out
    tmp_out="$( pg_lsclusters -j | jq -r '.[] | select(.cluster == "clone") | select(.version="14") | select(.running == 1 ) | .port' )"
    if [[ -n "${tmp_out}" ]]
    then
        status_line "PG-Clone runs" "yes"
        status_line "PG-Clone port" "${tmp_out}"
        tmp_out="$(
            sudo -u postgres psql -qAtX -F, -d postgres -p "${tmp_out}" -c "
                select
                    pg_last_xact_replay_timestamp()::timestamp(0),
                    (now() - pg_last_xact_replay_timestamp())::INTERVAL(3)
            "
        )"
        status_line "Last replicated transaction timestamp" "${tmp_out%%,*}"
        status_line "Replication 'lag'" "${tmp_out##*,}"
    else
        status_line "PG-Clone runs" "no"
    fi

    if grep -qP '\s/mnt/pg-clone\s' /proc/mounts
    then
        status_line "/mnt/pg-clone mounted" "yes"
    else
        status_line "/mnt/pg-clone mounted" "no"
    fi

    tmp_out="$( lvdisplay /dev/pg/pgclone 2>/dev/null | awk '/Allocated to snapshot/ {print $NF}' )"
    if [[ -n "${tmp_out}" ]]
    then
        status_line "Snapshot (/dev/pg/pgclone) exists" "yes" "Allocated: ${tmp_out}"
    else
        status_line "Snapshot (/dev/pg/pgclone) exists" "no"
    fi

    tmp_out="$( aws-list-volumes -ft | awk -v "d=${aws_temp_volume_device}" '$2==d {printf "%s:%s\n", $3, $6}' )"
    if [[ -n "${tmp_out}" ]]
    then
        status_line "Snapshot volume (${aws_temp_volume_device}) exists" "yes"
        status_line "Volume ID" "${tmp_out%%:*}"
        status_line "Volume size:" "${tmp_out##*:} GB"
    else
        status_line "Snapshot volume (${aws_temp_volume_device}) exists" "no"
    fi

    exit 0
}
### Functions that implement most of the functionality ###

### Main program ###

# Make sure only one copy of this program can run at a time
exec 9>"${lock_file}" || exit 1
flock -n 9 || exit 0

# Make sure script PWD is viewable by anyone, to avoid problems with sudo running commands, like pg_ctl
cd /

debug_info "Running sanity checks"
sanity_checks

debug_info "Parsing/validating command line arguments"
process_cmdline "$@"

(( 1 == status_only )) && show_current_status 9>&-

debug_info "Removing (potential) leftovers from previous runs"
cleanup_existing_leftovers 9>&-
(( 0 == cleanup_only )) || exit 0

# New stuff will be made now, make sure this script will cleanup after itself, if it would break.
trap exit_cleanup EXIT

debug_info "Adding temp volume for snapshot data"
add_temp_volume

debug_info "Make snapshot of Pg volume"
make_pg_snapshot

debug_info "Waiting so that psql can connect"
wait_for_working_cloned_pg

debug_info "Cloned PG started at port ${clone_port}, in /mnt/pg-clone/14/main"

exit 0

# vim: set filetype=bash shiftwidth=4 expandtab smarttab softtabstop=4 tabstop=4 textwidth=132 :
