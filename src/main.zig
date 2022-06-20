const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const os = std.os;
const testing = std.testing;
const unicode = std.unicode;
const croc = std.testing.allocator;
const dbg = std.debug.print;

const spoon = @import("spoon");

const Table = @import("table").Table;
const Value = @import("value").Value;

var term: spoon.Term = undefined;
var loop: bool = true;

var renderTable: Table = undefined;

const Settings = struct {
    const unused_column_width: usize = 10;
    const top_rows: usize = 2;
};

const Pos = struct {
    x: usize,
    y: usize,
};
var cur = Pos{ .x = 4, .y = 1 };
var offset = Pos{ .x = 0, .y = 0 };
var copy_cur: ?Pos = null;
var copy_mode: CopyMode = .Cell;
var edit_line = std.ArrayList(u8).init(croc);
var editor: Editor = undefined;
var mode_key: u8 = 0;

const CopyMode = enum {
    Cell,
    Line,
    Column,
};

// heuristically determine if the user entered data
// if yes, the table should not be saved if almost empty
var max_cells: usize = 0;
fn countCells() usize {
    var sum: usize = 0;
    const cols = renderTable.columns.items;
    for (cols) |col| {
        sum += col.rows.items.len;
    }
    return sum;
}

fn saveTable() !void {
    const cnt = countCells();
    if (max_cells < cnt) max_cells = cnt;
    if (max_cells > 10 and cnt < 10) {
        dbg("We had {d} cells and now only {d}, so not saving table.\n", .{ max_cells, cnt });
    } else {
        try renderTable.save();
    }
}

pub fn main() !void {
    renderTable = Table.fromCSV("todo") catch
        Table.init("todo") catch {
        @panic("");
    };
    defer renderTable.deinit();
    max_cells = countCells();
    if (max_cells < 10) {
        return;
    }

    try term.init(render);
    defer term.deinit();

    os.sigaction(os.SIG.WINCH, &os.Sigaction{
        .handler = .{ .handler = handleSigWinch },
        .mask = os.empty_sigset,
        .flags = 0,
    }, null);

    try term.uncook();
    defer term.cook() catch {};

    try term.hideCursor();

    try term.fetchSize();

    var title = std.ArrayList(u8).init(croc);
    defer title.deinit();
    try title.writer().print("db/{s}.csv - zspread", .{renderTable.name.items});
    try term.setWindowTitle("{s}", .{title.items});
    defer term.setWindowTitle("bash", .{}) catch {};
    try term.updateContent();

    try mainloop();
    try saveTable();
}

fn max(a: usize, b: usize) usize {
    return if (a > b) a else b;
}

fn moveCursor(dx: i32, dy: i32) !void {
    const new_x: i32 = @intCast(i32, cur.x) + dx;
    const new_y: i32 = @intCast(i32, cur.y) + dy;
    if (new_x < 0) cur.x = 0 else cur.x = @intCast(usize, new_x);
    if (new_y < 0) cur.y = 0 else cur.y = @intCast(usize, new_y);
    try term.updateContent();
}

fn copy(mode: CopyMode) !void {
    copy_cur = cur;
    copy_mode = mode;
}

fn paste() !void {
    if (copy_cur != null) {
        var value: Value = undefined;
        if (copy_cur.?.y > 0) {
            if (renderTable.getAt(copy_cur.?.x, copy_cur.?.y - 1)) |v| {
                value = try v.clone();
            } else |_| {
                value = Value.empty;
            }
            try setAt(cur.x, cur.y - 1, value);
            try saveTable();
        }
    }
}

fn delete() !void {
    if (cur.y != 0) {
        try setAt(cur.x, cur.y - 1, Value.empty);
        try term.updateContent();
    }
}

/// add new columns until we have new_x+1 columns, so that col(new_x) becomes accessible
fn expandColumns(new_x: usize) !void {
    var line = std.ArrayList(u8).init(croc);
    defer line.deinit();
    var x = new_x;

    while (renderTable.columns.items.len < x + 1) {
        var giveup_count = renderTable.columns.items.len + 1;
        var adder: usize = 0;
        while (adder < giveup_count) : (adder += 1) {
            try line.resize(0);
            try line.writer().print("column {d}", .{renderTable.columns.items.len + 1 + adder});
            renderTable.addColumn(line.items) catch |e| {
                if (e == error.ColumnExists) continue;
            };
            break;
        }
    }
}

fn generateColumnName(from_x: usize) !std.ArrayList(u8) {
    var line = std.ArrayList(u8).init(croc);
    var n = from_x;
    while (true) : (n += 1) {
        try line.resize(0);
        try line.writer().print("column {d}", .{n});
        if (!renderTable.hasColumn(line.items)) {
            return line;
        }
    }
}

fn insertColumn(insert_x: usize) !void {
    // the position of the content to be copied changes
    if (copy_cur != null and copy_cur.?.x > insert_x) {
        copy_cur.?.x += 1;
    }

    // Add one column and then swap it for the desired position
    const old_len = renderTable.columns.items.len;
    if (insert_x <= old_len) {
        var new_name = try generateColumnName(insert_x + 1);
        defer new_name.deinit();
        try renderTable.insertColumnAt(insert_x, new_name.items);
    } else {
        try expandColumns(insert_x);
    }
    try term.updateContent();
}

fn insertRow(col_y: usize) !void {
    if (copy_cur != null and copy_cur.?.y > cur.y) {
        copy_cur.?.y += 1;
    }
    renderTable.insertRowAt(col_y) catch |e| {
        if (e != error.InvalidPosition) {
            return e;
        }
    };
    cur.y = col_y + 1;
    try term.updateContent();
}

fn deleteColumn() !void {
    if (copy_cur != null) {
        if (copy_cur.?.x == cur.x) {
            copy_cur = null;
        } else if (copy_cur.?.x > cur.x) {
            copy_cur.?.x -= 1;
        }
    }
    renderTable.deleteColumnAt(cur.x) catch |e| {
        if (e != error.InvalidPosition) {
            return e;
        }
    };
    try saveTable();
    try term.updateContent();
}

fn deleteRow() !void {
    if (cur.y == 0) return error.InvalidPosition;
    if (cur.y > 0) {
        if (copy_cur != null) {
            if (copy_cur.?.y == cur.y) {
                copy_cur = null;
            } else if (copy_cur.?.y > cur.y) {
                copy_cur.?.y -= 1;
            }
        }
        renderTable.deleteRowAt(cur.y - 1) catch |e| {
            if (e != error.InvalidPosition) {
                return e;
            }
        };
        if (cur.y > 0 and getMaxRowCount() + 1 == cur.y) {
            cur.y -= 1;
        }
        try saveTable();
        try term.updateContent();
    }
}

fn getMaxRowCount() usize {
    var max_rows: usize = 0;
    for (renderTable.columns.items) |col| {
        if (max_rows < col.rows.items.len) {
            max_rows = col.rows.items.len;
        }
    }
    return max_rows;
}

fn setAt(new_x: usize, new_y: usize, v: Value) !void {
    var x = new_x;
    var y = new_y;

    try expandColumns(new_x);

    var col = &renderTable.columns.items[x];
    _ = switch (v) {
        .empty => if (y >= col.rows.items.len) {
            return;
        },
        else => {},
    };

    while (col.rows.items.len < y + 1) {
        try renderTable.appendAt(x, Value.empty);
    }
    try renderTable.replaceAt(x, y, v);
    try term.updateContent();
}

fn enterInsertMode(mode: u8) !void {
    mode_key = mode;
    try editor.deleteAll();
    if (cur.x >= renderTable.columns.items.len) {
        try expandColumns(cur.x);
    }
    if (mode_key == 'i' or mode_key == 'a') {
        if (cur.y > 0) {
            var line = std.ArrayList(u8).init(croc);
            defer line.deinit();
            const cols = renderTable.columns.items;
            if (cur.x < cols.len) {
                const rows = cols[cur.x].rows.items;
                if (cur.y - 1 < rows.len) {
                    const value = rows[cur.y - 1];
                    try value.write(line.writer());
                    try editor.set(line.items);
                }
            }
        } else {
            if (cur.x >= renderTable.columns.items.len) {
                try expandColumns(cur.x);
            }
            try editor.set(renderTable.columns.items[cur.x].name.items);
        }
        if (mode_key == 'a') {
            editor.end();
            mode_key = 'i';
        }
    } else if (mode_key == 'C') {
        mode_key = 'i';
    } else {
        @panic("Unkown mode key");
    }
}

fn exitInsertMode() !void {
    mode_key = 0;
    if (cur.y == 0) {
        renderTable.renameColumnAt(cur.x, editor.line()) catch {};
    } else {
        const value = try Value.parse(editor.line());
        try setAt(cur.x, cur.y - 1, value);
    }
    try editor.deleteAll();
    try saveTable(); // TODO: xxx
}

fn mainloop() !void {
    const large_step: i32 = 7;
    const huge_step: i32 = 30;
    var buf: [16]u8 = undefined;
    var fds: [1]os.pollfd = undefined;
    fds[0] = .{
        .fd = term.tty.handle,
        .events = os.POLL.IN,
        .revents = undefined,
    };

    editor = try Editor.init();
    defer editor.deinit();

    loop: while (loop) {
        _ = try os.poll(&fds, -1);

        const read = try term.readInput(&buf);
        var it = spoon.inputParser(buf[0..read]);
        while (it.next()) |in| {
            // ESC should exit any mode
            if (mode_key != 0 and mode_key != 'i') {
                _ = switch (in.content) {
                    .escape => {
                        mode_key = 0;
                        continue;
                    },
                    else => {},
                };
            }
            _ = switch (mode_key) {
                0 => switch (in.content) { // mode_key == 0
                    .escape => {}, // do nothing to avoid mode confusion
                    .codepoint => |cp| {
                        if (in.mod_ctrl) {
                            _ = switch (cp) {
                                'c' => try copy(.Cell),
                                'h' => try moveCursor(-huge_step, 0),
                                'j' => try moveCursor(0, huge_step), // note: ctrl-j is translated by the linux terminal to \r, so won't work as expected
                                'k' => try moveCursor(0, -huge_step),
                                'l' => try moveCursor(huge_step, 0),
                                'v' => try paste(),
                                else => {},
                            };
                        } else {
                            _ = switch (cp) {
                                // edit mode
                                'C', 'a', 'i' => try enterInsertMode(@truncate(u8, cp)), // replace/append/insert: enter edit mode for cell
                                // insert/delete/copy/paste
                                'D' => mode_key = 'D', // delete
                                'P' => mode_key = 'P', // paste
                                'Y' => mode_key = 'Y', // yank
                                'd' => mode_key = 'd', // delete (vi-like)
                                'I' => try insertColumn(cur.x),
                                'O' => try insertRow(if (cur.y > 0) cur.y - 1 else 0),
                                'o' => try insertRow(cur.y),
                                '+' => try insertColumn(cur.x),
                                'x' => try delete(),
                                // movement
                                'H' => try moveCursor(-large_step, 0),
                                'J' => try moveCursor(0, large_step),
                                'K' => try moveCursor(0, -large_step),
                                'L' => try moveCursor(large_step, 0),
                                'h' => try moveCursor(-1, 0),
                                'j' => try moveCursor(0, 1),
                                'k' => try moveCursor(0, -1),
                                'l' => try moveCursor(1, 0),
                                // quit
                                'q' => break :loop,
                                else => {},
                            };
                        }
                    },
                    .arrow_left => try moveCursor(-1, 0),
                    .arrow_right => try moveCursor(1, 0),
                    .arrow_up => try moveCursor(0, -1),
                    .arrow_down => try moveCursor(0, 1),
                    else => {},
                },
                'd' => { // mode_key == 'd'
                    _ = switch (in.content) {
                        .escape => mode_key = 0,
                        .codepoint => |cp| switch (cp) {
                            'c' => try deleteColumn(),
                            'd' => try deleteRow(),
                            else => ErrorMessage("illegal delete command"),
                        },
                        else => {},
                    };
                    mode_key = 0;
                },
                'D' => { // mode_key == 'D'
                    _ = switch (in.content) {
                        .escape => mode_key = 0,
                        .codepoint => |cp| switch (cp) {
                            'c' => try deleteColumn(),
                            'l' => try deleteRow(),
                            else => ErrorMessage("illegal delete command"),
                        },
                        else => {},
                    };
                    mode_key = 0;
                },
                'i' => switch (in.content) { // mode_key == 'i'
                    .escape => try exitInsertMode(),
                    .codepoint => |cp_u21| {
                        if (cp_u21 < 256) {
                            const cp = @truncate(u8, cp_u21);
                            if (in.mod_ctrl) {
                                _ = switch (cp) {
                                    'a' => editor.home(),
                                    'e' => editor.end(),
                                    'f' => editor.right(),
                                    'b' => editor.left(),
                                    'h' => try editor.deleteLeftOfCursor(),
                                    'u' => try editor.deleteAllLeftOfCursor(),
                                    'w' => try editor.deleteWordLeftOfCursor(),
                                    else => dbg("unused insert mode key combination C-{c} ({d})\n", .{ cp, cp }),
                                };
                            } else {
                                _ = switch (cp) {
                                    //' ', '0'...'9', 'A'...'Z', 'a'...'z' => try editor.append(cp),

                                    9 => { // Tab
                                        try exitInsertMode();
                                        cur.x += 1;
                                        try enterInsertMode('a');
                                    },
                                    10 => { // Enter
                                        try exitInsertMode();
                                        cur.y += 1;
                                        try enterInsertMode('a');
                                    },
                                    32...126 => try editor.insert(cp),
                                    127 => try editor.deleteLeftOfCursor(),
                                    228 => try editor.insertMultiple("ä"),
                                    196 => try editor.insertMultiple("Ä"),
                                    246 => try editor.insertMultiple("ö"),
                                    214 => try editor.insertMultiple("Ö"),
                                    252 => try editor.insertMultiple("ü"),
                                    220 => try editor.insertMultiple("Ü"),
                                    223 => try editor.insertMultiple("ß"),
                                    233 => try editor.insertMultiple("é"),
                                    else => dbg("unused insert mode key {d}\n", .{cp}),
                                };
                            }
                        } else {
                            dbg("Codepoint value {d} must be < 256", .{cp_u21});
                            @panic("x");
                        }
                    },
                    .delete => try editor.deleteRightOfCursor(),
                    //.insert => {},
                    .end => editor.end(),
                    .home => editor.home(),
                    //.page_up => {},
                    //.page_down => {},
                    .arrow_left => editor.left(),
                    .arrow_right => editor.right(),
                    // .arrow_up  (also: mouse wheel)
                    // .arrow_down (also: mouse wheel)
                    else => {
                        dbg("Unknown in.content type {}\n", .{in.content});
                    },
                },
                else => {},
            };
        }
        term.updateContent() catch {};
    }
}

pub const Editor = struct {
    content: std.ArrayList(u8),
    cur: Pos = .{ .x = 0, .y = 0 },

    const Self = @This();

    fn deinit(self: Self) void {
        self.content.deinit();
    }

    pub fn line(self: Self) []const u8 {
        return self.content.items;
    }

    pub fn init() !Editor {
        return Editor{
            .content = std.ArrayList(u8).init(croc),
        };
    }

    pub fn left(self: *Self) void {
        if (self.cur.x > 0) self.cur.x -= 1;
    }

    pub fn right(self: *Self) void {
        if (self.len() > self.cur.x) self.cur.x += 1;
    }

    pub fn startOfText(self: *Self) void {
        self.cur.x = 0;
        self.cur.y = 0;
    }

    pub fn home(self: *Self) void {
        self.cur.x = 0;
    }

    pub fn end(self: *Self) void {
        self.cur.x = self.len();
    }

    pub fn deleteWordLeftOfCursor(self: *Self) !void {
        // delete non-spaces
        while (self.cur.x > 0 and self.content.items[self.cur.x - 1] != ' ') {
            self.cur.x -= 1;
            try self.deleteRightOfCursor();
        }
        // delete spaces
        while (self.cur.x > 0 and self.content.items[self.cur.x - 1] == ' ') {
            self.cur.x -= 1;
            try self.deleteRightOfCursor();
        }
    }

    pub fn deleteAllLeftOfCursor(self: *Self) !void {
        while (self.cur.x > 0) {
            self.cur.x -= 1;
            try self.deleteRightOfCursor();
        }
    }

    pub fn deleteLeftOfCursor(self: *Self) !void {
        if (self.cur.x > 0) {
            self.cur.x -= 1;
            try self.deleteRightOfCursor();
        }
    }

    pub fn deleteRightOfCursor(self: *Self) !void {
        if (self.len() > self.cur.x) {
            _ = self.content.orderedRemove(self.cur.x);
        }
    }

    pub fn deleteAll(self: *Self) !void {
        try self.content.resize(0);
        self.cur.x = 0;
        self.cur.y = 0;
    }

    pub fn len(self: Self) usize {
        return self.content.items.len;
    }

    pub fn insert(self: *Self, char: u8) !void {
        try self.content.insert(self.cur.x, char);
        self.cur.x += 1;
    }

    pub fn set(self: *Self, string: []const u8) !void {
        try self.content.resize(0);
        try self.content.appendSlice(string);
    }

    pub fn insertMultiple(self: *Self, string: []const u8) !void {
        for (string) |char| {
            try self.insert(char);
        }
    }
};

fn render(_: *spoon.Term, _: usize, columns: usize) !void {
    var line = std.ArrayList(u8).init(croc);
    defer line.deinit();

    try term.clear();
    try term.fetchSize(); // term.height and term.width will contain the size

    try term.moveCursorTo(0, 0);
    try term.setAttribute(.{ .fg = .green, .reverse = true });

    try line.resize(0);
    const mode_name: []const u8 = switch (mode_key) {
        0 => "normal",
        'd', 'D' => "delete",
        'i', 'a' => "insert",
        'y', 'Y' => "copy",
        'p', 'P' => "paste",
        'g' => "go to",
        else => @panic("Unknown mode"),
    };
    try line.writer().print("Table: {s} - {s}", .{ renderTable.name.items, mode_name });
    var remaining_columns = try term.writeLine(columns, line.items);
    try term.writeByteNTimes(' ', remaining_columns);

    // constants and variables
    var col_total_width: usize = 0;
    const cols = renderTable.columns.items;
    const col1_name = "row#";

    // calculate the width and starting term column of every table column
    // if the cursor is outside existing columns, calculate positions of not (yet) existing columns as well
    var term_col_width = std.ArrayList(usize).init(croc);
    defer term_col_width.deinit();
    var term_col_pos = std.ArrayList(usize).init(croc);
    defer term_col_pos.deinit();

    try term_col_pos.append(col_total_width);
    col_total_width += col1_name.len + 1;
    try term_col_width.append(col1_name.len + 1);

    var col_idx: usize = 0;
    while (col_idx < cols.len or col_idx <= cur.x + 10) : (col_idx += 1) {
        try term_col_pos.append(col_total_width);
        var col_width = Settings.unused_column_width;
        if (col_idx < cols.len) col_width = try cols[col_idx].maxWidth();
        if (mode_key == 'i' and col_idx == cur.x and editor.len() > col_width) col_width = editor.len();

        col_total_width += col_width + 1;
        try term_col_width.append(col_width);
    }

    // calculate offset
    offset.x = 0;
    col_idx = cur.x + 1;
    while (true) : (offset.x += 1) {
        dbg("c1\n", .{});
        if (!(col_idx > offset.x)) break;
        dbg("c2\n", .{});
        if (!(col_idx - offset.x < term_col_pos.items.len)) break;
        dbg("c3\n", .{});
        if (!(col_idx - offset.x < term_col_width.items.len)) break;
        dbg("c4\n", .{});
        if (!(col_idx + 1 < term_col_pos.items.len)) break;
        dbg("c5\n", .{});
        const last_col_start = term_col_pos.items[col_idx];
        const last_col_width = term_col_width.items[col_idx];
        const first = term_col_width.items[0];
        const offset_start = term_col_pos.items[offset.x];
        const text_width = last_col_start + last_col_width - offset_start + first;
        dbg("offset.x: {d}, ", .{offset.x});
        dbg("offset_start: {d}, ", .{offset_start});
        dbg("text_width: {d}, ", .{text_width});
        dbg("term.width: {d}\n", .{term.width});
        if (text_width <= term.width) break;
        //if (!(term_col_pos.items[col_idx] + term_col_width.items[col_idx] - term_col_pos.items[offset.x] > term.width)) break;
    }
    dbg("------\n", .{});

    if (cur.x + offset.x > term.width) offset.x = cur.x - term.width;
    offset.y = if (Settings.top_rows + 1 + cur.y > term.height) Settings.top_rows + 1 + cur.y - term.height else 0;

    // print column contents
    const num_rows = getMaxRowCount();
    var row_idx: usize = offset.y;
    // loop rows
    while (row_idx - offset.y <= term.height - Settings.top_rows and (row_idx < num_rows + 1 or row_idx <= cur.y)) : (row_idx += 1) {
        // print row number
        try term.setAttribute(.{ .fg = .red, .bold = true });
        try term.moveCursorTo(row_idx - offset.y + Settings.top_rows - 1, term_col_pos.items[0]);
        try line.resize(0);
        if (row_idx > offset.y) {
            try line.writer().print("{d}", .{row_idx});
            _ = try term.writeLine(term_col_width.items[0], line.items);
        } else {
            _ = try term.writeAll("row#");
        }

        // loop columns
        col_idx = offset.x;
        while (col_idx < cols.len or col_idx <= cur.x) : (col_idx += 1) {
            const rows = if (col_idx < cols.len) cols[col_idx].rows.items else undefined;

            const col_start = term_col_pos.items[col_idx + 1];
            const first = term_col_width.items[0];
            const offset_start = term_col_pos.items[offset.x + 1];
            const cursor_start = col_start - offset_start + first;
            try term.moveCursorTo(row_idx - offset.y + Settings.top_rows - 1, cursor_start);
            if (row_idx == 2) {
                dbg("col_idx: {d}, ", .{col_idx});
                dbg("offset.x: {d}, ", .{offset.x});
                dbg("col_start: {d}, ", .{col_start});
                dbg("first: {d}, ", .{first});
                dbg("offset_start: {d}\n", .{offset_start});
            }
            // display edit text instead of saved cell content
            if (mode_key == 'i' and cur.x == col_idx and cur.y == row_idx) {
                // the text
                try term.setAttribute(.{ .fg = .yellow, .reverse = true });
                const col_width = term_col_width.items[col_idx + 1];
                const edit_width = editor.len();
                const width = if (col_width > edit_width) col_width else edit_width;
                var remaining = try term.writeLine(width, editor.line());
                try term.writeByteNTimes(' ', remaining);

                // the cursor
                try term.moveCursorTo(Settings.top_rows - 1 + row_idx - offset.y, cursor_start + editor.cur.x);
                try term.setAttribute(.{ .fg = .bright_blue, .reverse = true });
                var key: u8 = ' ';
                if (editor.cur.x < editor.len()) key = editor.line()[editor.cur.x];
                try term.writeByte(key);
            } else {
                try term.setAttribute(.{ .fg = if (row_idx - offset.y == 0) .red else .white, .reverse = (cur.x == col_idx and cur.y == row_idx) });

                if ((col_idx < cols.len or col_idx <= cur.x) and row_idx < rows.len + 1) {
                    // if row_idx == 0, then write the column name, else the column content
                    const cell_text = blk: {
                        if (row_idx - offset.y == 0) {
                            if (col_idx >= cols.len) {
                                try line.resize(0);
                                try line.writer().print("new col {d}", .{col_idx + 1 - cols.len});
                                break :blk line.items;
                            } else {
                                break :blk cols[col_idx].name.items;
                            }
                        } else { // column content
                            try line.resize(0);
                            if (col_idx < cols.len) {
                                try rows[row_idx - 1].write(line.writer());
                            }
                            break :blk line.items;
                        }
                    };
                    var remaining = try term.writeLine(term_col_width.items[col_idx + 1], cell_text);
                    remaining += 1; // add one space after column
                    try term.writeByteNTimes(' ', remaining);
                } else {
                    const remaining = term_col_width.items[col_idx + 1];
                    try term.writeByteNTimes(' ', remaining);
                }
                try line.resize(0);
            }
        }
    }
}

fn handleSigWinch(_: c_int) callconv(.C) void {
    term.fetchSize() catch {};
    term.updateContent() catch {};
}

/// TODO: render message in status line
fn ErrorMessage(msg: []const u8) void {
    _ = msg; // empty for now
}

/// Custom panic handler, so that we can try to cook the terminal on a crash,
/// as otherwise all messages will be mangled.
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
    @setCold(true);
    term.cook() catch {};
    std.builtin.default_panic(msg, trace);
}
