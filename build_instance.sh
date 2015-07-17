#!/bin/bash
# Script to spin up an instance in ec2 and prep it for DSE installation.

host=$1
[ -z "$host" ] && { echo -n "\$1: Enter the host name you want to use for the new instance: " ; read host ; }

availzone=$2
[ -z "$availzone" ] && { echo -n "\$2: Enter availability zone: [RANDOM] " ; read availzone ; }

type=$3
[ -z "$type" ] && { echo -n "\$3: Enter instance type: [m2.2xlarge] " ; read type ; } 
[ -z $type ] && type=m2.2xlarge

# 'region=' is here for future expansion
region=us-east-1
ec2runfile=/tmp/ec2run.out
CONFDIR="$(dirname $0)"/../conf
OOZONE=/home/ppacheco/repo/bind/zones/pri/ooyala.com.zone
clusterlist=$CONFDIR/clusterlist.txt
log=~/log/ec2_instance.log

oldid=$(egrep -w `echo $host |sed 's/\.ooyala\.com//'` $OOZONE |egrep -v 'staging|us-ec2' |awk '{print $6}')

## Find cluster based on host name, or ask for one.

cluster=$(cd $CONFDIR/clusters ; grep -wl "^$host" *)
[ -z "$cluster" ] && { echo "A valid cluster could not be determined by $host." ; echo -n "Choose a cluster from this list: " ; echo "" ; cat $clusterlist; echo "" ; read cluster ; }
[ $(egrep -w ^"${cluster}" $clusterlist |awk '{print $1}') ] || { echo "invalid cluster chosen." ; exit 1 ; }

##Table Lookup
#
grouplist=$CONFDIR/security_groups.txt
SECURITYGROUP=$(egrep -v '^#' $grouplist |egrep -w $cluster |awk '{print $2}')
KEY=$(egrep -v '^#' $grouplist |egrep -w $cluster |awk '{print $3}')

#
## Main
#
set -x 

echo "creating instance in $region"
if [ -z "$availzone" ] 
  then
    ec2run $(~/scripts/dns_txt x86_64.ami.$region) --region=$region -g $SECURITYGROUP -g all-region-servers -k $KEY -t $type >$ec2runfile
  else
    ec2run $(~/scripts/dns_txt x86_64.ami.$region) --region=$region -g $SECURITYGROUP -g all-region-servers -k $KEY -t $type -z $availzone >$ec2runfile
  fi
# If ec2run fails
[ $? -ne 0 ] && { echo "error creating instance" ; exit 2 ; }
# log entry for host creation
id=$(cat $ec2runfile |tail -1 |awk '{print $2}')
STATUS=0
echo "$(date)	$STATUS $host completed ec2run, instance id is $id in $region" >>$log
#
## Test for instance to become available
# Check every 15 seconds until the instance is assigned an Ec2 address.
#
amazonname=$(ec2din $id |tail -1 |awk '{print $4}')
#
while [ "$amazonname" == "pending" ]  
  do
    echo "waiting on instance to spin up..."
    sleep 15
    amazonname=$(ec2din `cat $ec2runfile |tail -1 |awk '{print $2}'` |tail -1 |awk '{print $4}') ;
  done
#
# First, disable alerting.
ssh $amazonname touch /etc/maint
#
## Update DNS
# fix this with relative path to repo
id=$(tail -1 $ec2runfile |awk '{print $2}')
amazonname=$(ec2din $id |tail -1 |awk '{print $4}')
cd ~/repo/bind
git pull
## spit out new DNS entry 
echo "$(echo $host |sed 's/.ooyala.com//g')     300 CNAME   ${amazonname}.  ; $id $zone"
#
vim $OOZONE
git commit -a -m "replacing $host with a $type in $zone"

# fix this with relative path to repo
~/repo/bind/push_changes.sh
STATUS=$?
commit=$(cd ~/repo/bind;git log | head -1)
echo "$(date)	$STATUS $host completed dns update from $oldid to $id via $commit" >>$log

# Mountfix
$(dirname $0)/dse_ec2_mountfix.sh $host 

# Sysctl for performance improvements.
scp ~/files/dse/sysctl.conf $host
ssh $host sysctl -p

# Splunk client install
## Change this to a repo-relative path for use by others.
~/repo/ooyala-sre/monitoring/splunk/splunkforwarder/client_setup_ec2 $host $region

#
## Test for new host entry resolving in DNS
# Keep checking every 15 seconds until DNS has updated locally.
#
hostentry=$(host $host |grep alias |awk '{print $6}' |sed 's/com\./com/')
#
while [ "$hostentry" != $amazonname ]
  do
    echo "Waiting on DNS update..."
    sleep 15
    hostentry=$(host $host |grep alias |awk '{print $6}' |sed 's/com\./com/')
  done

#
## Terminate old instance
if [ -z "$oldid" ]
  then
    echo "No old instance to terminate"
    exit 0
  else
    ec2-modify-instance-attribute --disable-api-termination false $oldid
    ec2-terminate-instances $oldid
    STATUS=$?
    echo "$(date)	$STATUS $host completed termination of $oldid in $region" >>$log
  fi
exit 0
