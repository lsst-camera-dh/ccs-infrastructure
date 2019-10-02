#!/bin/bash

# Compress fits files under specified directory.

PN=${0##*/}

function die ()
{
    [ $# -gt 0 ] && echo "$PN: $@" >&2
    exit 1
}


[ $USER = ccs ] || die "Run as the ccs user"


PATH=$HOME/ccs-infrastructure/compress:$PATH


logdir=$HOME/compress
mkdir -p $logdir


## Record directories that we already did.
compressfile=$logdir/compressed
touch $compressfile

logbase=$logdir/$(date +%Y%m%d-%H%M%S)

logfile=$logbase.log
exec 1> $logfile 2>&1

logfits=$logbase.txt
logjob=$logbase.job
logout=$logbase.out


[ $# -gt 0 ] || die "Specify one or more directories to compress"


## Avoid multiple instances.
lockfile=/var/tmp/$PN.lock

[ -e $lockfile ] && {
    read pid < $lockfile
    if ps -p $pid >& /dev/null; then
        die "$lockfile exists and pid $pid is running"
    else
        echo "Ignoring stale lockfile $lockfile"
    fi
}

echo $$ >| $lockfile || die "cannot create $lockfile"

trap "rm -f $lockfile 2>/dev/null" EXIT


for dir; do

    [[ $dir == /* ]] || dir=$PWD/$dir

    [ -d $dir ] || {
        echo "Not found: $dir"
        continue
    }

    grep -q "^${dir} " $compressfile && {
        echo "Already done: $dir"
        continue
    }

    grep -q "^${dir%/*} " $compressfile && {
        echo "Already done parent: $dir"
        continue
    }

    size0=$(du -sm "$dir" | cut -f1)

    ## Could replace parallel with
    ##   find ... \( -exec fpack-test.sh '{}' \; -print \) | \
    ##     xargs -n1 -P4 fpackafile_attr.sh
    ### where fpack-test.sh returns 0 if file is not already compressed.
    find "$dir" -type f -name '*.fits' -exec find-fpack.sh '{}' + > $logfits

    parallel --joblog $logjob -j 5 fpackafile_attr.sh < $logfits > $logout || \
        die "Failed processing $dir"

    size1=$(du -sm "$dir" | cut -f1)

    echo "$dir $size0 $size1" >> $compressfile

done

exit 0
