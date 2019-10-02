#!/bin/bash
for file in "$@"
do
a=`attr -q -g user.fpack "$file" 2>/dev/null`
if [ "$a" != "true" ]
then
echo $file
fi
done
