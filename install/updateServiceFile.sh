#!/bin/sh

#The first argument must be the name of the service, the second the name of the symlink
if [ $# -ne 2 ]; then
    echo This scripts requires two arguments: the name of the service file to update and the name of the symlink pointing to the CCS installation to run
    exit 1
fi

symlink_name=$2
service_file_name=$1

echo updating service $service_file_name to point to /lsst/ccs/$symlink_name

BASEDIR=$(dirname "$0")
## This script must be run as root
VERIFY_USER=`$BASEDIR/verifyUser.sh root`

if [ "$VERIFY_USER" == 1 ] 
then
    service_file=/etc/systemd/system/$service_file_name.service

    if [[ ! -f $service_file ]]; 
    then
	echo Service file $service_file does not exist. Exiting.
	exit
    fi
    sed -i -e "s/\/lsst\/ccs\/.*\/bin/\/lsst\/ccs\/$symlink_name\/bin/" $service_file
    systemctl daemon-reload
else
    echo $VERIFY_USER
fi


