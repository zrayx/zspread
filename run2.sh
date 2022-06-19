#!/bin/bash

ps -u willem -eo comm | grep -wq zspread && {
    kill `ps -u willem -eo comm,pid | awk '/zspread/ { print $2 }'`
}


[[ -e run_me ]] && zig build run 2>zspread.log &

inotifywait --format %w -q -e close_write run_me

exec ./run2.sh
