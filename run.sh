#!/bin/bash

clear
#zig build test > out 2>&1
#head -$((LINES-4)) out | cut -b-$COLUMNS
#rm out

ps -u $USER -eo comm | grep -wq zspread && {
    kill `ps -u $USER -eo comm,pid | awk '/zspread/ { print $2 }'`
}

#(cd lib/zdb/ && zig build test; echo -----------------------------------------)
#zig build test 2>&1 | cat

zig build && touch run_me
echo --------------------------------------------------------------------------------

#echo --------------------------------------------------------------------------------
inotifywait --format %w -q -e close_write src/*.zig build.zig lib/zdb/build.zig lib/zdb/src/*.zig


exec ./run.sh
