// cat - concatenate files and print on the standard output
// Copyright (C) 2025 Dongjun "Aurorasphere" Kim

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.

// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR ANY PARTICULAR PURPOSE. See the GNU
// General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.

const std = @import("std");
const posix = std.posix;
const xio = @import("posix-xio.zig");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const prog = std.fs.path.basename(argv[0]);

    // POSIX cat only supports -u flag
    var u_flag: bool = false;

    // Collect non-flag arguments
    var paths = std.ArrayList([]const u8).init(allocator);
    defer paths.deinit();

    // Process arguments
    var i: usize = 1;
    while (i < argv.len) {
        const arg = argv[i];
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) {
                // End of options - add remaining args as paths
                i += 1;
                while (i < argv.len) {
                    try paths.append(argv[i]);
                    i += 1;
                }
                break;
            } else if (std.mem.eql(u8, arg, "-")) {
                // Single dash means stdin
                try paths.append(arg);
            } else if (std.mem.eql(u8, arg, "--help")) {
                try printUsage();
                return 0;
            } else if (std.mem.eql(u8, arg, "--version")) {
                try printVersion();
                return 0;
            } else if (std.mem.eql(u8, arg, "-u")) {
                u_flag = true;
            } else {
                xio.xerrorf(prog, "cat: invalid option -- '{s}'", .{arg});
                xio.xerror(prog, "Try 'cat --help' for more information.");
                return 1;
            }
        } else {
            // Non-flag argument - add to paths
            try paths.append(arg);
        }
        i += 1;
    }

    // If no paths provided, read from stdin
    const target_paths = if (paths.items.len == 0) &[_][]const u8{"-"} else paths.items;

    var exit_code: u8 = 0;
    for (target_paths) |path| {
        if (std.mem.eql(u8, path, "-")) {
            // Read from stdin
            if (catStream(allocator, std.io.getStdIn().reader(), u_flag)) |_| {
                // Success
            } else |err| {
                exit_code = 1;
                xio.xerrorf(prog, "cat: stdin: {}", .{err});
            }
        } else {
            // Read from file
            if (catFile(allocator, path, u_flag)) |_| {
                // Success
            } else |err| {
                exit_code = 1;
                switch (err) {
                    error.FileNotFound => xio.xerrorf(prog, "cat: {s}: No such file or directory", .{path}),
                    error.AccessDenied => xio.xerrorf(prog, "cat: {s}: Permission denied", .{path}),
                    error.IsDir => xio.xerrorf(prog, "cat: {s}: Is a directory", .{path}),
                    else => xio.xerrorf(prog, "cat: {s}: {}", .{ path, err }),
                }
            }
        }
    }

    return exit_code;
}

fn catFile(allocator: std.mem.Allocator, path: []const u8, u_flag: bool) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    try catStream(allocator, file.reader(), u_flag);
}

fn catStream(_: std.mem.Allocator, reader: anytype, u_flag: bool) !void {
    if (u_flag) {
        // Unbuffered mode: read and write byte by byte
        var buffer: [1]u8 = undefined;
        while (true) {
            const bytes_read = try reader.read(&buffer);
            if (bytes_read == 0) break; // EOF

            try xio.xwrite(posix.STDOUT_FILENO, buffer[0..bytes_read]);
        }
    } else {
        // Buffered mode: use larger buffer for efficiency
        var buffer: [8192]u8 = undefined;

        while (true) {
            const bytes_read = try reader.read(&buffer);
            if (bytes_read == 0) break; // EOF

            try xio.xwrite(posix.STDOUT_FILENO, buffer[0..bytes_read]);
        }
    }
}

fn printUsage() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "Usage: cat [OPTION]... [FILE]...\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Concatenate FILE(s) to standard output.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -u                         write bytes from input to output without delay\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --help                 display this help and exit\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --version              output version information and exit\n");
    try xio.xwrite(posix.STDOUT_FILENO, "\n");
    try xio.xwrite(posix.STDOUT_FILENO, "With no FILE, or when FILE is -, read standard input.\n");
}

fn printVersion() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "cat (zig-coreutils) 1.0.0\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Copyright (C) 2025 Dongjun \"Aurorasphere\" Kim\n");
    try xio.xwrite(posix.STDOUT_FILENO, "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "This is free software: you are free to change and redistribute it.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "There is NO WARRANTY, to the extent permitted by law.\n");
}
