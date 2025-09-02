// cp - copy files and directories
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

const CpOptions = struct {
    force: bool = false, // -f: force, remove existing destination files
    interactive: bool = false, // -i: prompt before overwrite
    recursive: bool = false, // -R: copy directories recursively
    preserve: bool = false, // -p: preserve file attributes
    follow_links: FollowLinks = .unspecified, // -H, -L, -P: how to handle symbolic links
};

const FollowLinks = enum {
    unspecified, // Default behavior
    H, // -H: follow links specified as operands
    L, // -L: follow all symbolic links
    P, // -P: preserve symbolic links
};

const CpError = error{
    FileNotFound,
    PermissionDenied,
    IsDirectory,
    NotDirectory,
    FileExists,
    CrossDeviceLink,
    Unexpected,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const prog = std.fs.path.basename(argv[0]);

    // Parse options and arguments
    var options = CpOptions{};
    var sources = std.ArrayList([]const u8).init(allocator);
    defer sources.deinit();
    var destination: []const u8 = undefined;

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
            } else if (std.mem.eql(u8, arg, "-R")) {
                options.recursive = true;
            } else if (std.mem.eql(u8, arg, "-p")) {
                options.preserve = true;
            } else if (std.mem.eql(u8, arg, "-H")) {
                options.follow_links = .H;
            } else if (std.mem.eql(u8, arg, "-L")) {
                options.follow_links = .L;
            } else if (std.mem.eql(u8, arg, "-P")) {
                options.follow_links = .P;
            } else if (std.mem.eql(u8, arg, "-")) {
                // Single dash is treated as a source file
                try sources.append(arg);
            } else {
                xio.xerrorf(prog, "cp: invalid option -- '{s}'", .{arg});
                xio.xerror(prog, "Try 'cp --help' for more information.");
                return 1;
            }
        } else {
            if (i == argv.len - 1) {
                // Last argument is the destination
                destination = arg;
            } else {
                // All other arguments are sources
                try sources.append(arg);
            }
        }
        i += 1;
    }

    if (sources.items.len == 0) {
        xio.xerror(prog, "cp: missing file operand");
        xio.xerror(prog, "Try 'cp --help' for more information.");
        return 1;
    }

    // Check if destination exists and is a directory
    const dest_stat = std.fs.cwd().statFile(destination) catch |err| {
        switch (err) {
            error.FileNotFound => {
                // Destination doesn't exist, treat as file
                if (sources.items.len > 1) {
                    xio.xerrorf(prog, "cp: target '{s}' is not a directory", .{destination});
                    return 1;
                }
                copyFile(allocator, sources.items[0], destination, &options) catch |copy_err| {
                    handleCopyError(prog, sources.items[0], destination, copy_err);
                    return 1;
                };
                return 0;
            },
            error.AccessDenied => return CpError.PermissionDenied,
            else => return CpError.Unexpected,
        }
    };

    if (dest_stat.kind == .directory) {
        // Destination is a directory, copy each source into it
        var has_error = false;
        for (sources.items) |source| {
            const basename = std.fs.path.basename(source);
            const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ destination, basename });
            defer allocator.free(dest_path);

            if (copyFile(allocator, source, dest_path, &options)) |_| {
                // Success
            } else |err| {
                has_error = true;
                handleCopyError(prog, source, dest_path, err);
            }
        }
        return if (has_error) 1 else 0;
    } else {
        // Destination is a file
        if (sources.items.len > 1) {
            xio.xerrorf(prog, "cp: target '{s}' is not a directory", .{destination});
            return 1;
        }
        copyFile(allocator, sources.items[0], destination, &options) catch |copy_err| {
            handleCopyError(prog, sources.items[0], destination, copy_err);
            return 1;
        };
        return 0;
    }
}

fn copyFile(allocator: std.mem.Allocator, source: []const u8, destination: []const u8, options: *const CpOptions) !void {
    // Check if source exists
    const source_stat = std.fs.cwd().statFile(source) catch |err| {
        switch (err) {
            error.FileNotFound => return CpError.FileNotFound,
            error.AccessDenied => return CpError.PermissionDenied,
            else => return CpError.Unexpected,
        }
    };

    // Handle directories
    if (source_stat.kind == .directory) {
        if (options.recursive) {
            try copyDirectoryRecursive(allocator, source, destination, options);
        } else {
            return CpError.IsDirectory;
        }
    } else {
        // Handle regular files
        try copyRegularFile(allocator, source, destination, options);
    }
}

fn copyRegularFile(allocator: std.mem.Allocator, source: []const u8, destination: []const u8, options: *const CpOptions) !void {
    // Check if destination exists
    _ = std.fs.cwd().statFile(destination) catch |err| {
        switch (err) {
            error.FileNotFound => {
                // Destination doesn't exist, proceed with copy
                return copyFileContents(allocator, source, destination, options);
            },
            error.AccessDenied => return CpError.PermissionDenied,
            else => return CpError.Unexpected,
        }
    };

    // Note: Same file detection would require inode comparison,
    // but Zig's Stat struct doesn't expose inode information

    // Destination exists, check if we need to prompt
    if (shouldPrompt(destination, options)) {
        if (!try promptUser(allocator, destination)) {
            return; // User declined
        }
    }

    // Remove existing file if -f is specified
    if (options.force) {
        std.fs.cwd().deleteFile(destination) catch |err| {
            switch (err) {
                error.FileNotFound => {}, // Already handled above
                error.AccessDenied => return CpError.PermissionDenied,
                else => return CpError.Unexpected,
            }
        };
    }

    // Handle symbolic links according to POSIX standard
    if (options.follow_links == .P) {
        // -P: preserve symbolic links
        const link_stat = try std.fs.cwd().statFile(source);
        if (link_stat.kind == .sym_link) {
            // Copy the symbolic link itself
            var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const link_target = try std.fs.readLinkAbsolute(source, &link_buffer);
            std.fs.cwd().symLink(link_target, destination, .{}) catch |err| {
                switch (err) {
                    error.AccessDenied => return CpError.PermissionDenied,
                    error.PathAlreadyExists => return CpError.FileExists,
                    else => return CpError.Unexpected,
                }
            };
            return;
        }
    }

    // Proceed with file copy
    try copyFileContents(allocator, source, destination, options);
}

fn copyFileContents(_: std.mem.Allocator, source: []const u8, destination: []const u8, options: *const CpOptions) !void {
    // Copy the file
    const source_file = std.fs.cwd().openFile(source, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return CpError.FileNotFound,
            error.AccessDenied => return CpError.PermissionDenied,
            else => return CpError.Unexpected,
        }
    };
    defer source_file.close();

    const dest_file = std.fs.cwd().createFile(destination, .{}) catch |err| {
        switch (err) {
            error.AccessDenied => return CpError.PermissionDenied,
            error.PathAlreadyExists => return CpError.FileExists,
            else => return CpError.Unexpected,
        }
    };
    defer dest_file.close();

    // Copy file contents
    const buffer_size = 8192;
    var buffer: [buffer_size]u8 = undefined;
    while (true) {
        const bytes_read = source_file.read(&buffer) catch |err| {
            switch (err) {
                error.AccessDenied => return CpError.PermissionDenied,
                else => return CpError.Unexpected,
            }
        };
        if (bytes_read == 0) break;

        dest_file.writeAll(buffer[0..bytes_read]) catch |err| {
            switch (err) {
                error.AccessDenied => return CpError.PermissionDenied,
                else => return CpError.Unexpected,
            }
        };
    }

    // Preserve file attributes if -p is specified
    if (options.preserve) {
        const source_stat = try std.fs.cwd().statFile(source);
        // Set file permissions (mode)
        const dest_file_for_chmod = std.fs.cwd().openFile(destination, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => return CpError.FileNotFound,
                error.AccessDenied => return CpError.PermissionDenied,
                else => return CpError.Unexpected,
            }
        };
        defer dest_file_for_chmod.close();

        dest_file_for_chmod.chmod(source_stat.mode) catch |err| {
            switch (err) {
                error.AccessDenied => return CpError.PermissionDenied,
                else => return CpError.Unexpected,
            }
        };
        // Note: Setting timestamps and ownership requires additional system calls
        // that are not yet available in Zig's standard library
    }
}

fn copyDirectoryRecursive(allocator: std.mem.Allocator, source: []const u8, destination: []const u8, options: *const CpOptions) !void {
    const source_stat = try std.fs.cwd().statFile(source);

    // Create destination directory with proper permissions
    const dir_mode = if (options.preserve)
        source_stat.mode
    else
        source_stat.mode | 0o700; // Add read/write/execute for owner

    posix.mkdir(destination, dir_mode) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {
                // Check if it's a directory
                const dest_stat = std.fs.cwd().statFile(destination) catch return CpError.Unexpected;
                if (dest_stat.kind != .directory) {
                    return CpError.NotDirectory;
                }
            },
            error.AccessDenied => return CpError.PermissionDenied,
            else => return CpError.Unexpected,
        }
    };

    var source_dir = std.fs.cwd().openDir(source, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => return CpError.FileNotFound,
            error.AccessDenied => return CpError.PermissionDenied,
            else => return CpError.Unexpected,
        }
    };
    defer source_dir.close();

    var iterator = source_dir.iterate();
    while (try iterator.next()) |entry| {
        // Skip . and ..
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        const source_path = try std.fs.path.join(allocator, &[_][]const u8{ source, entry.name });
        defer allocator.free(source_path);
        const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ destination, entry.name });
        defer allocator.free(dest_path);

        // Recursively copy the entry
        if (entry.kind == .directory) {
            try copyDirectoryRecursive(allocator, source_path, dest_path, options);
        } else {
            try copyRegularFile(allocator, source_path, dest_path, options);
        }
    }

    // Set final directory permissions if -p is specified
    if (options.preserve) {
        var dest_dir = std.fs.cwd().openDir(destination, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => return CpError.FileNotFound,
                error.AccessDenied => return CpError.PermissionDenied,
                else => return CpError.Unexpected,
            }
        };
        defer dest_dir.close();

        dest_dir.chmod(source_stat.mode) catch |err| {
            switch (err) {
                error.AccessDenied => return CpError.PermissionDenied,
                else => return CpError.Unexpected,
            }
        };
    }
}

fn shouldPrompt(path: []const u8, options: *const CpOptions) bool {
    if (options.force) return false;
    if (options.interactive) return true;

    // Check if file is not writable and stdin is a terminal
    const stat = std.fs.cwd().statFile(path) catch return false;
    const is_writable = (stat.mode & 0o200) != 0; // Check write permission for owner
    const is_terminal = posix.isatty(posix.STDIN_FILENO);

    return !is_writable and is_terminal;
}

fn promptUser(_: std.mem.Allocator, path: []const u8) !bool {
    try xio.xwrite(posix.STDERR_FILENO, "cp: overwrite '");
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

fn handleCopyError(prog: []const u8, source: []const u8, destination: []const u8, err: anyerror) void {
    switch (err) {
        CpError.FileNotFound => {
            xio.xerrorf(prog, "cp: cannot stat '{s}': No such file or directory", .{source});
        },
        CpError.PermissionDenied => {
            xio.xerrorf(prog, "cp: cannot open '{s}': Permission denied", .{source});
        },
        CpError.IsDirectory => {
            xio.xerrorf(prog, "cp: omitting directory '{s}'", .{source});
        },
        CpError.NotDirectory => {
            xio.xerrorf(prog, "cp: cannot create directory '{s}': File exists", .{destination});
        },
        CpError.FileExists => {
            xio.xerrorf(prog, "cp: cannot create '{s}': File exists", .{destination});
        },
        CpError.CrossDeviceLink => {
            xio.xerrorf(prog, "cp: cannot create link '{s}': Cross-device link", .{destination});
        },
        else => {
            xio.xerrorf(prog, "cp: cannot copy '{s}' to '{s}': {}", .{ source, destination, err });
        },
    }
}

fn printUsage() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "Usage: cp [OPTION]... SOURCE... DEST\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -f                    if an existing destination file cannot be opened, remove it and try again\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -H                    take actions based on the type and contents of the file referenced by any symbolic link specified as a source_file operand\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -i                    prompt before overwrite\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -L                    take actions based on the type and contents of the file referenced by any symbolic link specified as a source_file operand or any symbolic links encountered during traversal of a file hierarchy\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -P                    take actions on any symbolic link specified as a source_file operand or any symbolic link encountered during traversal of a file hierarchy\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -p                    preserve file attributes\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -R                    copy directories recursively\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --help            display this help and exit\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --version         output version information and exit\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "The cp utility shall copy the contents of source_file to the destination path.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "When -R is specified, cp shall copy each file in the file hierarchy rooted in each source_file.\n");
}

fn printVersion() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "cp (zig-coreutils) 1.0.0\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Copyright (C) 2025 Dongjun \"Aurorasphere\" Kim\n");
    try xio.xwrite(posix.STDOUT_FILENO, "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "This is free software: you are free to change and redistribute it.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "There is NO WARRANTY, to the extent permitted by law.\n");
}
