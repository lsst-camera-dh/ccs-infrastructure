#!/bin/bash

## List files that do NOT have the attribute.
for file; do
    getfattr -n user.fpack "$file" >& /dev/null || echo "$file"
done

exit 0
