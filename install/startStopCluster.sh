#!/bin/bash

if [ $# -ne 1 ]; then
    echo "One argument must be provided, either start/stop."
    exit 1
fi



## Loop over all the systemd CCS applications defined in /etc/systemd/system directory
while read -r ccs_app
do
    echo "sudo systemctl $1 $ccs_app"
    sudo systemctl "$1" "$ccs_app"

done < <(grep -l "/lsst/ccs" /etc/systemd/system/*.service | sed -e "s|/etc/systemd/system/||" -e "s/.service//")
