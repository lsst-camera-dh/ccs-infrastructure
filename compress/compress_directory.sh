#!/bin/bash
###
### Compress fits files under specified directory.

PN=${0##*/}

function die ()
{
    [ $# -gt 0 ] && echo "$PN: $@" >&2
    exit 1
}


[ $USER = ccs ] || die "Run as the ccs user"

##renice 19 $$ > /dev/null

PATH=$HOME/ccs-infrastructure/compress:$PATH


logdir=$HOME/compress
mkdir -p $logdir


## Record directories that we already did.
compressfile=$logdir/compressed
[ -e $compressfile ] || touch $compressfile

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

    parent="${dir%/*}"

    grep -q "^$parent " $compressfile && {
        echo "Already done parent: $dir"
        continue
    }

#    symlink=
#    [ -L "$parent" ] && symlink=t

    size0=$(du -sm "$dir" | cut -f1)

    ## Could replace parallel with
    ##   find ... \( -exec fpack-test.sh '{}' \; -print \) | \
    ##     xargs -n1 -P4 fpackafile_attr.sh
    ### where fpack-test.sh returns 0 if file is not already compressed.
    ## Skip empty files.
    find "$dir" -type f -name '*.fits' -size +0 \
         -exec find-fpack.sh '{}' + > $logfits

    [ -s $logfits ] || {
        rm -f $logfits
        continue # nothing to compress
    }

    parallel --joblog $logjob -j 8 fpackafile_attr.sh < $logfits > $logout || \
        die "Failed processing $dir"

    ## If all went well there's no need to keep the list of inputs.
    ## Perhaps it should be a temporary file?
    rm -f $logfits

    size1=$(du -sm "$dir" | cut -f1)

    echo "$dir $size0 $size1" >> $compressfile

done

## Avoid leaving empty log files.
[ -s $logfile ] || rm -f $logfile

exit 0
