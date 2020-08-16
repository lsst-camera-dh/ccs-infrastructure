#!/bin/bash

## Move files from gpfs fast partition to main partition,
## optionally compressing as we do so.

## Usage: fast2slow </path/to/fast/MC_C_# ... | ALL>
## $1 == source fast directory, or ALL for all of them (caution)

### Options.

## If non-empty compress, else copy.
compress=t
## If non-empty delete originals.
purge=t
## If non-empty, ALL operates on focal-plane.TEST
debug=


### Parameters.
base=/gpfs/slac/lsst/fs3/g
fast=$base/fast
slow=$base/data
focal=rawData/focal-plane
[ "$debug" ] && focal=$focal.TEST


PN=${0##*/}

function die ()
{
    [ $# -gt 0 ] && echo "$PN: $*" >&2
    exit 1
}

[ "$debug" ] || [ $USER = ccs ] || die "Run as the ccs user"

[ $# -eq 0 ] && die "Specify directory(s) to operate on (or 'ALL')"


##renice 19 $$ > /dev/null

PATH=$HOME/ccs-infrastructure/compress:$PATH

logdir=$HOME/compress
mkdir -p $logdir

logbase=$logdir/$(date +%Y%m%d-%H%M%S)

logfile=$logbase.log
exec 1> $logfile 2>&1

logfits=$logbase.txt
logjob=$logbase.job
logout=$logbase.out


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


function doit () {

    local src=$1

    [ -L "$src" ] && {
        echo "skipping symlink $src"
        return 1
    }

    [ -e "$src" ] || {
        echo "$src not found"
        return 1
    }

    [[ $src == $fast/* ]] || die "Unexpected format for src: $src"

    local dest=$slow${src#$fast}

    [ -e $dest ] && [ ! -L $dest ] && {
        echo "$dest exists but is not a symlink"
        return 1
    }

    local tempdest=$dest.temp.$$

    [ -e $tempdest ] && die "$tempdest already exists!"

    local docopy

    if [ ! "$compress" ]; then
        docopy=t
    else
        find "$src" -type f -name '*.fits' \
            -exec find-fpack.sh '{}' + > $logfits

        [ -s $logfits ] || {
            echo "Nothing to compress in $src, falling back to copy"
            rm -f $logfits
            docopy=t
        }
    fi


    if [ "$docopy" ]; then

        ## TODO parallel?
        cp -a $src $tempdest || die "cp error for $src"
        ## Should we delete tempdest?

    else

        mkdir $tempdest || die "mkdir $tempdest error"

        parallel --joblog $logjob -j 8 \
            fpackafile_attr.sh -d $tempdest < $logfits > $logout || {
	    rmdir $tempdest >& /dev/null # if empty
            die "Failed compressing $src"
	}

        rm -f $logfits
    fi


    { rm -f $dest && mv $tempdest $dest ; } || die "rename error for $dest"
    ## On failure, should we restore dest and delete tempdest?

    [ ! "$purge" ] || rm -rf $src || die "error deleting $src"

    return 0
}                               # function doit


### Main body.

if [ "$1" == "ALL" ]; then      # operate on everything

    ymd="202[0-9][01][0-9][0-3][0-9]"
    obs_prefix="MC_C_"
    obs_dir="${obs_prefix}${ymd}_+([0-9])"

    shopt -s extglob

    for src in $fast/$focal/$ymd/$obs_dir; do
        doit $src
    done

else
    for src; do
	[[ $src == /* ]] || src=$PWD/$src
	doit "$src"
    done
fi


exit 0
