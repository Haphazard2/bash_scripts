#!/bin/bash
#
# This script will accept command line arguments, or will prompt you for options if you do not use any.
#
# It uses files found in $DATAFILES for host lists as well as command list options
# Regardless, this script will only restart the next host, once the prior host has come back online.
#
# Check these first to variables to see if they should be changed.
LOG=~/log/dse_actions.log
CURRENTVER=3.0.1-1

DATAFILES="$(dirname "$0")"/../conf
CLUSTERLIST=${DATAFILES}/clusterlist.txt
COMMANDLIST=${DATAFILES}/clustercommands.txt
PASSWDFILE=${DATAFILES}/simple_auth.txt
CASSDIR=/etc/dse/cassandra
#
### Command Line Arguments and Option prompts
#
## Command to execute
if [ -z "$1" ]
  then
    echo "Enter command to execute against $command by choosing from this list"
    cat $COMMANDLIST
    echo "" ; echo -n "Command: " ; read command
    grep -wq $command $COMMANDLIST
    [ $? -ne 0 ] && { echo "$command is an invalid option." ; exit 1 ; }
  else
    command=$1
    shift
    grep -wq $command $COMMANDLIST
    [ $? -ne 0 ] && { echo "$command is an invalid option." ; exit 2 ; }
  fi
#
## Cluster
if [ -z "$1" ]
  then
    # Prompt user for cluster to apply $command to
    echo "Enter cluster name or host name(s) for $command by choosing from this list"
    echo "Entering a cluster will apply $command to all hosts in the cluster.  Or you may choose individual host(s) to apply the command to:"
    echo "NOTE: Most commands will not work on non-DSE clusters."
    echo ""
    echo "${BASENAME} [command] [ cluster name or host list ]"
    cat $CLUSTERLIST
    echo ""
    echo -n "Cluster: "
    read cluster
    cat $CLUSTERLIST |grep -wq $cluster
    [ $? -ne 0 ] && { echo "$cluster is an invalid option." ; exit 3 ; }
    HOSTLIST=$(cat $DATAFILES/clusters/$cluster | egrep -v '^#')
  else
    # Determine if user entered a cluster name or host name(s) at command line.
    cat $CLUSTERLIST |grep -wq $1
    if [ $? -eq 0 ]
      then
	cluster=$1
	HOSTLIST=$(cat $DATAFILES/clusters/$cluster | egrep -v '^#')	    # Don't pull 'commented' hosts from the list
      else
	echo "$1 is not a cluster name.  Assuming host(s) instead.."
	HOSTLIST=$*
	cluster=$(cd $DATAFILES/clusters ; grep -wl "^$1" *)
	[ -z "$cluster" ] && { echo "a valid cluster could not be determined" ; exit 6 ; }
      fi
  fi
#
## More stated constants
#
TOKENFILE=${DATAFILES}/tokens/${cluster}_tokens
PORT=$(grep rpc_port $DATAFILES/$cluster/* |cut -d' ' -f2|tail -1)
JMXID=$(egrep -w ^$cluster $PASSWDFILE |awk '{print $2}')
JMXPASSWD=$(egrep -w ^$cluster $PASSWDFILE |awk '{print $3}')
DATESTAMP=$(date '+%Y%m%d')
#
## Functions
#
function init_tool {
    ssh $host " [ -x /etc/init.d/dse ] && { /etc/init.d/dse $1 2>&1 >/dev/null ; } || { /etc/init.d/cassandra $1 2>&1 >/dev/null ; } "
}
function nodetool_cmd {
    # There are combinations here.  With and without password requirements, and for a dse or cassandra instance.
    if [ -z "$JMXID" ]
      then
	ssh $host " [ -x /usr/bin/nodetool ] && { /usr/bin/nodetool -h localhost $* ; } \
	    || { /opt/company/cassandra/current/bin/nodetool -h localhost $* ; } "
      else
	ssh $host " [ -x /usr/bin/nodetool ] && { /usr/bin/nodetool  -u $JMXID -pw $JMXPASSWD -h localhost $* ; } \
	    || { /opt/company/cassandra/current/bin/nodetool  -u $JMXID -pw $JMXPASSWD -h localhost $* ; } "
      fi	
}
function master_nodetool {
    # There are combinations here.  With and without password requirements, and for a dse or cassandra instance.
    masterhost=$(tail -1 $TOKENFILE |awk '{print $1}')
    [ $masterhost == $host ] && masterhost=$(head -1 $TOKENFILE |awk '{print $1}')
    #
    if [ -z "$JMXID" ]
      then
	ssh $masterhost " [ -x /usr/bin/nodetool ] && { /usr/bin/nodetool -h localhost $* ; } \
            || { /opt/company/cassandra/current/bin/nodetool -h localhost $* ; } "
      else
        ssh $masterhost " [ -x /usr/bin/nodetool ] && { /usr/bin/nodetool  -u $JMXID -pw $JMXPASSWD -h localhost $* ; } \
            || { /opt/company/cassandra/current/bin/nodetool  -u $JMXID -pw $JMXPASSWD -h localhost $* ; } "
      fi
}
function drain_node {
    # Dont bother to drain node if cassandra isn't running.
    # look for actual processes, rather than relying on the init script
    if [ $(ssh $host pgrep -c -f cassandra) -gt 0 ]
      then
	echo "performing graceful nodetool drain on $host"
	nodetool_cmd disablethrift
	nodetool_cmd disablegossip
	nodetool_cmd drain
      else
	echo "cassandra not currently running on $host, node not drained"
      fi
}
function rolling_restart {
    drain_node
    init_tool stop
    echo "Starting DSE on $host and sleeping for 10 seconds"
    init_tool start
    sleep 10
    # Test for a healthy start of DSE, or fail and bomb out.
    init_tool status
    [ $? -eq 0 ] && { echo "waiting for $PORT to come up"; ssh $host "until netstat -nltp |grep -q $PORT ; do sleep 1; echo -n '.'; done" ; } ||
	{ echo "Cassandra failed to start on $host with exit status $?" ; \
	     ssh $host tail -50 /var/log/cassandra/output.log|grep -v Classpath:; exit $? ; }
}
function wipe_system {
    ssh $host "[ -d /data/cassandra/data ] && { rm -r /data/cassandra/* ; } || { rm -r /data/cassandra/* ; }" 
    ssh $host "[ -d /commit/cassandra ] && { rm -r /commit/cassandra/* ; } || { rm -r /commit/* ; }"
    ssh $host "[ -d /var/log/cassandra ] && { rm -r /var/log/cassandra/* ; } || { rm -r /opt/company/cassandra/shared/log/* ; }"
}
function push_config {
    ssh $host "[ -d ${CASSDIR}/BAK ] || mkdir ${CASSDIR}/BAK"  # Create a BAK dir if it does not already exist
    for file in $(ls ${DATAFILES}/$cluster)
      do
	# Backup $file if it exists and hasn't already been backed up today
	ssh $host "[ -f ${CASSDIR}/$file -a ! -f ${CASSDIR}/BAK/${file}.${DATESTAMP} ] && \
	mv ${CASSDIR}/${file} ${CASSDIR}/BAK/${file}.${DATESTAMP}"
	# If there is a $TOKENFILE, then dynamic config of cassandra.yaml will be performed
	if [ $file = cassandra.yaml -a -f $TOKENFILE ]
	  then
	    modify_conf
	    scp ${DATAFILES}/${cluster}/${host}.yaml $host:${CASSDIR}/cassandra.yaml
	    ssh $host "chown cassandra:cassandra ${CASSDIR}/cassandra.yaml"
	    [ -f ${DATAFILES}/${cluster}/${host}.yaml ] && rm ${DATAFILES}/${cluster}/${host}.yaml #cleanup
	  else
	    scp ${DATAFILES}/${cluster}/${file} $host:${CASSDIR}/${file}
	    ssh $host "chown cassandra:cassandra ${CASSDIR}/${file}"
	  fi
      done
}
function modify_conf {
    cp ${DATAFILES}/${cluster}/cassandra.yaml ${DATAFILES}/${cluster}/${host}.yaml
    token=$(grep -w ^$host $TOKENFILE |awk '{print $2}')
    broadcast=$(grep -w ^$host $TOKENFILE |awk '{print $3}')
    listen=$(grep -w ^$host $TOKENFILE |awk '{print $4}')
    ex ${DATAFILES}/${cluster}/${host}.yaml <<EOF
/initial_token:
s/initial_token:/initial_token: $token/
/listen_address:
s/listen_address:/listen_address: $listen/
/broadcast_address:
s/broadcast_address:/broadcast_address: $broadcast/
x
EOF
}
function removetoken {
    #
    token=$(grep -w ^$host $TOKENFILE |awk '{print $2}')
    #
    # First confirm that another removetoken operation is not currently in progress
    # NOTE: A flaw in the nodetool command prevents all but the one node from effectively using the "nodetool removetoken status" command.
    # This is why I am checking the ring for "Leaving"
    echo "Checking for an existing removetoken operation on $cluster"
    master_nodetool ring |egrep "Leaving"
    [ $? -eq 0 ] && { echo "token could not be removed while another removetoken operation is in progress" ; exit 4 ; }
    #
    # Second, prompt user for confirmation
    echo "This operation will remove $host from the cluster: $cluster"
    echo "are you sure you want to continue?  Type 'yes' to continue, type anything else to quit"
    read response
    case $response in
      yes|y|Yes|YES)
        drain_node
	init_tool stop
	sleep 10
	echo "removing token for $host in the background..."
	master_nodetool removetoken $token &
      ;;
      *)
	echo "Not performing removetoken for $host"
	exit 7
      ;;
    esac
}
function install_java {
    ssh $host dpkg -l | grep -q oracle-java6
    if [ $? -ne 0 ] 
      then
        # keys, yo!
	ssh $host "wget http://apt_server.company.com/company.key -O - | apt-key add -"
	ssh $host "curl -s http://apt_server.company.com/company.key | apt-key add -"
	# Oracle Java 6 install
	ssh $host "echo 'deb [arch=amd64] http://apt_server.company.com/oracle-java lucid main' > /etc/apt/sources.list.d/company-oracle-java.list"
	ssh $host "apt-get update"
	ssh $host "apt-get -y --no-install-recommends --allow-unauthenticated install oracle-java6"
	STATUS=$?
	echo "$(date)	$STATUS $host upgraded to oracle-java6" >> $LOG
      else
	echo "Oracle Java6 already installed on $host"
      fi
}
#
### Main
#
for host in $HOSTLIST
  do
    START=$(date '+%s')
    #
    case $command in
      test)
	echo "host=$host"
	echo "command=$command"
	echo "cluster=$cluster"
	echo "PORT=$PORT"
	echo "JMXID=$JMXID"
	echo "JMXPASSWD=$JMXPASSWD"
	echo "DATESTAMP=$DATESTAMP"
	echo "TOKENFILE=$TOKENFILE"
      ;;
      config)
	echo "Kicking off a rolling config change of all the files found in ${DATAFILES}/$cluster"
	echo "This script will back up the files on each host to ${CASSDIR}/BAK"
	push_config
	rolling_restart
	STATUS=$?
      ;;
      rebuild)
	echo "under construction" 
	exit 0
	#[ $(wc -w $HOSTLIST) > 1 ] && { echo "the rebuild operation can only be performed on a single host" ; exit 69 ; }
	#echo "The complete process to replace a failed node."
	#echo "You will be put into a vim session for zone file modification."
	#echo "Your CNAME new entry (containing ec2 instance details) will be echo'd just before the vim session, so just scroll up and copy paste."
	#echo "Don't forget to roll the serial number.  All the repo stuff is done for you."
	#drain_node
	#init_tool stop
	## These external scripts will promt the user for input if $* is not present.
	## The external scripts also handle logging.
	#$(basedir $0)/build_instance.sh $host $2 $3
	#$(basedir $0)/install_dse.sh $host $4
	#$0 config $host
      ;;	
      restore)
	echo "Restoring backed up config files on $host"
	echo "Under construction"
	#ssh $host "for file in $(ls $CASSDIR/BAK/*.${DATESTAMP}) ; do cp $file    "
      ;;
      restart)
	rolling_restart
	STATUS=$?
      ;;
      stop)
	drain_node
	init_tool stop
	STATUS=$?
      ;;
      start)
	drain_node
	init_tool start
	STATUS=$?
      ;;
      removetoken)
	echo "Removing $host from the cluster using a nodetool removetoken command"
	removetoken
	STATUS=$?
      ;;
      repair)
	nodetool_cmd repair -pr
	STATUS=$?
      ;;
      snapshot)
	nodetool_cmd snapshot
	STATUS=$?
      ;;
      clearsnapshot)
	nodetool_cmd clearsnapshot
	STATUS=$?
      ;;
      cleanup)
	nodetool_cmd cleanup
	STATUS=$?
      ;;
      upgrade)
	echo "Current version is identified as $CURRENTVER. Please '[CTRL]+c now and update the variable in this script if it is incorrect."
	echo "Be sure to save your existing config files if necessary before executing this command!"
	echo ""
	# Checking Current version on $host
	version=$(ssh $host dpkg -l dse |tail -1 |awk '{print $3}')
	if [[ -z "$version" || $version != $CURRENTVER ]]
	 then
	  # Stopping
	    drain_node
	    init_tool stop
	  # Checking for / installing oracle-java6
	    install_java
	  # Installing
	    ssh $host "[ -f /etc/apt/sources.list.d/puppetlabs.list ] && rm /etc/apt/sources.list.d/puppetlabs.list"
	    scp ${DATAFILES}/dse.list $host:/etc/apt/sources.list.d/dse.list
	    ssh $host "curl -L http://debian.datastax.com/debian/repo_key | apt-key add -"
	    ssh $host "apt-get update"
	    ssh $host "apt-get install -y -o "DPkg::Options::=--force-confold" dse-full opscenter"
	  # brute force make and set ownership of required directories.
	    ssh $host "mkdir /data/cassandra ; chown -R cassandra:cassandra /data/cassandra ; mkdir -p /commit/cassandra ; chown -R cassandra:cassandra /commit"
	    push_config
	    rolling_restart
	    STATUS=$?
	    echo ""
	  else
	    echo "dse already installed on $host"
	    STATUS=2
	  fi
      ;;
      wipe)
	echo "WARNING: Performing this action will remove a node from the ring and totally wipe out it's configuration."
	echo "This action is useful only for starting all over with a hosed node."
	echo "are you sure you wish to continue? [no]:" ; read answer
	case answer in 
	  yes|Y|Yes|YES|FoShizzle)
	    drain_node
	    init_tool stop
	    wipe_system
	    echo ""
	    echo "$(date)	$STATUS $host completed $command in $(expr $FINISH - $START) seconds" >> $LOG
	    echo "completed $command on $host"
	    ;;
	  *)
	    echo ""
	    exit 420
	    ;;
	esac
      ;;
      info)
	echo "$host	$PORT	$(ssh $host dpkg -l dse |tail -1 |awk '{print $3}')	 $(cd ${DATAFILES}/clusters ; grep -wl ^$host *)"
      ;;
      *)
	echo "Invalid command. Try using this script with no arguments to be prompted for valid options."
	exit 5
      ;;
    esac
    FINISH=$(date '+%s')
    if [ $command != info ]
      then
	echo ""
	echo "$(date)	$STATUS $host completed $command in $(expr $FINISH - $START) seconds" >> $LOG
	echo "completed $command on $host"
      fi
  done
