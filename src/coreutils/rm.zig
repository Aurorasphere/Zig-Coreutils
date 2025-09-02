// rm - remove directory entries
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

const RmOptions = struct {
    force: bool = false, // -f: do not prompt, suppress errors
    interactive: bool = false, // -i: prompt for confirmation
    recursive: bool = false, // -r, -R: remove directories recursively
    verbose: bool = false, // -v: verbose output
    remove_dirs: bool = false, // -d: remove empty directories
};

const RmError = error{
    FileNotFound,
    PermissionDenied,
    DirectoryNotEmpty,
    InvalidPath,
    OperationNotPermitted,
    IsDirectory,
    NotEmpty,
    Unexpected,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const prog = std.fs.path.basename(argv[0]);

    if (argv.len < 2) {
        xio.xerror(prog, "rm: missing operand");
        xio.xerror(prog, "Try 'rm --help' for more information.");
        return 1;
    }

    // Parse options and arguments
    var options = RmOptions{};
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    var i: usize = 1;
    while (i < argv.len) {
        const arg = argv[i];

        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--help")) {
                try printUsage();
                return 0;
            } else if (std.mem.eql(u8, arg, "--version")) {
                try printVersion();
                return 0;
            } else if (std.mem.eql(u8, arg, "-f")) {
                options.force = true;
                options.interactive = false; // -f overrides -i
            } else if (std.mem.eql(u8, arg, "-i")) {
                options.interactive = true;
                options.force = false; // -i overrides -f
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "-R")) {
                options.recursive = true;
            } else if (std.mem.eql(u8, arg, "-v")) {
                options.verbose = true;
            } else if (std.mem.eql(u8, arg, "-d")) {
                options.remove_dirs = true;
            } else if (std.mem.eql(u8, arg, "-")) {
                // Single dash is treated as a file
                try files.append(arg);
            } else {
                xio.xerrorf(prog, "rm: invalid option -- '{s}'", .{arg});
                xio.xerror(prog, "Try 'rm --help' for more information.");
                return 1;
            }
        } else {
            try files.append(arg);
        }
        i += 1;
    }

    if (files.items.len == 0) {
        if (!options.force) {
            xio.xerror(prog, "rm: missing operand");
            xio.xerror(prog, "Try 'rm --help' for more information.");
            return 1;
        }
        // -f with no operands is allowed
        return 0;
    }

    // Process each file
    var has_error = false;
    for (files.items) |file| {
        if (removeFile(allocator, file, &options)) |_| {
            // Success
        } else |err| {
            has_error = true;
            switch (err) {
                RmError.FileNotFound => {
                    if (!options.force) {
                        xio.xerrorf(prog, "rm: cannot remove '{s}': No such file or directory", .{file});
                    }
                },
                RmError.PermissionDenied => {
                    xio.xerrorf(prog, "rm: cannot remove '{s}': Permission denied", .{file});
                },
                RmError.DirectoryNotEmpty => {
                    xio.xerrorf(prog, "rm: cannot remove '{s}': Directory not empty", .{file});
                },
                RmError.IsDirectory => {
                    xio.xerrorf(prog, "rm: cannot remove '{s}': Is a directory", .{file});
                },
                RmError.NotEmpty => {
                    xio.xerrorf(prog, "rm: cannot remove '{s}': Directory not empty", .{file});
                },
                else => {
                    xio.xerrorf(prog, "rm: cannot remove '{s}': {}", .{ file, err });
                },
            }
        }
    }

    return if (has_error) 1 else 0;
}

fn removeFile(allocator: std.mem.Allocator, path: []const u8, options: *const RmOptions) !void {
    // Check for special cases first
    const basename = std.fs.path.basename(path);
    if (std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) {
        xio.xerrorf("rm", "rm: cannot remove '{s}': Invalid argument", .{path});
        return RmError.InvalidPath;
    }

    // Check if file exists
    const stat = std.fs.cwd().statFile(path) catch |err| {
        switch (err) {
            error.FileNotFound => return RmError.FileNotFound,
            error.AccessDenied => return RmError.PermissionDenied,
            else => return RmError.Unexpected,
        }
    };

    // Handle directories
    if (stat.kind == .directory) {
        if (options.recursive) {
            try removeDirectoryRecursive(allocator, path, options);
        } else if (options.remove_dirs) {
            try removeEmptyDirectory(allocator, path, options);
        } else {
            return RmError.IsDirectory;
        }
    } else {
        // Handle regular files
        try removeRegularFile(allocator, path, options);
    }
}

fn removeRegularFile(allocator: std.mem.Allocator, path: []const u8, options: *const RmOptions) !void {
    // Check if we need to prompt
    if (shouldPrompt(path, options)) {
        if (!try promptUser(allocator, path)) {
            return; // User declined
        }
    }

    // Remove the file
    std.fs.cwd().deleteFile(path) catch |err| {
        switch (err) {
            error.FileNotFound => return RmError.FileNotFound,
            error.AccessDenied => return RmError.PermissionDenied,
            error.IsDir => return RmError.IsDirectory,
            else => return RmError.Unexpected,
        }
    };

    if (options.verbose) {
        try xio.xwrite(posix.STDOUT_FILENO, "removed '");
        try xio.xwrite(posix.STDOUT_FILENO, path);
        try xio.xwrite(posix.STDOUT_FILENO, "'\n");
    }
}

fn removeEmptyDirectory(allocator: std.mem.Allocator, path: []const u8, options: *const RmOptions) !void {
    // Check if we need to prompt
    if (shouldPrompt(path, options)) {
        if (!try promptUser(allocator, path)) {
            return; // User declined
        }
    }

    // Remove the empty directory
    std.fs.cwd().deleteDir(path) catch |err| {
        switch (err) {
            error.FileNotFound => return RmError.FileNotFound,
            error.AccessDenied => return RmError.PermissionDenied,
            error.DirNotEmpty => return RmError.NotEmpty,
            else => return RmError.Unexpected,
        }
    };

    if (options.verbose) {
        try xio.xwrite(posix.STDOUT_FILENO, "removed directory '");
        try xio.xwrite(posix.STDOUT_FILENO, path);
        try xio.xwrite(posix.STDOUT_FILENO, "'\n");
    }
}

fn removeDirectoryRecursive(allocator: std.mem.Allocator, path: []const u8, options: *const RmOptions) !void {
    // Check if we need to prompt for the directory itself
    if (shouldPrompt(path, options)) {
        if (!try promptUser(allocator, path)) {
            return; // User declined
        }
    }

    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => return RmError.FileNotFound,
            error.AccessDenied => return RmError.PermissionDenied,
            else => return RmError.Unexpected,
        }
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        // Skip . and ..
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });
        defer allocator.free(full_path);

        // Recursively remove the entry
        if (entry.kind == .directory) {
            try removeDirectoryRecursive(allocator, full_path, options);
        } else {
            try removeRegularFile(allocator, full_path, options);
        }
    }

    // Now remove the empty directory
    std.fs.cwd().deleteDir(path) catch |err| {
        switch (err) {
            error.FileNotFound => return RmError.FileNotFound,
            error.AccessDenied => return RmError.PermissionDenied,
            error.DirNotEmpty => return RmError.NotEmpty,
            else => return RmError.Unexpected,
        }
    };

    if (options.verbose) {
        try xio.xwrite(posix.STDOUT_FILENO, "removed directory '");
        try xio.xwrite(posix.STDOUT_FILENO, path);
        try xio.xwrite(posix.STDOUT_FILENO, "'\n");
    }
}

fn shouldPrompt(path: []const u8, options: *const RmOptions) bool {
    if (options.force) return false;
    if (options.interactive) return true;

    // Check if file is not writable and stdin is a terminal
    const stat = std.fs.cwd().statFile(path) catch return false;
    const is_writable = (stat.mode & 0o200) != 0; // Check write permission for owner
    const is_terminal = posix.isatty(posix.STDIN_FILENO);

    return !is_writable and is_terminal;
}

fn promptUser(_: std.mem.Allocator, path: []const u8) !bool {
    try xio.xwrite(posix.STDERR_FILENO, "rm: remove '");
    try xio.xwrite(posix.STDERR_FILENO, path);
    try xio.xwrite(posix.STDERR_FILENO, "'? ");

    var buffer: [256]u8 = undefined;
    const stdin = std.io.getStdIn().reader();
    const line = stdin.readUntilDelimiterOrEof(&buffer, '\n') catch return false;

    if (line) |l| {
        // Check for affirmative responses (y, yes, etc.)
        const trimmed = std.mem.trim(u8, l, " \t\r\n");
        return std.mem.eql(u8, trimmed, "y") or
            std.mem.eql(u8, trimmed, "Y") or
            std.mem.eql(u8, trimmed, "yes") or
            std.mem.eql(u8, trimmed, "YES");
    }

    return false;
}

fn printUsage() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "Usage: rm [OPTION]... FILE...\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Remove (unlink) the FILE(s).\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -f                    ignore nonexistent files and arguments, never prompt\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -i                    prompt before every removal\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -r, -R                remove directories and their contents recursively\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -d                    remove empty directories\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -v                    explain what is being done\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --help            display this help and exit\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --version         output version information and exit\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "By default, rm does not remove directories.  Use the -r or -R option\n");
    try xio.xwrite(posix.STDOUT_FILENO, "to remove each listed directory, too, along with all of its contents.\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "To remove a file whose name starts with a '-', for example '-foo',\n");
    try xio.xwrite(posix.STDOUT_FILENO, "use one of these commands:\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  rm -- -foo\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  rm ./-foo\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Note that if you use rm to remove a file, it might be possible to recover\n");
    try xio.xwrite(posix.STDOUT_FILENO, "some of its contents, given sufficient expertise and/or time.  For greater\n");
    try xio.xwrite(posix.STDOUT_FILENO, "assurance that the contents are truly unrecoverable, consider using shred.\n");
}

fn printVersion() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "rm (zig-coreutils) 1.0.0\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Copyright (C) 2025 Dongjun \"Aurorasphere\" Kim\n");
    try xio.xwrite(posix.STDOUT_FILENO, "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "This is free software: you are free to change and redistribute it.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "There is NO WARRANTY, to the extent permitted by law.\n");
}
