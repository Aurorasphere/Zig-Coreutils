// Create directories
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

    var argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    _ = std.fs.path.basename(argv[0]); // prog variable not used in this implementation
    const args = if (argv.len > 1) argv[1..] else &[_][]const u8{};

    var parents = false; // -p flag
    var mode: std.posix.mode_t = 0o755; // default mode
    var paths = std.ArrayList([]const u8).init(allocator);
    defer paths.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--parents")) {
                parents = true;
            } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--mode")) {
                if (i + 1 >= args.len) {
                    xio.xwrite(2, "mkdir: missing operand after '-m'\n") catch {};
                    return 1;
                }
                i += 1;
                const mode_str = args[i];
                mode = parseMode(mode_str) catch |e| {
                    xio.xwrite(2, "mkdir: invalid mode '") catch {};
                    xio.xwrite(2, mode_str) catch {};
                    xio.xwrite(2, "': ") catch {};
                    xio.xwrite(2, @errorName(e)) catch {};
                    xio.xwrite(2, "\n") catch {};
                    return 1;
                };
            } else if (std.mem.eql(u8, arg, "--help")) {
                try printUsage();
                return 0;
            } else if (std.mem.eql(u8, arg, "--version")) {
                try printVersion();
                return 0;
            } else if (std.mem.eql(u8, arg, "--")) {
                i += 1;
                break;
            } else {
                xio.xwrite(2, "mkdir: invalid option -- ") catch {};
                xio.xwrite(2, arg) catch {};
                xio.xwrite(2, "\n") catch {};
                xio.xwrite(2, "Try 'mkdir --help' for more information.\n") catch {};
                return 1;
            }
        } else {
            try paths.append(arg);
        }
    }

    // Add remaining arguments as paths
    while (i < args.len) : (i += 1) {
        try paths.append(args[i]);
    }

    if (paths.items.len == 0) {
        xio.xwrite(2, "mkdir: missing operand\n") catch {};
        xio.xwrite(2, "Try 'mkdir --help' for more information.\n") catch {};
        return 1;
    }

    // Create directories
    var has_error = false;
    for (paths.items) |path| {
        if (createDirectory(path, parents, mode, allocator)) |_| {
            // Success
        } else |e| {
            has_error = true;
            xio.xwrite(2, "mkdir: cannot create directory '") catch {};
            xio.xwrite(2, path) catch {};
            xio.xwrite(2, "': ") catch {};
            switch (e) {
                error.AccessDenied => xio.xwrite(2, "Permission denied\n") catch {},
                error.FileNotFound => xio.xwrite(2, "No such file or directory\n") catch {},
                error.PathAlreadyExists => xio.xwrite(2, "File exists\n") catch {},
                error.NameTooLong => xio.xwrite(2, "File name too long\n") catch {},
                error.DiskQuota => xio.xwrite(2, "Disk quota exceeded\n") catch {},
                error.NoSpaceLeft => xio.xwrite(2, "No space left on device\n") catch {},
                else => {
                    xio.xwrite(2, @errorName(e)) catch {};
                    xio.xwrite(2, "\n") catch {};
                },
            }
        }
    }

    return if (has_error) 1 else 0;
}

fn createDirectory(path: []const u8, parents: bool, mode: std.posix.mode_t, allocator: std.mem.Allocator) !void {
    if (parents) {
        try createDirectoryRecursive(path, mode, allocator);
    } else {
        // Check if directory already exists
        if (std.fs.cwd().access(path, .{})) |_| {
            return error.PathAlreadyExists;
        } else |_| {
            // Directory doesn't exist, create it with specified mode
            try posix.mkdir(path, mode);
        }
    }
}

fn createDirectoryRecursive(path: []const u8, mode: std.posix.mode_t, allocator: std.mem.Allocator) !void {
    var path_parts = std.ArrayList([]const u8).init(allocator);
    defer path_parts.deinit();

    // Split path into components
    var iter = try std.fs.path.componentIterator(path);
    while (iter.next()) |component| {
        if (component.name.len > 0) {
            try path_parts.append(component.name);
        }
    }

    var current_path = std.ArrayList(u8).init(allocator);
    defer current_path.deinit();

    // Create each component of the path
    for (path_parts.items) |part| {
        if (current_path.items.len > 0) {
            try current_path.append('/');
        }
        try current_path.appendSlice(part);

        const full_path = current_path.items;
        if (std.fs.cwd().access(full_path, .{})) |_| {
            // Path exists, check if it's a directory
            const stat = try std.fs.cwd().statFile(full_path);
            if (stat.kind != .directory) {
                return error.PathAlreadyExists;
            }
        } else |_| {
            // Path doesn't exist, create it with specified mode
            try posix.mkdir(full_path, mode);
        }
    }
}

fn parseMode(mode_str: []const u8) !std.posix.mode_t {
    if (mode_str.len == 0) return error.InvalidMode;

    // Handle octal mode (e.g., "755", "0700")
    if (mode_str[0] >= '0' and mode_str[0] <= '7') {
        return std.fmt.parseInt(std.posix.mode_t, mode_str, 8);
    }

    // Handle symbolic mode (e.g., "u+rwx", "g-w") - simplified version
    // For now, just support basic octal parsing
    return error.InvalidMode;
}

fn printUsage() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "Usage: mkdir [OPTION]... DIRECTORY...\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Create the DIRECTORY(ies), if they do not already exist.\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -m, --mode=MODE   set file permissions (as in chmod)\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -p, --parents     no error if existing, make parent directories as needed\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --help        display this help and exit\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --version     output version information and exit\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Examples:\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  mkdir -p /tmp/a/b/c  Create directory /tmp/a/b/c, creating parent directories\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  mkdir -m 700 dir     Create directory 'dir' with permissions 700\n");
}

fn printVersion() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "mkdir (zig-coreutils) 1.0.0\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Copyright (C) 2025 Dongjun \"Aurorasphere\" Kim\n");
    try xio.xwrite(posix.STDOUT_FILENO, "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "This is free software: you are free to change and redistribute it.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "There is NO WARRANTY, to the extent permitted by law.\n");
}
