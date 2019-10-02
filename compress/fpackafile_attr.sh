#!/bin/bash
#
# Compress $1 using fpack and reset mtime, atime.
# Original script from Yousuke, LSSTTD-1335.

FPACK=/gpfs/slac/lsst/fs2/u1/devel/marshall/cfitsio/bin/fpack
FOPTS="-g2"

fitsfile=$1

## Compress the file.
$FPACK $FOPTS $fitsfile || {
    rt=$?
    echo "fpack error: returned $rt"
    exit $rt
}

## Reset timestamp and ownership to match the original file.
touch -r ${fitsfile} ${fitsfile}.fz
chown --reference=$fitsfile ${fitsfile}.fz

## Rename new file over the original.
ls -lh --full-time $fitsfile ${fitsfile}.fz
mv -v ${fitsfile}.fz ${fitsfile}

## The time-based version did not have this attr step.
## Set file attribute.
## NB: not visible over NFS; not preserved by default tar, rsync, etc.
setfattr -n user.fpack ${fitsfile}

exit 0
