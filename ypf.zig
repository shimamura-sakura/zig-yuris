const std = @import("std");
const alloc = std.heap.page_allocator;
const cp932 = @import("zig-cp932/cp932.zig");
const deflate = std.compress.deflate;

const NAME_LENGTH = tbl: {
    var table: [256]u8 = undefined;
    for (0..256) |i|
        table[i] = @intCast(i);
    for (.{
        .{ 3, 72 },
        .{ 6, 53 },
        .{ 9, 11 },
        .{ 12, 16 },
        .{ 13, 19 },
        .{ 17, 25 },
        .{ 21, 27 },
        .{ 28, 30 },
        .{ 32, 35 },
        .{ 38, 41 },
        .{ 44, 47 },
        .{ 46, 50 },
    }) |p|
        std.mem.swap(u8, &table[p[0]], &table[p[1]]);
    break :tbl table;
};

fn Slice(comptime T: anytype) type {
    return struct {
        const Self = @This();
        left: T,
        pub fn take(self: *Self, n: anytype) error{EOF}!@TypeOf(self.left[0..n]) {
            if (self.left.len < n) return error.EOF;
            defer self.left = self.left[n..];
            return self.left[0..n];
        }
    };
}

const TEST_PATH = "/lipsum/games/RJ367965/pac/YSbin.ypf";

pub fn main() anyerror!void {
    // argument
    var argIter = try std.process.argsWithAllocator(alloc);
    defer argIter.deinit();
    _ = argIter.next(); // skip program name
    const arg_input = argIter.next() orelse {
        std.debug.print("usage: program input_file [output_directory]\n", .{});
        return error.NoInputFile;
    };
    const arg_output = argIter.next() orelse ".";

    // open output dir
    var out_dir = std.fs.cwd().makeOpenPath(arg_output, .{}) catch return error.OpenOutputDir;
    defer out_dir.close();

    // read file
    const bytes = bytes: {
        const file = try std.fs.cwd().openFileZ(arg_input, .{});
        defer file.close();
        const data = try alloc.alloc(u8, @intCast(try file.getEndPos()));
        errdefer alloc.free(data);
        _ = try file.reader().readAll(data);
        break :bytes data;
    };
    defer alloc.free(bytes);
    var slice: Slice([]const u8) = .{ .left = bytes };

    // header
    const header = header: {
        const h = try slice.take(32);
        if (!std.mem.eql(u8, h[0..4], &.{ 'Y', 'P', 'F', 0 }))
            return error.NotYPF0;
        break :header .{
            .version = std.mem.readIntLittle(u32, h[4..8]),
            .entries = std.mem.readIntLittle(u32, h[8..12]),
        };
    };
    const fl_u64Offset = header.version >= 480;
    const fl_hashField = header.version >= 464;
    // originally 473
    // fix for １人殺すのも２人殺すのも同じことだと思うから which is 464.

    std.debug.print("YPF0 version {} entries {}\n", .{ header.version, header.entries });

    var path_buffer = std.ArrayList(u8).init(alloc);
    var path_writer = path_buffer.writer();
    defer path_buffer.deinit();

    // entries
    for (0..header.entries) |i| {
        // read entry
        const b1 = try slice.take(5); // name hash (4) and size (1)
        const name_hash = std.mem.readIntLittle(u32, b1[0..4]);
        const name_size = NAME_LENGTH[~b1[4]];
        const name_data = try slice.take(name_size); // name in cp932 with bits flipped
        const b2 = try slice.take(10); // type (1) compressed? (1) un-size (4) comp-size (4)
        const file_type = b2[0];
        const file_comp = b2[1] != 0;
        const file_size = std.mem.readIntLittle(u32, b2[2..6]);
        const comp_size = std.mem.readIntLittle(u32, b2[6..10]);
        const file_offs = if (fl_u64Offset)
            std.mem.readIntLittle(u64, try slice.take(8))
        else
            std.mem.readIntLittle(u32, try slice.take(4));
        const file_hash = if (fl_hashField)
            std.mem.readIntLittle(u32, try slice.take(4))
        else
            0;

        // make path
        path_buffer.clearRetainingCapacity();
        var prev_delim = true;
        var decoder = cp932.decoder;
        for (name_data) |b|
            if (try decoder.input(~b)) |u| switch (u) {
                '\\', '/' => {
                    if (prev_delim) continue;
                    try path_buffer.append('/');
                    prev_delim = true;
                },
                else => {
                    try path_writer.print("{u}", .{u});
                    prev_delim = false;
                },
            };
        std.debug.print("{d:3}: {s}\n", .{ i, path_buffer.items });
        if (std.mem.lastIndexOfScalar(u8, path_buffer.items, '/')) |i_delim|
            try out_dir.makePath(path_buffer.items[0..i_delim]);

        // write file
        const comp_data = bytes[file_offs..][0..comp_size];
        if (file_comp) {
            if (comp_data[0] != 0x78)
                return error.CompressNot0x78;
            const file_data = try alloc.alloc(u8, file_size);
            defer alloc.free(file_data);
            var data_stream = std.io.fixedBufferStream(comp_data[2..]);
            var decm_stream = try deflate.decompressor(alloc, data_stream.reader(), null);
            defer decm_stream.deinit();
            try decm_stream.reader().readNoEof(file_data);
            try out_dir.writeFile(path_buffer.items, file_data);
        } else {
            try out_dir.writeFile(path_buffer.items, comp_data);
        }

        _ = file_type;
        _ = name_hash;
        _ = file_hash;
    }
}
