#!/bin/bash

count=1
nextApp="false"
nextCp="false"
user_name="undefined"
ccs_process="undefined"
ccs_installation="undefined"

mapfile -t pids < <(pgrep -f 'java.*Bootstrap')
for process in $(ps --no-headers -w -w -u -p "${pids[@]}")
do

    if [[ count -eq 1 ]];
    then
	user_name=$process
    fi
    count=$((count+1))

    if [[ "$nextApp" = "true" ]];
    then
	ccs_process=$process
	count=1
    fi

    if [[ "$nextCp" = "true" ]];
    then
	ccs_installation=$(echo "$process" |cut -f1-5 -d "/")
    fi

    if [[ "$process" = "--app" ]];
    then
	nextApp="true"
    else
	nextApp="false"
    fi

    if [[ "$process" = "-cp" ]];
    then
	nextCp="true"
    else
	nextCp="false"
    fi

    if [[ count -eq 1 ]];
    then
	service_file=$(grep -l "$ccs_process" /etc/systemd/system/*.service)
	service=$(echo "$service_file" | cut -f5 -d "/" | cut -f1 -d ".")
#	if [[ -z "$service" ]];
#	then
#	    echo "NO SERVICE for $ccs_process"
#	else
	    isActive=$(systemctl is-active "$service")
	    echo -e "$ccs_process \t($user_name) \t $ccs_installation \t$service($isActive)"
#	fi

    fi
#    echo $process $count


done
