const std = @import("std");
const alloc = std.heap.page_allocator;

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

/// magic  [4]u8 = "YSMV"
/// unk_0  u32
/// nFiles u32
///
/// <- seek to 0x20 ->
/// offsets [nFiles]u32
/// lengths [nFiles]u32
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
        if (!std.mem.eql(u8, h[0..4], "YSMV"))
            return error.NotYSMV;
        break :header .{
            .entries = std.mem.readIntLittle(u32, h[8..12]),
        };
    };
    std.debug.print("YSMV entries {}\n", .{header.entries});

    // entries
    const entries = try alloc.alloc(struct {
        offset: u32,
        length: u32,
        unknow: u32,
    }, header.entries);
    defer alloc.free(entries);
    const n_digits = std.math.log10_int(@min(10, entries.len));
    for (entries) |*ent| ent.offset = std.mem.readIntLittle(u32, try slice.take(4));
    for (entries) |*ent| ent.length = std.mem.readIntLittle(u32, try slice.take(4));
    for (entries) |*ent| ent.unknow = std.mem.readIntLittle(u32, try slice.take(4));
    for (entries, 0..) |ent, i|
        std.debug.print("[{d:[1]}] offset 0x{2x:0>6} length {3:5} unknown {4x:0>8}\n", .{ i, n_digits, ent.offset, ent.length, ent.unknow });

    // decode
    for (entries) |ent| {
        for (bytes[ent.offset..][0..ent.length], 0..) |*b, i|
            b.* ^= @intCast((i & 0x0F) + 16);
    }

    // name
    var path_buffer = std.ArrayList(u8).init(alloc);
    var path_writer = path_buffer.writer();
    defer path_buffer.deinit();

    // write
    for (entries, 0..) |ent, i| {
        path_buffer.clearRetainingCapacity();
        try path_writer.print("{d:0<[1]}", .{ i, n_digits });
        std.debug.print("{s} length {}\n", .{ path_buffer.items, ent.length });
        try out_dir.writeFile(path_buffer.items, bytes[ent.offset..][0..ent.length]);
    }
}
