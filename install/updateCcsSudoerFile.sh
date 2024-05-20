#!/bin/bash

BASEDIR=$(dirname "$0")

## This script must be run as root
VERIFY_USER=$("$BASEDIR/verifyUser.sh" root)

if [ "$VERIFY_USER" == 1 ]
then

    ## Check if the /etc/sudoers.d/user-ccs file exists
    ## What permissions should this file have?
    ccs_sudoer_file="/etc/sudoers.d/user-ccs"
    if [ ! -f "$ccs_sudoer_file" ]
    then
	touch $ccs_sudoer_file
    fi

    ## Array containing the systemctl commands we want to add to the sudoer file for the ccs account
    systemctl_commands=( "status" "start" "stop" "restart" )

    ## Loop over all the systemd CCS applications defined in /etc/systemd/system directory
    while read -r ccs_app
    do
	echo "Working on CCS Application $ccs_app"


	for command in "${systemctl_commands[@]}"
	do
	    if ! grep "$ccs_app" "$ccs_sudoer_file" | grep -q "$command";
	    then
		echo "Adding command $command for $ccs_app"
		echo "ccs ALL= NOPASSWD: /usr/bin/systemctl $command $ccs_app" >> $ccs_sudoer_file
	    fi
	done

    done < <(grep -l "/lsst/ccs" /etc/systemd/system/*.service | sed -e "s|/etc/systemd/system/||" -e "s/.service//")
else
    echo "$VERIFY_USER"
fi


