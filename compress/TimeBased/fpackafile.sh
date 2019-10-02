#!/bin/bash
#
# Compress $1 using fpack and reset mtime, atime.

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

exit 0
