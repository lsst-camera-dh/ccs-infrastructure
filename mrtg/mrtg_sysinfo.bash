#!/bin/bash
### mrtg_sysinfo.bash
###
### *Creation: <Fri 28-Oct-2005 11:58:55 gmorris on kipac-dell5.Stanford.EDU>*
###
### Report system information in mrtg format.
###
### See e.g. http://www.dmzs.com/~dmz/projects/mrtgsystemload.html
###
### TODO
### 1. Make du return the correct result for unmounted filesystems,
### without having to mount them every 5 minutes.


PN=${0##*/}

function die ()
{
    [ $# -gt 0 ] && echo "${PN}: $@" 1>&2
    exit 1
}                               # function die


function usage ()
{
    cat 1>&2 <<EOF
Usage: ${PN} load-<ui|us|a|>|mem|mem-buff|procs|swap|users|
         [i]root|[i]data[1-3]|scratch|uptime|
         temp-cpu[2]|temp-bmc|temp-board|temp-pci|temp-ipmi
         fans|loadavg|cpufreq[2]|iostat-[sd[abcd]]|idl
Produce mrtg format statistics on a variety of quantities.
Load can be user/idle; user/system; or active.
EOF
    exit 1
}


## Defaults.
while getopts ":h" option ; do
    case $option in
        (h) usage ;;

        (\?) die "Bad option -$OPTARG" ;;

        (:) die "Option -$OPTARG requires an argument" ;;

        (*) die "getopts error" ;;
    esac
done
shift $(( --OPTIND ))
OPTIND=1

[ $# -eq 1 ] || die "wrong number of arguments"



## Number of cores (including HT).
function ncpu ()
{
    grep -c ^processor /proc/cpuinfo
}                               # function ncpu


## NB seems uptime (idle time at least) resets after 45 days or so.
## NB in RHEL6, idle time is multiplied by the number of cores.
## Since 2.6.29?
## http://help.lockergnome.com/linux/proc-uptime-idle-counter--ftopict498477.html
function uptime ()
{
    gawk -v arg="$1" -v ncpu=`ncpu` '\

function secs2days( secs    , days, hours, mins ) \
{
    days = int( secs / 86400 )

    secs -= days * 86400

    hours = int( secs / 3600 )

    secs -= hours * 3600

    mins = int( secs / 60 )

    secs -= mins * 60

    return sprintf( "%s:%s:%.2d:%.2s", days, hours, mins, secs )
}


function fmt( days, hours, mins    , ret )
{
    ret = (hours ":" mins)

    if ( days > 0 ) ret = (days " days, " ret)

    return ret
}


{
   ## Uptime.
   str = secs2days( $1 )
   split( str, array1, ":" )

   ## Idletime.
   str = secs2days( $2/ncpu )
   split( str, array2, ":" )
}


END \
{
    uptime   = fmt( array1[1], array1[2], array1[3] )
    idletime = fmt( array2[1], array2[2], array2[3] )

    if ( arg ) printf( "%.0f %.0f", $1, $2/ncpu )
    else print uptime

}' /proc/uptime

}                               # function uptime


function mrtg ()
{
    local input=$1 output=$2 uptime node=${HOSTNAME%%.*}

    uptime=`uptime`

    ## We used to use cat and a here-doc, but that made selinux
    ## complain about access to /tmp.
    printf "%s\n%s\n%s\n%s\n" "$input" "$output" "$uptime" "$node"
}                               # function mrtg


function load ()
{
    local ltype=$1

    case $ltype in
        ui|us|a) ;;
        *) die "Bad load type: $ltype" ;;
    esac


    ## vmstat output gained an extra column at the end in RHEL5, so
    ## we parse the output now rather than fixing the column numbers.
    vmstat 1 2 | gawk -v ltype="$ltype" '\
$0 ~ /swpd/ \
{
    for ( i=1; i<=NF; i++ )
    {
        if ( $i == "us" ) i_us = i
        else if ( $i == "sy" ) i_sy = i
        else if ( $i == "id" ) i_id = i
    }
}



END \
{
    usr = i_us ? $i_us : 0
    sys = i_sy ? $i_sy : 0
    idl = i_id ? $i_id : 0

    act = usr + sys

    if ( ltype == "ui" )      print usr, idl
    else if ( ltype == "us" ) print usr, sys
    else if ( ltype == "a" )  print act, 0
}'

}                               # function load


function loadavg ()
{
    gawk '{ print int($1 * 100) }' /proc/loadavg
}                               # function loadavg


function mem ()
{
    local arg=$1

    gawk -v arg="$arg" '\
{
    if ( arg == "swap" )
    {
        if ( $1 == "SwapTotal:" ) total = $2
        else if ( $1 == "SwapFree:" ) free = $2
    }
    else if ( arg == "buff" )
    {
        if ( $1 == "MemTotal:" ) total = $2
        else if ( $1 == "MemFree:" ) free = $2
        else if ( $1 == "Buffers:" ) buff = $2
        else if ( $1 == "Cached:" ) cache = $2
    }
    else
    {
        if ( $1 == "MemTotal:" ) total = $2
        else if ( $1 == "MemFree:" ) free = $2
    }
}

END \
{
    ## "free" (as printed) = buff + cache in this case.
    if ( arg == "buff" )
    {
        used = total - (free + buff + cache)
        free = buff + cache
    }
    else
    {
        used = total - free
    }

    total *= 1024
    free  *= 1024
    used  *= 1024

    printf( "%d %d\n", used, free )

}' /proc/meminfo

}                               # function mem


function procs ()
{
    ## Discard errors from any vanished procs.
    ## Stops working May 2014. SELinux prevents access to all /proc.
    ## Add a local policy xoc_mrtg_ps.te.
    ls -d /proc/[0-9]* 2> /dev/null | wc -l
###    /bin/ps -e 2> /dev/null | wc -l
}                               # function procs


function users ()
{
    if grep -q 'release 7' /etc/redhat-release >& /dev/null; then
        command who | gawk '$1 != "(unknown)" {n++} END {print 0 + n}'
    else
        command uptime | gawk -v RS=',' '/user/ { print $1 }'
    fi
}                               # function users


## Return the partition (eg /dev/sda3) associated with a mount-point
## (eg /xoc5_data1).
## This is of no use, because df does not work for unmounted partitions.
function disk_part ()
{
    local mount=$1

    [ "$mount" ] || return 1

    local part label uuid device
    part=`gawk -v mount="$mount" '$2 == mount { print $1 }' /etc/fstab 2> /dev/null`

    case "$part" in
        /dev/*) echo "$part"; return 0 ;;

        LABEL*) label=${part#LABEL\=} ;;

        UUID*) uuid=${part#UUID\=} ;;

        *) return 2 ;;
    esac


    device=$(lsblk -l -f 2> /dev/null | gawk -v label="$label" \
                                             -v uuid="$uuid" '{
if ( (label && $3 == label) || (uuid && $0 ~ uuid) ) {
  print $1
  exit
}
}')

    [ "$device" ] && {

        device=${device/-/\/}   # for lvm devices

        echo "/dev/$device"
        return 0
    }

    return 1
}                           # function disk_part


## Return 0 if mount $1 is mounted. From rsync_backup.bash
function mountedp ()
{
    local mount=$1

    grep -q " $mount " /etc/mtab || return 1

    return 0
}                               # function mountedp


function du ()
{
    local disk=$1 flag=$2
    local reserved

    case $disk in
       data?)
            disk=/${HOSTNAME%%.*}_$disk
            mountedp $disk || {
                ## TODO Return null string rather than 0s?
                echo "0 0"
                return 1
            }
            ;;
        root) disk=/ ; reserved=t ;;
    esac

    ## For unmounted partitions, need to use the device name, else get
    ## the stats for the / partition.
    ## NB actually, this does not work either. df does not work for
    ## unmounted partitions.
    local device opt=${flag:--B1}
###    device=`disk_part "$disk"`

    device=${device:=$disk}     # if error

    ## Only solution for unmounted partitions is to mount them.
    ## Not doing that every 5 mins.

    ## Used, free.
    ## Long partition names are printed on a line by themselves, with
    ## the actual status information on the next line.
###    df $opt $device 2> /dev/null | gawk 'NR == 2 {print $3, $4}'

    ## The available space reported by df excludes any space reserved
    ## for root. One way want to include it for /.
    ## FIXME but not all users of / run as root...
    if [ "$OFFreserved" ]; then
        df $opt $device 2> /dev/null | \
            gawk 'NR == 2 { if (NF == 1); getline; print $(5-NR), \
$(4-NR) - $(5-NR) }'
    else
        df $opt $device 2> /dev/null | \
            gawk 'NR == 2 { if (NF == 1); getline; print $(5-NR), $(6-NR) }'
    fi
}                               # function du


function afsdu ()
{
    local PATH=/usr/afsws/bin:$PATH
    type -ap fs >& /dev/null || return 1

    fs lq -path "${@:-.}" | gawk 'NR == 2 \
{
    printf( "%.0f %.0f\n", 1024 * $3, 1024 * ($2 - $3) )
}'

}                               # function afsdu


function zfsdu ()
{
    local disk=${1#ki} totflag=$2
    disk=${disk#0}

    local host_a host
    host_a[1]="wain027"
    host_a[2]="wain001"
    host_a[3]="wain002"
    host_a[4]="wain010"
    host_a[5]="wain023"
    host_a[6]="wain040"
    host_a[7]="wain041"
    host_a[8]="wain009"
    host_a[10]="wain042"
    host_a[11]="wain085"
    host_a[14]="wain068"

    host=${host_a[$disk]}

    [ "$host" ] || return 1

    if [ "$totflag" ]; then

        command ssh $host '/bin/df -k /g.ki.ki* | /usr/local/bin/gawk '\''NR == 2 { printf( "%.0f %0.f\n", 1024 * ($2-$4), 1024 * $4)}'\''' 2> /dev/null
    else

        ## Adapted from ~/.aliasrc: zfs_quota_free.
        ## mrtg cannot handle -ve numbers, so if overquota'd report 0 free
        ## instead. % used will be > 100 in such cases.
        command ssh $host 'btot=`/bin/df -k /g.ki.ki* | /usr/local/bin/gawk '\''NR == 2 { print 1024 * $2 }'\''`; /usr/sbin/zfs get -p -H -r -o value quota kipac | /usr/local/bin/gawk -v btot="$btot" '\''{ bquot += $1 } END { printf( "%.0f %0.f\n", bquot, (btot>bquot ? (btot-bquot) : 0) ) }'\''' 2> /dev/null
    fi
}


function temp-ipmi ()
{
    local sudo="sudo"
    [ $UID -eq 0 ] && sudo=
    $sudo ipmi-sensors -t temperature --no-header-output \
	--comma 2> /dev/null | gawk -v FS=',' '\
{
    if ($2 ~ /Inlet/) inlet=$1
    else if ($2 ~ /Exhaust/) exhaust=$1
}
END \
{
    x = inlet + exhaust
    if (!x) exit 1
    printf("%.0f %.0f\n", inlet, exhaust)
}' || return 1
}				# function temp-ipmi


function temp-pci ()
{
    sensors 2> /dev/null | gawk '\
{
    if ( $0 ~ /PCI adapter/ ) {
       getline
       if ($1 != "temp1:") exit
       n++
       printf( "%.0f ", gensub( /[^0-9]*([0-9.]*)[^0-9]*/, "\\1", "t", $2) )
       exit
    }
}
END { if (!n) exit 1 }' || return 1
}                               # function temp-pci


## Temperature from lm-sensors.
## With hyperthreading enabled, it sort of looks as if the temps go:
## real 0123 hyper 0123; ie this happens to work.
function temp-sint ()
{
    sensors 2> /dev/null | gawk -v cores="^[$1]:\$" '\
{
    if ( $1 == "Core" && $2 ~ cores ) {
       printf( "%.0f ", gensub( /[^0-9]*([0-9.]*)[^0-9]*/, "\\1", "t", $3) )
       if (++n >= 2) exit
    }
}
END { if (!n) exit 1 }' || return 1

}                               # function temp-s

function temp-s ()
{
    temp-sint "01"
}

function temp-s2 ()
{
    ## NB for some reason, we have core 0134 instead of 0123?!
    ## FIXME detect this rather than hard-coding hostnames.
    ## Could eg touch a file to indicate this is needed.
    if [[ ${HOSTNAME%%.*} == xoc1[124] ]]; then
        temp-sint "34"
    else
        temp-sint "23"
    fi
}

function temp ()
{
    local arg=$1
    local PATH=/opt/dell/srvadmin/bin:$PATH
    type -ap omreport >& /dev/null || return 1

    omreport chassis temps | gawk -v arg="$arg" '\
{
    if ( arg == "cpu" )
    {
        if ( $0 ~ /(PROC_|CPU)1 Temp/ )
        {
            getline
            temp_cpu = $(NF-1)
        }
    }
    else if ( arg == "board" )
    {
        if ( $0 ~ /System Board (Ambient|Inlet) Temp/ )
        {
            getline
            temp_board = $(NF-1)
        }
    }
    else if ( arg == "bmc" )
    {
        if ( $0 ~ /BMC Ambient Temp/ )
        {
            getline
            temp_amb = $(NF-1)
        }
        else if ( $0 ~ /BMC Planar Temp/ )
        {
            getline
            temp_pla = $(NF-1)
        }
    }
}

END \
{
    if ( arg == "cpu" )
    {
        printf( "%.0f\n", temp_cpu )
    }
    else if ( arg == "board" )
    {
        printf( "%.0f\n", temp_board )
    }
    else if ( arg == "bmc" )
    {
        printf( "%.0f %.0f\n", temp_amb, temp_pla )
    }
}'

}                               # function temp


function fans ()
{
    local PATH=/opt/dell/srvadmin/bin:$PATH
    type -ap omreport >& /dev/null || return 1

    omreport chassis fans | gawk '\
/Reading/ \
{
  fan[n++] = $3
}

END \
{
  if (n == 1)
  {
    fan[1] = fan[0]
    fan[0] = 0
   }

  printf( "%.0f %.0f\n", fan[0], fan[1] )
}'
}                               # function fans


## Note: it seems (from looking at the core id field) that if
## hyperthreading is enabled, the "real" cores are listed first, then
## the hyperthread ones. So the following simple method works (by accident).
## There does not seem to be any way to distinguish real/hyper?
function cpufreq ()
{
    ## For dual cpus.
    gawk '/cpu MHz/ {if (++i > 2) exit ; printf("%.0f ", $NF)} \
END {printf("\n")}' /proc/cpuinfo
}


function cpufreq2 ()
{
    ## For quad cpus.
    gawk '/cpu MHz/ {if (++i < 3) next ; printf("%.0f ", $NF)} \
END {printf("\n")}' /proc/cpuinfo
}


## total bytes read/written for given device.
function iostat ()
{
    local dev=${1:-sda}

    command iostat -d -k $dev | \
        gawk -v dev="^$dev" \
        '$1 ~ dev { printf( "%.0f %.0f\n", 1024*$5, 1024*$6 ) }'
}


function idl ()
{
    local idl_dir=/data/soft/idl

    ## For some reason, each license is counted 6 times.
    LM_LICENSE_FILE=$idl_dir/license/license.dat $idl_dir/idl/bin/lmstat -a | \
        gawk '/Users of idl:/ \
{
    total = $6
    used  = $(NF-3)
    total /= 6
    used /= 6
    print used, total - used
}'

}


## Main body.

case $1 in
    cpufreq) mrtg `cpufreq` ;;

    cpufreq2) mrtg `cpufreq2` ;;

    fans) mrtg `fans` ;;

    idl) mrtg `idl` ;;

    iostat) mrtg `iostat` ;;

    iostat-*) mrtg `iostat ${1#iostat-}` ;;

    mem) mrtg `mem` ;;

    mem-buff) mrtg `mem buff` ;;

    loadavg) mrtg 0 `loadavg` ;;

    load-ui) mrtg `load ui` ;;

    load-us) mrtg `load us` ;;

    load-a) mrtg `load a` ;;

    proc*) mrtg 0 `procs` ;;

    iroot|idata[1-3]|i/*) mrtg `du ${1#i} -i` ;;

    root|data[1-3]|/*) mrtg `du $1` ;;

    ## scratch for comas.
    scratch) mrtg `du /$1` ;;

    swap) mrtg `mem swap` ;;

    temp-cpu)
#        if type -ap omreport >& /dev/null; then
        if [[ ${HOSTNAME%%.*} == xoc[01] ]]; then # faster
            mrtg 0 `temp cpu`
        else
            mrtg `temp-s`
        fi
        ;;

    temp-cpu2) mrtg `temp-s2` ;;

    temp-bmc) mrtg `temp bmc` ;;

    temp-board) mrtg 0 `temp board` ;;

    temp-ipmi) mrtg `temp-ipmi` ;;

    temp-pci) mrtg 0 `temp-pci` ;;

    uptime) mrtg `uptime t` ;;

    user*) mrtg 0 `users` ;;

    /nfs/*) mrtg `du $1` ;;

    i/nfs/*) mrtg `du ${1#i} -i` ;;

    /afs/*) mrtg `afsdu $1` ;;

    ## Quota.
    zfs-*) mrtg `zfsdu ${1#*-}` ;;

    ## Actual used space.
    zfstot-*) mrtg `zfsdu ${1#*-} t` ;;

    *) die "Bad argument: $1" ;;
esac


exit


### mrtg_sysinfo.bash ends here
