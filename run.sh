#!/bin/bash

clear
#zig build test > out 2>&1
#head -$((LINES-4)) out | cut -b-$COLUMNS
#rm out

zig build test 2>&1 | cat
zig build run

#echo --------------------------------------------------------------------------------
inotifywait --format %w -q -e close_write src/*.zig build.zig lib/zdb/build.zig lib/zdb/src/*.zig


exec ./run.sh
