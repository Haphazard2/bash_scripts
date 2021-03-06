#!/bin/bash
#
source /usr/local/lib64/bash/mysql_common
backup_servers=(backup{101..107}.threatmetrix.com)
#
#Ordered by token range
#
### C* Node arrays
main_c_cluster=($(ssh main_c_cluster.threatmetrix.com /usr/local/dse/bin/nodetool ring |egrep ^10\.200 |awk '{print $1}'))
solr_cluster=($(ssh solr_cluster.threatmetrix.com /usr/local/dse/bin/nodetool ring |egrep ^10\.200\.36 |awk '{print $1}'))
offset=0        # Change which set of "every third node", valid numbers are 0 to $rf - 1
backup_day=1    # Delete this value to stripe backups across days of the week

i=0  # iterate through all the C* nodes in the array
x=0  # Array position of the backup server list
y=0  # Day of week: '+%w'
rf=3 # Replication Factor of cluster

echo "\"backup_type\",\"client_server\",\"backup_server\",\"state\",\"running\",\"dow\""
# Select every third node in the ring
while [[ $i -ne ${#main_c_cluster[@]} ]] ; do
    mod=$(($i % $rf))
    if [[ $mod -eq ${offset:-0} ]] ; then
        host=$(host ${main_c_cluster[$i]} |awk '{print $NF}' |sed 's/\.threatmetrix\.com\.//g')
        backup_server=$(echo ${backup_servers[$x]} |sed 's/\.threatmetrix\.com//g')
        #echo "\"casasandra\",\"${host}\",\"${backup_servers[$x]}\",\"1\",\"0\",\"${y}\""
        echo "	casasandra	$backup_server	$host	1	0	${y}"
        if [[ $x -eq $(( ${#backup_servers[@]} -1 )) ]] ; then
            x=0 
            [[ $y -eq 6 ]] && { y=0 ; } || { y=$(($y + 1)) ; }
        else
            x=$(($x + 1))
        fi
    fi
    i=$(( $i + 1))
done
# Slightly different requirements for the Solr cluster 
i=0
rf=3
while [[ $i -ne ${#solr_cluster[@]} ]] ; do
    mod=$(($i % $rf))
    if [[ $mod -eq 0 ]] ; then
        host=$(host ${solr_cluster[$i]} |awk '{print $NF}' |sed 's/\.threatmetrix\.com\.//g')
        backup_server=$(echo ${backup_servers[$x]} |sed 's/\.threatmetrix\.com//g')
        #echo "\"casasandra\",\"${host}\",\"${backup_servers[$x]}\",\"1\",\"0\",\"${y}\""
        echo "	casasandra	$backup_server	$host	1	0	${y}"
        [[ $x -eq $(( ${#backup_servers[@]} -1 )) ]] && { x=0 ; } || { x=$(($x + 1)) ; }
        [[ $y -eq 6 ]] && { y=0 ; } || { y=$(($y + 1)) ; }
    fi
    i=$(( $i + 1))
done

# I could automate this, but for now I'm dumping this script's output to a tmp file, and inserting it interactively via mysql (see below): 
# Then, using a mysql GUI, I delete all of the original rows, leaving only the new ones.
#
# mysql --user=${OPS_MYSQL_REMOTE_USER} --password=${OPS_MYSQL_REMOTE_PASS} --host=${OPS_MYSQL_HOST} -D ${DB_NODETRACK} -s -N
# mysql> LOAD DATA LOCAL INFILE '/tmp/backup.sql' INTO TABLE backups;
