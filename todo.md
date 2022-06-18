priority n-1
============
editor:
  ctrl modifier
    'h': backspace
    'b': cursor_left
    'f': cursor_right
    'a': start of line
    'e': end of line
    'u': delete everything left of the cursor
  move with cursor keys
  move with VI movement keys
handle utf8
    https://zig.news/dude_the_builder/unicode-basics-in-zig-dj3
load & save different tables
  interface for asking for table name
    or from command line

priority n-1
============
wrap columns/lines when cursor is outside current window
insert row
insert column
change tables
message line to display errors

priority n-1
============
mark ranges
  ctrl+space: mark row
  shift+space: mark column
    but shift+space won't work in terminal
copy/paste/cut uses temp table instead of position/range
display multiple tables next to each other
