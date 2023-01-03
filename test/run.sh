#!/bin/bash

for i in *.csv; do
    echo "========================================="
    echo $i
    echo "------------"
    /home/mbj/src/canboat/rel/linux-x86_64/analyzer -q  < $i
    echo "----"
    ../bin/n2k --infmt csv -f pretty $i
done
