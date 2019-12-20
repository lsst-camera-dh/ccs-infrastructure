#!/bin/bash
#
#
#---------------------------------------------------------------------------
# Check the air inlet temperature.  If it is above the threshold return the 
# value.  Otherwise return 0.
#---------------------------------------------------------------------------
#---------------------------------------------------------------------------
#- define some functions
#---------------------------------------------------------------------------
# usage: email "message text"
function email {
mail -s "${PROG} error" "$CONTACT" <<EOF
$1
Time: $(date)
EOF
}

# echo to send to stderr instead of stdout
function echoerr { 
printf "%s\n" "$*" >&2;
}

# called on trap triggered exit
function cleanexit {
set +u
rm -f $LOCKFILE
echoerr -n "cleanexit(): "
echoerr $(date --utc '+%Y%m%d%H%M%S')
exit $?
}

#---------------------------------------------------------------------------
# Initialization
#---------------------------------------------------------------------------
#if [ $# -ne 1 ]; then
#    echoerr "usage: $PROG \<temp-threshold-in-centigrate\>"
#    exit 1
#fi

LOCKDIR=/tmp
PROGPATH=$0
PROG=${0##*/}
PID=$$
dir0=$PWD
set -u
if [ ! -d ${LOCKDIR} ] || [ ! -w ${LOCKDIR} ]; then 
    echoerr "${LOCKDIR} dir does not exist or is not writable"
    exit 1
fi

LOCKFILE=${LOCKDIR}/${PROG}.lock
if ( set -o noclobber ; echoerr "$PID" > "$LOCKFILE") 2> /dev/null; 
then
    trap cleanexit INT TERM EXIT
else
    echoerr "Failed to acquire lockfile: $LOCKFILE." 
    echoerr "Held by PID $(< $LOCKFILE)"
    echoerr "exiting"
    exit 1
fi
#---------------------------------------------------------------------------
#
thresh=23
temp=$(ipmi-sensors -t temperature --no-header-output --comma |\
   gawk -F, '/Inlet/ {printf("%d\n",$4);}')
if [ $temp -lt $thresh ] ; then
   echoerr Inlet temp=$temp \< threshold=$thresh
   retval=0
else
   echoerr Inlet air temp=$temp \> threshold=$thresh
   retval=$temp
fi
#---------------------------------------------------------------------------
#- end of script, remove trap
#---------------------------------------------------------------------------
trap - INT TERM EXIT
rm -f $LOCKFILE
cd $dir0
echoerr exit at: $(date --utc '+%Y%m%d%H%M%S') 
exit $retval

