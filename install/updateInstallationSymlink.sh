#!/bin/bash

#The first argument must be the symlink name, the second the installation directory
if [ $# -ne 2 ]; then
    echo "This scripts requires two arguments: the name of the symlink and the name of the installation to link to."
    exit 1
fi

symlink_name=$1
installation_dir_name=$2

echo "updating symlink $symlink_name to point to $installation_dir_name"

BASEDIR=$(dirname "$0")

## This script must be run as ccs
VERIFY_USER=$("$BASEDIR/verifyUser.sh" ccs)

if [ "$VERIFY_USER" == 1 ]
then

    cd /lsst/ccs || exit
    if [[ -h "$symlink_name" ]];
    then
	echo "symlink currently pointing to"
	ls -l "$symlink_name"
	rm "$symlink_name"
    fi
    ln -s "$installation_dir_name" "$symlink_name"
    echo "symlink updated to"
    ls -l "$symlink_name"

else
    echo "$VERIFY_USER"
fi


