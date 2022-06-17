priority n-1
============
keep text when editing a column
resiliency against crashes
  save on every edit?
  any version control? backup saves?
  save to backup, then move back on successful save?
  save to backup, then load, then verify, then move to original file
buggy when saving/loading zero or empty columns
  can't edit name of empty column
can't delete last line

priority n-1
============
edit column name
edit cell
  'a': append
  'i': insert
  'C': replace
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
