#!/bin/bash

## List files that do NOT have the attribute.
for file; do
    ## Skip empty files. Now doing this in the find step.
###    [ -s "$file" ] || continue
    getfattr -n user.fpack "$file" >& /dev/null || echo "$file"
done

exit 0
