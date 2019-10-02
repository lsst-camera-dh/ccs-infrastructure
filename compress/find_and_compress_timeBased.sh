#!/bin/bash

#
# Script to find files between 50 and 51 days old and compress them
# (assuming we run the cron job once a day).
# This version does not use file attributes and is meant only for fs1.
#

# Find start end end times
Time_start=$(date +"%Y-%m-%d" --date='-51 days')
Time_end=$(date +"%Y-%m-%d" --date='-50 days')

# Now
Now=$(date +"%Y%m%d")

# Find files in the time window
find /gpfs/slac/lsst/fs1/g/data/jobHarness/jh_archive-*/LCA-11021_RTM -type f -name *.fits -a -newermt $Time_start ! -newermt $Time_end -size +16M > ~/fpacking/cronjob/mtime.$Now.txt

# Compress the files we just found
cat ~/fpacking/cronjob/mtime.$Now.txt | parallel --joblog ~/fpacking/cronjob/joblog.$Now.txt -j 5 ~/bin/fpackafile.sh > ~/fpacking/cronjob/mtime.$Now.log
