#!/bin/bash

stopfile=$HOME/COMPRESS.STOP

[ -e $stopfile ] && {
    echo "$stopfile exists"
    exit 1
}

cd /gpfs/slac/lsst/fs3/g/data/rawData/focal-plane || exit 1

for d in 20200*/*; do
    case $d in
        ## Skip .temp directories (used by fast2slow).
        *temp*) continue ;;
        #20201109/*) break ;;
    esac
    ~/ccs-infrastructure/compress/compress_directory.sh $PWD/$d || exit 1
    [ -e $stopfile ] && exit 0
done

exit 0
