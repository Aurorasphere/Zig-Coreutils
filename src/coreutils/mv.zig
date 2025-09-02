// mv - move files
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

const MvOptions = struct {
    force: bool = false, // -f: do not prompt for confirmation
    interactive: bool = false, // -i: prompt for confirmation
};

const MvError = error{
    FileNotFound,
    PermissionDenied,
    PathAlreadyExists,
    IsDirectory,
    NotDirectory,
    CrossDeviceLink,
    NoSpaceLeft,
    InvalidUtf8,
    FileTooBig,
    DeviceBusy,
    SystemResources,
    WouldBlock,
    NoDevice,
    OutOfMemory,
    SharingViolation,
    PipeBusy,
    NameTooLong,
    InvalidWtf8,
    BadPathName,
    NetworkNotFound,
    AntivirusInterference,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    IsDir,
    NotDir,
    FileLocksNotSupported,
    FileBusy,
    AccessDenied,
    Unexpected,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const prog = std.fs.path.basename(argv[0]);

    // Handle --help and --version first
    if (argv.len >= 2) {
        if (std.mem.eql(u8, argv[1], "--help")) {
            try printUsage();
            return 0;
        } else if (std.mem.eql(u8, argv[1], "--version")) {
            try printVersion();
            return 0;
        }
    }

    if (argv.len < 3) {
        xio.xerror("mv", "missing file operand");
        xio.xerror("mv", "Try 'mv --help' for more information.");
        return 1;
    }

    // Parse options
    var options = MvOptions{};
    var files = std.ArrayList([]const u8).init(allocator);
    defer files.deinit();

    var i: usize = 1;
    while (i < argv.len) {
        const arg = argv[i];
        if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // Parse short options
            for (arg[1..]) |c| {
                switch (c) {
                    'f' => {
                        options.force = true;
                        options.interactive = false; // -f overrides -i
                    },
                    'i' => {
                        options.interactive = true;
                        options.force = false; // -i overrides -f
                    },
                    else => {
                        xio.xerrorf(prog, "mv: invalid option -- '{c}'", .{c});
                        xio.xerror("mv", "Try 'mv --help' for more information.");
                        return 1;
                    },
                }
            }
        } else {
            try files.append(arg);
        }
        i += 1;
    }

    if (files.items.len < 2) {
        xio.xerror("mv", "missing destination file operand");
        xio.xerror("mv", "Try 'mv --help' for more information.");
        return 1;
    }

    // Move files
    var has_error = false;
    const destination = files.items[files.items.len - 1];
    const sources = files.items[0 .. files.items.len - 1];

    if (sources.len > 1) {
        // Multiple sources - destination must be a directory
        const dest_stat = std.fs.cwd().statFile(destination) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    xio.xerrorf(prog, "mv: target '{s}' is not a directory", .{destination});
                    return 1;
                },
                else => {
                    xio.xerrorf(prog, "mv: cannot stat '{s}': {s}", .{ destination, @errorName(err) });
                    return 1;
                },
            }
        };

        if (dest_stat.kind != .directory) {
            xio.xerrorf(prog, "mv: target '{s}' is not a directory", .{destination});
            return 1;
        }

        for (sources) |source| {
            if (moveFile(allocator, source, destination, &options)) |_| {
                // Success
            } else |err| {
                has_error = true;
                handleMoveError(prog, source, destination, err);
            }
        }
    } else {
        // Single source
        const source = sources[0];
        if (moveFile(allocator, source, destination, &options)) |_| {
            // Success
        } else |err| {
            has_error = true;
            handleMoveError(prog, source, destination, err);
        }
    }

    return if (has_error) 1 else 0;
}

fn moveFile(allocator: std.mem.Allocator, source: []const u8, destination: []const u8, options: *const MvOptions) !void {
    const source_stat = std.fs.cwd().statFile(source) catch |err| {
        switch (err) {
            error.FileNotFound => return MvError.FileNotFound,
            error.AccessDenied => return MvError.PermissionDenied,
            else => return MvError.Unexpected,
        }
    };

    // Check if destination exists
    const dest_stat = std.fs.cwd().statFile(destination) catch null;

    if (dest_stat) |dest| {
        // Destination exists - check if we should prompt
        if (!options.force and options.interactive) {
            if (!shouldOverwrite(destination)) {
                return; // User chose not to overwrite
            }
        }

        // Check for same file (same inode) - Zig's Stat doesn't have ino/dev fields
        // For now, skip this check as it's not available in Zig's standard library
        // TODO: Implement same file detection using POSIX system calls

        // Check type compatibility
        if (dest.kind == .directory and source_stat.kind != .directory) {
            // Move file into directory
            const basename = std.fs.path.basename(source);
            const new_dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ destination, basename });
            defer allocator.free(new_dest);
            return moveFile(allocator, source, new_dest, options);
        }

        if (dest.kind != .directory and source_stat.kind == .directory) {
            return MvError.NotDirectory;
        }

        // Remove existing destination
        if (dest.kind == .directory) {
            std.fs.cwd().deleteDir(destination) catch |err| {
                switch (err) {
                    error.AccessDenied => return MvError.PermissionDenied,
                    else => return MvError.Unexpected,
                }
            };
        } else {
            std.fs.cwd().deleteFile(destination) catch |err| {
                switch (err) {
                    error.AccessDenied => return MvError.PermissionDenied,
                    else => return MvError.Unexpected,
                }
            };
        }
    }

    // Perform the move using rename()
    std.fs.cwd().rename(source, destination) catch |err| {
        switch (err) {
            error.FileNotFound => return MvError.FileNotFound,
            error.AccessDenied => return MvError.PermissionDenied,
            error.PathAlreadyExists => return MvError.PathAlreadyExists,
            error.IsDir => return MvError.IsDirectory,
            error.NotDir => return MvError.NotDirectory,
            error.RenameAcrossMountPoints => {
                // Cross-device move - copy and delete
                return moveCrossDevice(allocator, source, destination, options);
            },
            else => return MvError.Unexpected,
        }
    };
}

fn moveCrossDevice(allocator: std.mem.Allocator, source: []const u8, destination: []const u8, options: *const MvOptions) !void {
    const source_stat = std.fs.cwd().statFile(source) catch |err| {
        switch (err) {
            error.FileNotFound => return MvError.FileNotFound,
            error.AccessDenied => return MvError.PermissionDenied,
            else => return MvError.Unexpected,
        }
    };

    if (source_stat.kind == .directory) {
        // Move directory across devices
        try copyDirectoryRecursive(allocator, source, destination, options);
        std.fs.cwd().deleteDir(source) catch |err| {
            switch (err) {
                error.AccessDenied => return MvError.PermissionDenied,
                else => return MvError.Unexpected,
            }
        };
    } else {
        // Move file across devices
        try copyFile(allocator, source, destination, options);
        std.fs.cwd().deleteFile(source) catch |err| {
            switch (err) {
                error.AccessDenied => return MvError.PermissionDenied,
                else => return MvError.Unexpected,
            }
        };
    }
}

fn copyFile(_: std.mem.Allocator, source: []const u8, destination: []const u8, _: *const MvOptions) !void {
    const source_file = std.fs.cwd().openFile(source, .{}) catch |err| {
        switch (err) {
            error.AccessDenied => return MvError.PermissionDenied,
            else => return MvError.Unexpected,
        }
    };
    defer source_file.close();

    const dest_file = std.fs.cwd().createFile(destination, .{}) catch |err| {
        switch (err) {
            error.AccessDenied => return MvError.PermissionDenied,
            else => return MvError.Unexpected,
        }
    };
    defer dest_file.close();

    // Copy file contents
    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = source_file.read(buffer[0..]) catch |err| {
            switch (err) {
                error.AccessDenied => return MvError.PermissionDenied,
                else => return MvError.Unexpected,
            }
        };
        if (bytes_read == 0) break;

        dest_file.writeAll(buffer[0..bytes_read]) catch |err| {
            switch (err) {
                error.AccessDenied => return MvError.PermissionDenied,
                else => return MvError.Unexpected,
            }
        };
    }

    // Preserve file permissions
    const source_stat = try std.fs.cwd().statFile(source);
    dest_file.chmod(source_stat.mode) catch {
        // Log warning but don't fail
    };
}

fn copyDirectoryRecursive(allocator: std.mem.Allocator, source: []const u8, destination: []const u8, options: *const MvOptions) !void {
    const source_stat = try std.fs.cwd().statFile(source);

    // Create destination directory
    std.fs.cwd().makeDir(destination) catch |err| {
        switch (err) {
            error.AccessDenied => return MvError.PermissionDenied,
            else => return MvError.Unexpected,
        }
    };

    // Set directory permissions
    var dest_dir = std.fs.cwd().openDir(destination, .{}) catch |err| {
        switch (err) {
            error.AccessDenied => return MvError.PermissionDenied,
            else => return MvError.Unexpected,
        }
    };
    defer dest_dir.close();

    dest_dir.chmod(source_stat.mode) catch {
        // Log warning but don't fail
    };

    // Copy directory contents
    var source_dir = std.fs.cwd().openDir(source, .{}) catch |err| {
        switch (err) {
            error.AccessDenied => return MvError.PermissionDenied,
            else => return MvError.Unexpected,
        }
    };
    defer source_dir.close();

    var iterator = source_dir.iterate();
    while (iterator.next() catch |err| {
        switch (err) {
            error.AccessDenied => return MvError.PermissionDenied,
            else => return MvError.Unexpected,
        }
    }) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        const source_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source, entry.name });
        defer allocator.free(source_path);
        const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ destination, entry.name });
        defer allocator.free(dest_path);

        if (entry.kind == .directory) {
            try copyDirectoryRecursive(allocator, source_path, dest_path, options);
        } else {
            try copyFile(allocator, source_path, dest_path, options);
        }
    }
}

fn shouldOverwrite(destination: []const u8) bool {
    const prompt = std.fmt.allocPrint(std.heap.page_allocator, "mv: overwrite '{s}'? ", .{destination}) catch return false;
    defer std.heap.page_allocator.free(prompt);
    xio.xwrite(posix.STDERR_FILENO, prompt) catch {};

    var buffer: [256]u8 = undefined;
    const stdin = std.io.getStdIn().reader();
    const input = stdin.readUntilDelimiterOrEof(buffer[0..], '\n') catch return false;

    if (input) |line| {
        return std.mem.eql(u8, line, "y") or std.mem.eql(u8, line, "Y") or std.mem.eql(u8, line, "yes");
    }

    return false;
}

fn handleMoveError(prog: []const u8, source: []const u8, destination: []const u8, err: MvError) void {
    switch (err) {
        MvError.FileNotFound => {
            xio.xerrorf(prog, "mv: cannot stat '{s}': No such file or directory", .{source});
        },
        MvError.PermissionDenied, MvError.AccessDenied => {
            xio.xerrorf(prog, "mv: cannot move '{s}' to '{s}': Permission denied", .{ source, destination });
        },
        MvError.PathAlreadyExists => {
            xio.xerrorf(prog, "mv: cannot move '{s}' to '{s}': File exists", .{ source, destination });
        },
        MvError.IsDirectory, MvError.IsDir => {
            xio.xerrorf(prog, "mv: cannot overwrite directory '{s}' with non-directory", .{destination});
        },
        MvError.NotDirectory, MvError.NotDir => {
            xio.xerrorf(prog, "mv: cannot overwrite non-directory '{s}' with directory", .{destination});
        },
        MvError.CrossDeviceLink => {
            xio.xerrorf(prog, "mv: cannot move '{s}' to '{s}': Invalid cross-device link", .{ source, destination });
        },
        MvError.NoSpaceLeft => {
            xio.xerrorf(prog, "mv: cannot move '{s}' to '{s}': No space left on device", .{ source, destination });
        },
        MvError.SystemResources => {
            xio.xerrorf(prog, "mv: cannot move '{s}' to '{s}': System resources exhausted", .{ source, destination });
        },
        MvError.FileBusy => {
            xio.xerrorf(prog, "mv: cannot move '{s}' to '{s}': File is busy", .{ source, destination });
        },
        else => {
            xio.xerrorf(prog, "mv: cannot move '{s}' to '{s}': Unexpected error", .{ source, destination });
        },
    }
}

fn printUsage() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "Usage: mv [-if] source_file target_file\n");
    try xio.xwrite(posix.STDOUT_FILENO, "       mv [-if] source_file... target_dir\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Move files and directories.\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -f    do not prompt for confirmation if the destination path exists\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -i    prompt for confirmation if the destination path exists\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --help     display this help and exit\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --version  output version information and exit\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Examples:\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  mv file1 file2              rename file1 to file2\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  mv file1 file2 dir/         move file1 and file2 to dir/\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  mv -i file1 file2           prompt before overwriting file2\n");
}

fn printVersion() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "mv (zig-coreutils) 1.0.0\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Copyright (C) 2025 Dongjun \"Aurorasphere\" Kim\n");
    try xio.xwrite(posix.STDOUT_FILENO, "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "This is free software: you are free to change and redistribute it.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "There is NO WARRANTY, to the extent permitted by law.\n");
}
