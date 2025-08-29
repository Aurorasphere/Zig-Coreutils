// List directory contents
// Copyright (C) 2025 Dongjun "Aurorasphere" Kim

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.

// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
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

    // Parse flags
    var aflag = false; // show hidden files
    var lflag = false; // long format

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
            } else if (std.mem.eql(u8, arg, "--help")) {
                try printUsage();
                return 0;
            } else {
                // Process short options
                for (arg[1..]) |c| {
                    switch (c) {
                        'a' => aflag = true,
                        'l' => lflag = true,
                        else => {
                            xio.xerrorf(prog, "invalid option -- '{c}'", .{c});
                            xio.xerror(prog, "Try 'ls --help' for more information.");
                            return 1;
                        },
                    }
                }
            }
        } else {
            // Non-flag argument - add to paths
            try paths.append(arg);
        }
        i += 1;
    }

    // If no paths provided, list current directory
    const target_paths = if (paths.items.len == 0) &[_][]const u8{"."} else paths.items;

    var exit_code: u8 = 0;
    for (target_paths) |path| {
        if (listDirectory(allocator, prog, path, aflag, lflag)) |_| {
            // Success
        } else |err| {
            exit_code = 1;
            switch (err) {
                error.FileNotFound => xio.xerrorf(prog, "cannot access '{s}': No such file or directory", .{path}),
                error.AccessDenied => xio.xerrorf(prog, "cannot open directory '{s}': Permission denied", .{path}),
                error.NotDir => xio.xerrorf(prog, "cannot access '{s}': Not a directory", .{path}),
                error.OutOfMemory => xio.xerror(prog, "out of memory"),
                else => xio.xerrorf(prog, "cannot access '{s}': {}", .{ path, err }),
            }
        }
    }

    return exit_code;
}

fn printUsage() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "Usage: ls [OPTION]... [FILE]...\n");
    try xio.xwrite(posix.STDOUT_FILENO, "List information about the FILEs (the current directory by default).\n");
    try xio.xwrite(posix.STDOUT_FILENO, "\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -a                         do not ignore entries starting with .\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -l                         use a long listing format\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --help                 display this help and exit\n");
}

fn listDirectory(allocator: std.mem.Allocator, _: []const u8, path: []const u8, aflag: bool, lflag: bool) !void {
    // Open directory
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        error.NotDir => {
            // If it's a file, just print the filename
            if (lflag) {
                try printLongFormat(allocator, path, path);
            } else {
                try xio.xwrite(posix.STDOUT_FILENO, path);
                try xio.xwrite(posix.STDOUT_FILENO, "\n");
            }
            return;
        },
        else => return err,
    };
    defer dir.close();

    // Collect entries
    var entries = std.ArrayList([]const u8).init(allocator);
    defer {
        for (entries.items) |entry| {
            allocator.free(entry);
        }
        entries.deinit();
    }

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        // Skip hidden files unless -a flag is set
        if (!aflag and entry.name.len > 0 and entry.name[0] == '.') {
            continue;
        }

        // Store a copy of the name
        const name = try allocator.dupe(u8, entry.name);
        try entries.append(name);
    }

    // Sort entries
    std.mem.sort([]const u8, entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Print entries
    if (lflag) {
        for (entries.items) |name| {
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path, name });
            defer allocator.free(full_path);
            try printLongFormat(allocator, full_path, name);
        }
    } else {
        for (entries.items) |name| {
            try xio.xwrite(posix.STDOUT_FILENO, name);
            try xio.xwrite(posix.STDOUT_FILENO, "\n");
        }
    }
}

fn printLongFormat(_: std.mem.Allocator, full_path: []const u8, name: []const u8) !void {
    const stat = std.fs.cwd().statFile(full_path) catch |err| switch (err) {
        else => {
            // If we can't stat the file, just print the name
            try xio.xwrite(posix.STDOUT_FILENO, name);
            try xio.xwrite(posix.STDOUT_FILENO, "\n");
            return;
        },
    };

    // File type and permissions
    var mode_str: [11]u8 = undefined;
    formatFileMode(stat.mode, &mode_str);
    try xio.xwrite(posix.STDOUT_FILENO, mode_str[0..10]);
    try xio.xwrite(posix.STDOUT_FILENO, " ");

    // Size (simplified - just show the size)
    var size_buf: [20]u8 = undefined;
    const size_str = std.fmt.bufPrint(size_buf[0..], "{d}", .{stat.size}) catch "?";
    // Right-align size in 8 characters
    const size_padding = if (size_str.len < 8) 8 - size_str.len else 0;
    var i: usize = 0;
    while (i < size_padding) : (i += 1) {
        try xio.xwrite(posix.STDOUT_FILENO, " ");
    }
    try xio.xwrite(posix.STDOUT_FILENO, size_str);
    try xio.xwrite(posix.STDOUT_FILENO, " ");

    // Name
    try xio.xwrite(posix.STDOUT_FILENO, name);
    try xio.xwrite(posix.STDOUT_FILENO, "\n");
}

fn formatFileMode(mode: std.fs.File.Mode, buf: *[11]u8) void {
    // File type
    buf[0] = switch (mode & posix.S.IFMT) {
        posix.S.IFDIR => 'd',
        posix.S.IFREG => '-',
        posix.S.IFLNK => 'l',
        posix.S.IFBLK => 'b',
        posix.S.IFCHR => 'c',
        posix.S.IFIFO => 'p',
        posix.S.IFSOCK => 's',
        else => '?',
    };

    // Owner permissions
    buf[1] = if (mode & posix.S.IRUSR != 0) 'r' else '-';
    buf[2] = if (mode & posix.S.IWUSR != 0) 'w' else '-';
    buf[3] = if (mode & posix.S.IXUSR != 0) 'x' else '-';

    // Group permissions
    buf[4] = if (mode & posix.S.IRGRP != 0) 'r' else '-';
    buf[5] = if (mode & posix.S.IWGRP != 0) 'w' else '-';
    buf[6] = if (mode & posix.S.IXGRP != 0) 'x' else '-';

    // Other permissions
    buf[7] = if (mode & posix.S.IROTH != 0) 'r' else '-';
    buf[8] = if (mode & posix.S.IWOTH != 0) 'w' else '-';
    buf[9] = if (mode & posix.S.IXOTH != 0) 'x' else '-';

    buf[10] = 0; // null terminator
}
