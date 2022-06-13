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

pub fn main() !void {
    var t1 = Table.fromCSV("io") catch
        Table.init("io") catch {
        @panic("");
    };
    defer t1.deinit();
    renderTable = t1;

    try t1.write(std.io.getStdOut().writer());
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
    try term.setWindowTitle("bash");
}

fn render(_: *spoon.Term, _: usize, columns: usize) !void {
    try term.clear();

    try term.moveCursorTo(0, 0);
    try term.setAttribute(.{ .fg = .green, .reverse = true });
    var remaining_columns = try term.writeLine(columns, "Table: ");
    remaining_columns = try term.writeLine(remaining_columns, renderTable.name.items);
    try term.writeByteNTimes(' ', remaining_columns);

    // get the width and starting term column of every table column
    var term_col_width = std.ArrayList(usize).init(croc);
    defer term_col_width.deinit();
    var term_col_pos = std.ArrayList(usize).init(croc);
    defer term_col_pos.deinit();
    var col_total_width: usize = 0;
    for (renderTable.columns.items) |col| {
        try term_col_pos.append(col_total_width);
        const col_width = try col.max_width();
        try term_col_width.append(col_width);
        col_total_width += col_width + 1;
    }

    // print column names
    var render_row: usize = 1;
    for (renderTable.columns.items) |col, idx| {
        try term.moveCursorTo(render_row, term_col_pos.items[idx]);
        try term.setAttribute(.{ .fg = .red, .bold = true });
        _ = try term.writeAll(col.name.items);
    }

    // print column contents
    render_row += 1;
    var line = std.ArrayList(u8).init(croc);
    defer line.deinit();
    var row_idx: usize = 0;
    var has_more: bool = false;
    if (renderTable.columns.items.len > 0) {
        const col0 = renderTable.columns.items[0];
        if (col0.rows.items.len > 0) {
            has_more = true;
        }
    }
    //has_more = renderTable.columns.items.len > 0 and renderTable.columns.items[0].rows.items.len > 0;

    while (has_more) : (row_idx += 1) {
        has_more = false;
        for (renderTable.columns.items) |col, idx| {
            // check for every column - if any column has data, continue loop
            if (col.rows.items.len > row_idx + 1) {
                has_more = true;
            }

            if (col.rows.items.len > row_idx) {
                const row = col.rows.items[row_idx];
                try row.write(line.writer());
                try term.moveCursorTo(render_row + row_idx, term_col_pos.items[idx]);
                try term.setAttribute(.{ .fg = .blue, .reverse = (cur_x == idx and cur_y == row_idx) });
                var remaining = try term.writeLine(term_col_width.items[idx], line.items);
                if (idx + 1 < renderTable.columns.items.len) remaining += 1;
                try term.writeByteNTimes(' ', remaining);
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
