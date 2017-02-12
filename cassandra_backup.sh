#!/bin/bash
#
# Script to perform backups

## Source
[ -f /usr/local/lib64/bash/mysql_common ] && { source /usr/local/lib64/bash/mysql_common ; } || { echo "Missing MySQL includes" ; exit 1 ; }

## Stated Constants
MYSQL_TABLE='backups'
DATA_DIR_LIST=($(ls /|grep data))
NODETOOL=/usr/local/dse/bin/nodetool

TMPDIR=/var/tmp
LOG=/var/log/cassandra_backups.log
DATE=$(date "+%Y%m%d %H:%M:%S")

LOCK_DIR=/var/lock/cassandra_backups
PIDFILE="${LOCK_DIR}/pid.txt"

HOSTNAME=$(facter --puppet tmx_hostname)
EMAIL=ppacheco@threatmetrix.com

REMOTEDIR=cassandra_backups
USERMODULE=backups
PASSWORD=backups

## Variables
backup_date=$(date +%Y%m%d)
backup_time=$(date +%Y%m%d-%H%M)


## Functions
logger () {
    curl -G --data-urlencode "script=${0}" --data-urlencode "status=${1}" --data-urlencode "node=${HOSTNAME}"  http://tools101.ops:8880/hubot/radio  > /dev/null 2>&1
}
# kill -9 command causes non-zero result, which makes the script die.
# Subsequent runs of the script work however.  Still, this needs to be fixed.

function process_handler() {
    if [ -f ${PIDFILE} ] ; then
    # If there's a PIDFILE and if the process exists, kill it
        pid=$(cat ${PIDFILE})
        ps -p ${pid} 2>&1 >/dev/null ; status=$?
        [[ ${status} -eq 0 ]] && { kill -9 ${pid} ; echo "$(date '+%Y%m%d %H:%M:%S'):status=${status}:process_handler killed process=$pid" >>$LOG ; }
    fi
    echo "$$" >$PIDFILE
}

function email_message() {
    echo "date: $(date)"
    echo "host: ${HOSTNAME}"
    echo ""
    cat ${TMPDIR}/${ks}-${backup_time}.err
    echo ""
}

function error_handler() {
    if [ "$?" -ne "0" ]; then
        # Commented for testing, please uncomment
        echo $(email_message) |mail -s "[Cassandra Backup Failure on ${HOSTNAME}" ${EMAIL}
        trap 'clean_up' INT TERM EXIT
        exit 255
    fi
}
# Here is where the script consults the nodetrack DB to identify the few valid backup servers, and if it's a scheduled backup day.
function my_sql_checks() {
    state=$(mysql --user=${OPS_MYSQL_REMOTE_USER} --password=${OPS_MYSQL_REMOTE_PASS} --host=${OPS_MYSQL_HOST} -D ${DB_NODETRACK} \
                  -s -N -e "select state from ${DB_NODETRACK}.${MYSQL_TABLE} where client_server = '${HOSTNAME}';")
    [[ "${state}" -ne 1 ]] && { echo "Backups are disabled For this client.  Consult the nodetrack DB" ; exit 0 ; }

    dow=$(mysql --user=${OPS_MYSQL_REMOTE_USER} --password=${OPS_MYSQL_REMOTE_PASS} --host=${OPS_MYSQL_HOST} -D ${DB_NODETRACK} \
                -s -N -e "select dow from ${DB_NODETRACK}.${MYSQL_TABLE} where client_server = '${HOSTNAME}';")
    [[ "${dow}" -ne "$(date +%w)" ]] && { echo "No Backup scheduled for today" ; exit 0 ; }

    backuphost=$(mysql --user=${OPS_MYSQL_REMOTE_USER} --password=${OPS_MYSQL_REMOTE_PASS} --host=${OPS_MYSQL_HOST} -D ${DB_NODETRACK} \
                        -s -N -e "select storage_server from ${DB_NODETRACK}.${MYSQL_TABLE} where client_server = '${HOSTNAME}';")
}

function clean_up() {
    echo "$(date '+%Y%m%d %H:%M:%S'):status=${status}:Clearning snapshot for ${backup_date}" >>${LOG}
    ${NODETOOL} -h ${HOSTNAME} clearsnapshot -t ${backup_date} 2>&1
    unset ${RSYNC_PASSWD}
    [ -f "${TMPDIR}/*-${backup_time}" ] && { rm -fv "${TMPDIR}/*-${backup_time}" ; }
    [ -f "${PIDFILE}" ] && { rm -fv "${PIDFILE}" ; }
}

function full_backup() {
    logger starting_backup
    echo "$(date '+%Y%m%d %H:%M:%S'):status=${status}:Storage_server=${backuphost}:starting backup" >>$LOG
    # Make all non-system and non-OpsCenter keyspaces into an array variable
    keyspace_list=($(echo "DESCRIBE KEYSPACES;" |/usr/local/dse/bin/cqlsh $(hostname -i) |sed 's/[ ]\+/\n/g'|egrep -v 'system|dse|OpsCenter|^$'))
    echo "$(date '+%Y%m%d %H:%M:%S'):backup starting:Storage_Server=${backuphost}" >>${LOG}
    error_count=0
    export RSYNC_PASSWORD=${PASSWORD}
    for ks in ${keyspace_list[*]}; do
        # Make a list of ColumnFamilies A.K.A Tables for given KeySpace
        cf_list=($(ls -1 /data/cassandra/data/${ks}))
        # Create Snapshot for $ks
        error_handler
        for cf in ${cf_list[*]}; do
            for datadir in ${DATA_DIR_LIST[*]} ; do
        	${NODETOOL} -h ${HOSTNAME} snapshot -t ${backup_date} -cf $cf $ks >${TMPDIR}/${ks}-${backup_time}.err 2>&1 >/dev/null
                # Isert a trailing slash in the sourcepath file after correcting the write permissions of the script
                sourcepath=/${datadir}/cassandra/data/${ks}/${cf}/snapshots/${backup_date}
                destination=rsync://${USERMODULE}@${backuphost}.threatmetrix.com/${USERMODULE}/${REMOTEDIR}/${HOSTNAME}/${ks}/${cf}
                num_files=$(ls ${sourcepath} |wc -l)
                source_file_count=$(ls /${datadir}/cassandra/data/${ks}/${cf} |egrep -v snapshots |wc -l)
                dir_size=$(du -sh ${sourcepath} |cut -f1)
                if [ ${num_files} -gt 0 ] ; then
                    rsync -av  --password-file=/etc/rsync/rsync_sysbackup.passwd -L --progress --bwlimit 25600 ${sourcepath} ${destination} >${TMPDIR}/${ks}-${BACKUP_TIME}.err 2>&1
                    status=$?
                    echo "$(date '+%Y%m%d %H:%M:%S'):status=${status}:rsync=${sourcepath}:storage_server=${backuphost}:CF_file_count=${source_file_count}:snapshot_file_count=${num_files}:directory_size=${dir_size}" >>${LOG}
                    [ ${status} -ne 0 ] && error_count=$((${error_count} + 1))
                else
                    echo "$(date '+%Y%m%d %H:%M:%S'):status=${status}:rsync=${sourcepath}:storage_server=${backuphost}:CF_file_count=${source_file_count}:snapshot_file_count=${num_files}:snapshot path is empty" >>${LOG}
                fi
        	${NODETOOL} -h ${HOSTNAME} clearsnapshot ${ks} -t ${backup_date} 2>&1
            done
        done
    done
}

## Preflight
# Extra cautionary
function preflight() {
    ${NODETOOL} -h ${HOSTNAME} clearsnapshot 2>&1
    [ -d ${LOCK_DIR} ] || { mkdir -p ${LOCK_DIR} ; }
    # Confirm C* is running otherwise bail
    service_status=$( ( [[ -e /service/dse ]] && { svstat /service/dse ; } || { svstat /service/cassandra ; } ) |awk '{print $2}' )
    [[ $service_status == 'up' ]] || { logger "Failed:Cassandra not running" ; echo "$(date '+%Y%m%d %H:%M:%S'):$?:backup failed, cassandra offline" >>${LOG} ; exit 99 ; }
}
#
## Main
#
## First see if the node is scheduled for backups before even running preflight or process handler
my_sql_checks #Am I a backup client?  Is today my backup day?
preflight
process_handler
full_backup
clean_up
echo "$(date '+%Y%m%d %H:%M:%S'):$?:backup complete:storage_server=${backuphost}:number_of_errors=${error_count}" >>${LOG}
logger "${HOSTNAME} completed backup with number of errors=${error_count}"
