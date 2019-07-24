#!/bin/sh

#The user against which to check must be provided
if [ $# -ne 1 ]; then
    echo One argument must be provided: the username to check against.
    exit 1
fi

_user="$(id -u -n)"

if [ $_user != $1 ]; then
    echo Incorrect user: $_user This script must be run by: $1
else
    echo 1
fi



