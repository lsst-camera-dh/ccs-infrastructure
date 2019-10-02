#!/bin/bash

#
# Script to find files without compressed attribute and compress them
# This version does use file attributes and is meant only for fs3.
#

# Now
Now=$(date +"%Y%m%d")

# Find uncompressed files (well, files without the compressed attribute)
find /gpfs/slac/lsst/fs3/g/data/ -name "*.fits" -type f -exec ~/bin/find-fpack.sh "{}" + > ~/fpacking/cronjob/mtime.$Now.txt

# Compress the files we just found
cat ~/fpacking/cronjob/mtime.$Now.txt | parallel --joblog ~/fpacking/cronjob/joblog.$Now.txt -j 5 ~/bin/fpackafile.sh > ~/fpacking/cronjob/mtime.$Now.log
