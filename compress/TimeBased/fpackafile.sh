#!/bin/bash
#
# process $1 with filename per line using fpack and reset mtime, atime
#---------------------
FPACK=/gpfs/slac/lsst/fs2/u1/devel/marshall/cfitsio/bin/fpack
FOPTS="-g2"

fitsfile=$1
#-compress the file
$FPACK $FOPTS $fitsfile
rt=$?
if [[ $rt -ne 0 ]] ; then
        echo "fpack error: returned $rt"
        exit $rt
fi
#-reset the access and modification times to match source file
touch -r ${fitsfile} ${fitsfile}.fz
#-remove the original file and rename the new file
ls -lh --full-time $fitsfile ${fitsfile}.fz
#rm ${fitsfile}
mv -v ${fitsfile}.fz ${fitsfile}

# Correct group
chown ccs:lsstadm ${fitsfile}

