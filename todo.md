priority n-1
============
editor:
  ctrl modifier
    'h': backspace
    'b': cursor_left
    'f': cursor_right
  render cursor
  move with cursor keys
  move with VI movement keys
handle utf8
    https://zig.news/dude_the_builder/unicode-basics-in-zig-dj3

priority n-1
============
wrap columns/lines when cursor is outside current window
insert row
insert column
change tables

priority n-1
============
mark ranges
  ctrl+space: mark row
  shift+space: mark column
    but shift+space won't work in terminal
copy/paste/cut uses temp table instead of position/range
display multiple tables next to each other
