const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const os = std.os;
const testing = std.testing;
const unicode = std.unicode;
const croc = std.testing.allocator;

const spoon = @import("spoon");

const Table = @import("table").Table;
const Value = @import("value").Value;

var term: spoon.Term = undefined;
var loop: bool = true;

var renderTable: Table = undefined;

const Settings = struct {
    const unused_column_width: usize = 13;
};

const Pos = struct {
    x: usize,
    y: usize,
};
var cur = Pos{ .x = 0, .y = 0 };
var copy_cur: ?Pos = null;
var edit_line = std.ArrayList(u8).init(croc);
var editor: Editor = undefined;
var mode_key: u8 = 0;

pub fn main() !void {
    var t1 = Table.fromCSV("io") catch
        Table.init("io") catch {
        @panic("");
    };
    defer t1.deinit();
    renderTable = t1;

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
    try term.setWindowTitle(title.items);
    defer term.setWindowTitle("bash") catch {};
    try term.updateContent();

    try mainloop();
    try renderTable.save();
}

fn moveCursor(dx: i32, dy: i32) !void {
    const new_x: i32 = @intCast(i32, cur.x) + dx;
    const new_y: i32 = @intCast(i32, cur.y) + dy;
    if (new_x < 0) cur.x = 0 else if (new_x > 99) cur.x = 99 else cur.x = @intCast(usize, new_x);
    if (new_y < 0) cur.y = 0 else if (new_y > 99) cur.y = 99 else cur.y = @intCast(usize, new_y);
    try term.updateContent();
}

fn copy() !void {
    //_ = renderTable.getAt(cur.x, cur.y) catch {
    //copy_cur = null;
    //return;
    //};
    copy_cur = cur;
}

fn paste() !void {
    if (copy_cur != null) {
        var value: Value = undefined;
        if (renderTable.getAt(copy_cur.?.x, copy_cur.?.y)) |v| {
            value = try v.clone();
        } else |_| {
            value = try Value.parse("");
        }
        try setAt(cur.x, cur.y, value);
    }
}

fn delete() !void {
    try setAt(cur.x, cur.y, try Value.parse(""));
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
    try term.updateContent();
}

fn deleteRow() !void {
    if (copy_cur != null) {
        if (copy_cur.?.y == cur.y) {
            copy_cur = null;
        } else if (copy_cur.?.y > cur.y) {
            copy_cur.?.y -= 1;
        }
    }
    renderTable.deleteRowAt(cur.y) catch |e| {
        if (e != error.InvalidPosition) {
            return e;
        }
    };
    try term.updateContent();
    {}
}

fn setAt(new_x: usize, new_y: usize, v: Value) !void {
    var line = std.ArrayList(u8).init(croc);
    defer line.deinit();
    var x = new_x;
    var y = new_y;

    while (renderTable.columns.items.len < x + 1) {
        var giveup_count = renderTable.columns.items.len + 1;
        var adder: usize = 0;
        while (adder < giveup_count) : (adder += 1) {
            try line.resize(0);
            try line.writer().print("column {d}", .{renderTable.columns.items.len + 1 + adder});
            renderTable.addColumn(line.items) catch |e| {
                if (e == error.ColumnExists) continue;
            };
            std.debug.print("Adding column {s}\n", .{line.items});
            break;
        }
    }

    while (renderTable.columns.items[x].rows.items.len < y + 1) {
        try renderTable.appendAt(x, try Value.parse(""));
    }
    try renderTable.replaceAt(x, y, v);
    try term.updateContent();
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
            _ = switch (mode_key) {
                0 => switch (in.content) { // mode_key == 0
                    .escape => break :loop,
                    .codepoint => |cp| {
                        _ = switch (mode_key) {
                            0 => {
                                _ = switch (cp) {
                                    'd' => {
                                        mode_key = 'd';
                                        break;
                                    },
                                    'i' => {
                                        mode_key = 'i';
                                        break;
                                    },
                                    else => {},
                                };
                            },
                            else => {},
                        };
                        if (in.mod_ctrl) {
                            _ = switch (cp) {
                                'c' => try copy(),
                                'h' => try moveCursor(-huge_step, 0),
                                'j' => try moveCursor(0, huge_step), // note: ctrl-j is translated by the linux terminal to \r, so won't work as expected
                                'k' => try moveCursor(0, -huge_step),
                                'l' => try moveCursor(huge_step, 0),
                                'v' => try paste(),
                                else => {},
                            };
                        } else {
                            _ = switch (cp) {
                                'H' => try moveCursor(-large_step, 0),
                                'J' => try moveCursor(0, large_step),
                                'K' => try moveCursor(0, -large_step),
                                'L' => try moveCursor(large_step, 0),
                                'h' => try moveCursor(-1, 0),
                                'j' => try moveCursor(0, 1),
                                'k' => try moveCursor(0, -1),
                                'l' => try moveCursor(1, 0),
                                'q' => break :loop,
                                'x', 'D' => try delete(),
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
                'd' => switch (in.content) { // mode_key == 'd'
                    .escape => mode_key = 0,
                    .codepoint => |cp| switch (cp) {
                        'c' => {
                            mode_key = 0;
                            try deleteColumn();
                        },
                        'd' => {
                            mode_key = 0;
                            try deleteRow();
                        },
                        else => {},
                    },
                    else => {},
                },
                'i' => switch (in.content) { // mode_key == 'i'
                    .escape => {
                        mode_key = 0;
                        const value = try Value.parse(editor.line());
                        try setAt(cur.x, cur.y, value);
                        try editor.deleteAll();
                    },
                    .codepoint => |cp_u21| {
                        if (cp_u21 < 256) {
                            const cp = @truncate(u8, cp_u21);
                            _ = switch (cp) {
                                //' ', '0'...'9', 'A'...'Z', 'a'...'z' => try editor.append(cp),
                                // 10 => // line feed
                                10 => { // TODO: same code as for .escape
                                    mode_key = 0;
                                    const value = try Value.parse(editor.line());
                                    try setAt(cur.x, cur.y, value);
                                    try editor.deleteAll();
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
                                else => {
                                    std.debug.print("Unknown codepoint {}\n", .{cp});
                                },
                            };
                        } else {
                            std.debug.print("Codepoint value {d} must be < 256", .{cp_u21});
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
                        std.debug.print("Unknown in.content type {}\n", .{in.content});
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

    pub fn home(self: *Self) void {
        self.cur.x = 0;
    }

    pub fn end(self: *Self) void {
        self.cur.x = self.len();
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
        try self.content.append(string);
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

    try term.moveCursorTo(0, 0);
    try term.setAttribute(.{ .fg = .green, .reverse = true });

    try line.resize(0);
    const mode_name: []const u8 = switch (mode_key) {
        0 => "normal",
        'd' => "delete",
        'i' => "insert",
        else => @panic("Unknown mode"),
    };
    try line.writer().print("Table: {s} - {s}", .{ renderTable.name.items, mode_name });
    var remaining_columns = try term.writeLine(columns, line.items);
    try term.writeByteNTimes(' ', remaining_columns);

    // constants and variables
    var cur_y_offset: usize = 1;
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
    while (col_idx < cols.len or col_idx <= cur.x) : (col_idx += 1) {
        try term_col_pos.append(col_total_width);
        var col_width = Settings.unused_column_width;
        if (col_idx < cols.len) col_width = try cols[col_idx].maxWidth();
        if (mode_key == 'i' and col_idx == cur.x and editor.len() > col_width) col_width = editor.len();

        col_total_width += col_width + 1;
        try term_col_width.append(col_width);
    }

    // print column names
    try term.moveCursorTo(cur_y_offset, term_col_pos.items[0]);
    try term.setAttribute(.{ .fg = .red, .bold = true });
    _ = try term.writeAll("row#");
    col_idx = 0;
    while (col_idx < cols.len or col_idx <= cur.x) : (col_idx += 1) {
        try term.moveCursorTo(cur_y_offset, term_col_pos.items[col_idx + 1]);
        try term.setAttribute(.{ .fg = .red, .bold = true });
        // non-existing columns
        if (col_idx >= cols.len) {
            try line.resize(0);
            try line.writer().print("new column {d}", .{col_idx + 1 - cols.len});
        }
        const name = if (col_idx < cols.len) cols[col_idx].name.items else line.items;
        _ = try term.writeAll(name);
    }

    // print column contents
    cur_y_offset += 1;
    var has_more = cols.len > 0 and cols[0].rows.items.len > 0;
    var row_idx: usize = 0;
    // loop rows
    while (has_more or row_idx <= cur.y) : (row_idx += 1) {
        has_more = false;

        // print row number
        try term.setAttribute(.{ .fg = .red, .bold = true });
        try term.moveCursorTo(cur_y_offset + row_idx, term_col_pos.items[0]);
        try line.resize(0);
        try line.writer().print("{d}", .{row_idx + 1});
        _ = try term.writeLine(term_col_width.items[0], line.items);

        // loop columns
        col_idx = 0;
        while (col_idx < cols.len or col_idx <= cur.x) : (col_idx += 1) {
            const rows = if (col_idx < cols.len) cols[col_idx].rows.items else undefined;
            // check for every column - if any column has data, continue loop
            if (col_idx < cols.len and row_idx + 1 < rows.len) {
                has_more = true;
            }

            try term.moveCursorTo(cur_y_offset + row_idx, term_col_pos.items[col_idx + 1]);
            if (mode_key == 'i' and cur.x == col_idx and cur.y == row_idx) {
                // the text
                try term.setAttribute(.{ .fg = .yellow, .reverse = true });
                const col_width = term_col_width.items[col_idx + 1];
                const edit_width = editor.len();
                const width = if (col_width > edit_width) col_width else edit_width;
                var remaining = try term.writeLine(width, editor.line());
                try term.writeByteNTimes(' ', remaining);

                // the cursor
                try term.moveCursorTo(cur_y_offset + row_idx, term_col_pos.items[col_idx + 1] + editor.cur.x);
                try term.setAttribute(.{ .fg = .blue, .reverse = true });
                var key: u8 = ' ';
                if (editor.cur.x < editor.len()) key = editor.line()[editor.cur.x];
                try term.writeByte(key);
            } else {
                try term.setAttribute(.{ .fg = .blue, .reverse = (cur.x == col_idx and cur.y == row_idx) });

                if (col_idx < cols.len and row_idx < rows.len) {
                    try line.resize(0);
                    try rows[row_idx].write(line.writer());
                    var remaining = try term.writeLine(term_col_width.items[col_idx + 1], line.items);
                    if (col_idx + 1 < cols.len) remaining += 1;
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

/// Custom panic handler, so that we can try to cook the terminal on a crash,
/// as otherwise all messages will be mangled.
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace) noreturn {
    @setCold(true);
    term.cook() catch {};
    std.builtin.default_panic(msg, trace);
}
