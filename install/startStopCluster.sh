#!/bin/sh

if [ $# -ne 1 ]; then
    echo One argument must be provided, either start/stop.
    exit 1
fi



## Loop over all the systemd CCS applications defined in /etc/systemd/system directory
for ccs_app in `grep -l "/lsst/ccs" /etc/systemd/system/*.service | sed -e "s/\/etc\/systemd\/system\///" | sed -e "s/.service//"`
do
    echo sudo systemctl $1 $ccs_app
    sudo systemctl $1 $ccs_app
done




