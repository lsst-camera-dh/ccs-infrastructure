#!/bin/bash

for file; do
    getfattr -n user.fpack "$file" >& /dev/null && echo "$file"
done

exit 0
