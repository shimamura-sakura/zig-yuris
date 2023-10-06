// Ref: https://github.com/arcusmaximus/VNTranslationTools/blob/main/VNTextPatch.Shared/Scripts/Yuris/Notes.txt
// Ref: https://github.com/Dir-A/YurisTools/blob/main/lib/YurisStaticLibrary/YSCM.cpp

const std = @import("std");
const alloc = std.heap.page_allocator;
const cp932 = @import("zig-cp932/cp932.zig");

fn Slice(comptime T: anytype) type {
    return struct {
        const Self = @This();
        left: T,
        pub fn take(self: *Self, n: anytype) error{EOF}!@TypeOf(self.left[0..n]) {
            if (self.left.len < n) return error.EOF;
            defer self.left = self.left[n..];
            return self.left[0..n];
        }
        pub fn zstr(self: *Self) error{EOF}!@TypeOf(self.left[0..]) {
            const i = std.mem.indexOfScalar(u8, self.left, 0) orelse return error.EOF;
            defer self.left = self.left[i + 1 ..];
            return self.left[0..i];
        }
    };
}

pub fn main() anyerror!void {
    // argument
    var argIter = try std.process.argsWithAllocator(alloc);
    defer argIter.deinit();
    _ = argIter.next(); // skip program name
    const arg_input = argIter.next() orelse {
        std.debug.print("usage: program input_file\n", .{});
        return error.NoInputFile;
    };

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
        const b = try slice.take(16);
        if (!std.mem.eql(u8, b[0..4], "YSCM"))
            return error.NotYSCM;
        break :header .{
            .version = std.mem.readIntLittle(u32, b[4..8]),
            .numCmds = std.mem.readIntLittle(u32, b[8..12]),
        };
    };
    std.debug.print("YSCM version {} numCmds {}\n", .{ header.version, header.numCmds });

    // commands
    for (0..header.numCmds) |i| {
        const cmdname = try slice.zstr();
        const numAttr = (try slice.take(1))[0];
        std.debug.print("{d:3}: {s} {d}\n", .{ i, cmdname, numAttr });
        for (0..numAttr) |j| {
            const attrName = try slice.zstr();
            const b2 = try slice.take(2);
            std.debug.print("- {d:3}: {s} {d} {d}\n", .{ j, attrName, b2[0], b2[1] });
        }
    }

    // error messages
    for (0..37) |i| {
        var decoder = cp932.decoder;
        std.debug.print("E[{d:3}]: ", .{i});
        for (try slice.zstr()) |b| {
            if (try decoder.input(b)) |u|
                std.debug.print("{u}", .{u});
        }
        std.debug.print("\n", .{});
    }

    // unknown table
    std.debug.print("unknown 256 bytes:\n", .{});
    for (slice.left, 1..) |b, i| {
        std.debug.print("{x:2} {c}", .{ b, if (i % 16 == 0) @as(u8, '\n') else ' ' });
    }
}
