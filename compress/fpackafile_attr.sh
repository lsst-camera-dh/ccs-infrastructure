#!/bin/bash

# Compress input fits file using fpack and reset mtime, atime.
# Original script from Yousuke, LSSTTD-1335.

#FPACK=/gpfs/slac/lsst/fs2/u1/devel/marshall/cfitsio/bin/fpack # 3.45
## This version has -O (added in 3.46).
FPACK=/gpfs/slac/lsst/fs2/u1/devel/gmorris/cfitsio/bin/fpack # 3.47
FOPTS="-g2"

outdir=
[ "$1" = "-d" ] && {
    outdir=$2
    shift 2
}

fitsfile=$1

if [ "$outdir" ]; then
    outfile=$outdir/${fitsfile##*/}
else
    outfile=$fitsfile.fz        # temporary, gets renamed over input
fi

## Compress the file.
## If the argument to -O is too long, use -S to send to stdout instead.
$FPACK $FOPTS ${outdir:+-O $outfile} $fitsfile || {
    rt=$?
    echo "fpack error: returned $rt"
    exit $rt
}

## Reset timestamp and ownership to match the original file.
touch -r $fitsfile $outfile
chmod --reference=$fitsfile $outfile
chown --reference=$fitsfile $outfile

## The time-based version did not have this attr step.
## Set file attribute.
## NB: not visible over NFS; not preserved by default tar, rsync, etc.
setfattr -n user.fpack $outfile

ls -lk --full-time $fitsfile $outfile

[ "$outdir" ] || {
    ## Rename new file over the original.
    mv $outfile $fitsfile
}

exit 0
