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

var cur_x: usize = 0;
var cur_y: usize = 0;
var renderTable: Table = undefined;

const Settings = struct {
    const unused_column_width: usize = 10;
};

pub fn main() !void {
    var t1 = Table.fromCSV("io") catch
        Table.init("io") catch {
        @panic("");
    };
    defer t1.deinit();
    renderTable = t1;

    // try t1.write(std.io.getStdOut().writer());
    try t1.save();

    try term.init(render);
    defer term.deinit();

    os.sigaction(os.SIG.WINCH, &os.Sigaction{
        .handler = .{ .handler = handleSigWinch },
        .mask = os.empty_sigset,
        .flags = 0,
    }, null);

    var fds: [1]os.pollfd = undefined;
    fds[0] = .{
        .fd = term.tty.handle,
        .events = os.POLL.IN,
        .revents = undefined,
    };

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

    var buf: [16]u8 = undefined;
    while (loop) {
        _ = try os.poll(&fds, -1);

        const read = try term.readInput(&buf);
        var it = spoon.inputParser(buf[0..read]);
        while (it.next()) |in| {
            switch (in.content) {
                .escape => {
                    loop = false;
                    break;
                },
                .codepoint => |cp| {
                    if (cp == 'q') loop = false;
                    break;
                },
                .arrow_right => {
                    // TODO: 99
                    if (cur_x < 99) {
                        cur_x += 1;
                        try term.updateContent();
                    }
                },
                .arrow_left => {
                    if (cur_x > 0) {
                        cur_x -= 1;
                        try term.updateContent();
                    }
                },
                .arrow_down => {
                    // TODO: 99
                    if (cur_y < 99) {
                        cur_y += 1;
                        try term.updateContent();
                    }
                },
                .arrow_up => {
                    if (cur_y > 0) {
                        cur_y -= 1;
                        try term.updateContent();
                    }
                },
                else => {},
            }
        }
    }
}

fn render(_: *spoon.Term, _: usize, columns: usize) !void {
    try term.clear();

    try term.moveCursorTo(0, 0);
    try term.setAttribute(.{ .fg = .green, .reverse = true });
    var remaining_columns = try term.writeLine(columns, "Table: ");
    remaining_columns = try term.writeLine(remaining_columns, renderTable.name.items);
    try term.writeByteNTimes(' ', remaining_columns);

    // constants and variables
    var cur_y_offset: usize = 1;
    var col_total_width: usize = 0;
    const cols = renderTable.columns.items;
    var line = std.ArrayList(u8).init(croc);
    defer line.deinit();
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
    while (col_idx < cols.len or col_idx <= cur_x) : (col_idx += 1) {
        try term_col_pos.append(col_total_width);
        const col_width = if (col_idx < cols.len) try cols[col_idx].max_width() else Settings.unused_column_width;
        col_total_width += col_width + 1;
        try term_col_width.append(col_width);
    }

    // print column names

    try term.moveCursorTo(cur_y_offset, term_col_pos.items[0]);
    try term.setAttribute(.{ .fg = .red, .bold = true });
    _ = try term.writeAll("row#");
    col_idx = 0;
    while (col_idx < cols.len or col_idx <= cur_x) : (col_idx += 1) {
        try term.moveCursorTo(cur_y_offset, term_col_pos.items[col_idx + 1]);
        try term.setAttribute(.{ .fg = .red, .bold = true });
        // non-existing columns
        if (col_idx >= cols.len) {
            try line.resize(0);
            try line.writer().print("column {d}", .{col_idx + 1});
        }
        const name = if (col_idx < cols.len) cols[col_idx].name.items else line.items;
        _ = try term.writeAll(name);
    }

    // print column contents
    cur_y_offset += 1;
    var has_more = cols.len > 0 and cols[0].rows.items.len > 0;
    var row_idx: usize = 0;
    // loop rows
    while (has_more or row_idx <= cur_y) : (row_idx += 1) {
        has_more = false;

        // print row number
        try term.setAttribute(.{ .fg = .red, .bold = true });
        try term.moveCursorTo(cur_y_offset + row_idx, term_col_pos.items[0]);
        try line.resize(0);
        try line.writer().print("{d}", .{row_idx + 1});
        _ = try term.writeLine(term_col_width.items[0], line.items);

        // loop columns
        col_idx = 0;
        while (col_idx < cols.len or col_idx <= cur_x) : (col_idx += 1) {
            const rows = if (col_idx < cols.len) cols[col_idx].rows.items else undefined;
            // check for every column - if any column has data, continue loop
            if (col_idx < cols.len and row_idx + 1 < rows.len) {
                has_more = true;
            }

            try term.moveCursorTo(cur_y_offset + row_idx, term_col_pos.items[col_idx + 1]);
            try term.setAttribute(.{ .fg = .blue, .reverse = (cur_x == col_idx and cur_y == row_idx) });

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
