// chmod - change the file modes
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

const ChmodOptions = struct {
    recursive: bool = false, // -R: recursively change file mode bits
};

const ChmodError = error{
    InvalidMode,
    PermissionDenied,
    FileNotFound,
    Unexpected,
};

const ModeType = enum {
    octal,
    symbolic,
};

const ParsedMode = union(ModeType) {
    octal: u32,
    symbolic: SymbolicMode,
};

const SymbolicMode = struct {
    who: Who = .a,
    op: Op,
    perm: PermList = .{},
};

const Who = enum {
    u, // user
    g, // group
    o, // other
    a, // all (ugo)
};

const Op = enum {
    plus, // +
    minus, // -
    equal, // =
};

const PermList = struct {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    setuid: bool = false,
    setgid: bool = false,
    sticky: bool = false,
    capital_x: bool = false, // X - execute if directory or any execute bit set
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const prog = std.fs.path.basename(argv[0]);

    // Parse options and arguments
    var options = ChmodOptions{};
    var mode_str: []const u8 = undefined;
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
            } else if (std.mem.eql(u8, arg, "-R")) {
                options.recursive = true;
            } else {
                xio.xerrorf(prog, "chmod: invalid option -- '{s}'", .{arg});
                xio.xerror(prog, "Try 'chmod --help' for more information.");
                return 1;
            }
        } else {
            if (i == 1 or (i == 2 and options.recursive)) {
                // First non-option argument is the mode
                mode_str = arg;
            } else {
                // All other arguments are files
                try files.append(arg);
            }
        }
        i += 1;
    }

    if (files.items.len == 0) {
        xio.xerrorf(prog, "chmod: missing operand after '{s}'", .{mode_str});
        xio.xerror(prog, "Try 'chmod --help' for more information.");
        return 1;
    }

    // Parse mode
    const parsed_mode = parseMode(mode_str) catch |err| {
        switch (err) {
            ChmodError.InvalidMode => {
                xio.xerrorf(prog, "chmod: invalid mode: '{s}'", .{mode_str});
                return 1;
            },
            else => return 1,
        }
    };

    // Apply mode to files
    var has_error = false;
    for (files.items) |file| {
        if (applyMode(allocator, file, parsed_mode, &options)) |_| {
            // Success
        } else |err| {
            has_error = true;
            handleChmodError(prog, file, err);
        }
    }

    return if (has_error) 1 else 0;
}

fn parseMode(mode_str: []const u8) !ParsedMode {
    // Check if it's an octal mode
    var is_octal = true;
    for (mode_str) |c| {
        if (!std.ascii.isDigit(c)) {
            is_octal = false;
            break;
        }
    }
    if (is_octal) {
        const mode = try std.fmt.parseInt(u32, mode_str, 8);
        return ParsedMode{ .octal = mode };
    }

    // Parse symbolic mode
    const symbolic_mode = try parseSymbolicMode(mode_str);
    return ParsedMode{ .symbolic = symbolic_mode };
}

fn parseSymbolicMode(mode_str: []const u8) !SymbolicMode {
    var mode = SymbolicMode{ .op = .equal };
    var i: usize = 0;

    // Parse who (optional)
    if (i < mode_str.len) {
        switch (mode_str[i]) {
            'u' => {
                mode.who = .u;
                i += 1;
            },
            'g' => {
                mode.who = .g;
                i += 1;
            },
            'o' => {
                mode.who = .o;
                i += 1;
            },
            'a' => {
                mode.who = .a;
                i += 1;
            },
            else => {},
        }
    }

    // Parse operation
    if (i >= mode_str.len) return ChmodError.InvalidMode;
    switch (mode_str[i]) {
        '+' => {
            mode.op = .plus;
            i += 1;
        },
        '-' => {
            mode.op = .minus;
            i += 1;
        },
        '=' => {
            mode.op = .equal;
            i += 1;
        },
        else => return ChmodError.InvalidMode,
    }

    // Parse permissions
    while (i < mode_str.len) {
        switch (mode_str[i]) {
            'r' => {
                mode.perm.read = true;
                i += 1;
            },
            'w' => {
                mode.perm.write = true;
                i += 1;
            },
            'x' => {
                mode.perm.execute = true;
                i += 1;
            },
            'X' => {
                mode.perm.capital_x = true;
                i += 1;
            },
            's' => {
                mode.perm.setuid = true;
                mode.perm.setgid = true;
                i += 1;
            },
            't' => {
                mode.perm.sticky = true;
                i += 1;
            },
            else => return ChmodError.InvalidMode,
        }
    }

    return mode;
}

fn applySymbolicMode(_: []const u8, sym_mode: SymbolicMode, current_mode: u32) !u32 {
    var new_mode = current_mode;

    switch (sym_mode.op) {
        .plus => {
            // Add permissions
            if (sym_mode.who == .u or sym_mode.who == .a) {
                if (sym_mode.perm.read) new_mode |= 0o400;
                if (sym_mode.perm.write) new_mode |= 0o200;
                if (sym_mode.perm.execute) new_mode |= 0o100;
                if (sym_mode.perm.setuid) new_mode |= 0o4000;
            }
            if (sym_mode.who == .g or sym_mode.who == .a) {
                if (sym_mode.perm.read) new_mode |= 0o040;
                if (sym_mode.perm.write) new_mode |= 0o020;
                if (sym_mode.perm.execute) new_mode |= 0o010;
                if (sym_mode.perm.setgid) new_mode |= 0o2000;
            }
            if (sym_mode.who == .o or sym_mode.who == .a) {
                if (sym_mode.perm.read) new_mode |= 0o004;
                if (sym_mode.perm.write) new_mode |= 0o002;
                if (sym_mode.perm.execute) new_mode |= 0o001;
                if (sym_mode.perm.sticky) new_mode |= 0o1000;
            }
        },
        .minus => {
            // Remove permissions
            if (sym_mode.who == .u or sym_mode.who == .a) {
                if (sym_mode.perm.read) new_mode &= ~@as(u32, 0o400);
                if (sym_mode.perm.write) new_mode &= ~@as(u32, 0o200);
                if (sym_mode.perm.execute) new_mode &= ~@as(u32, 0o100);
                if (sym_mode.perm.setuid) new_mode &= ~@as(u32, 0o4000);
            }
            if (sym_mode.who == .g or sym_mode.who == .a) {
                if (sym_mode.perm.read) new_mode &= ~@as(u32, 0o040);
                if (sym_mode.perm.write) new_mode &= ~@as(u32, 0o020);
                if (sym_mode.perm.execute) new_mode &= ~@as(u32, 0o010);
                if (sym_mode.perm.setgid) new_mode &= ~@as(u32, 0o2000);
            }
            if (sym_mode.who == .o or sym_mode.who == .a) {
                if (sym_mode.perm.read) new_mode &= ~@as(u32, 0o004);
                if (sym_mode.perm.write) new_mode &= ~@as(u32, 0o002);
                if (sym_mode.perm.execute) new_mode &= ~@as(u32, 0o001);
                if (sym_mode.perm.sticky) new_mode &= ~@as(u32, 0o1000);
            }
        },
        .equal => {
            // Set permissions exactly
            if (sym_mode.who == .u or sym_mode.who == .a) {
                new_mode &= ~@as(u32, 0o700); // Clear user permissions
                if (sym_mode.perm.read) new_mode |= 0o400;
                if (sym_mode.perm.write) new_mode |= 0o200;
                if (sym_mode.perm.execute) new_mode |= 0o100;
                if (sym_mode.perm.setuid) new_mode |= 0o4000;
            }
            if (sym_mode.who == .g or sym_mode.who == .a) {
                new_mode &= ~@as(u32, 0o070); // Clear group permissions
                if (sym_mode.perm.read) new_mode |= 0o040;
                if (sym_mode.perm.write) new_mode |= 0o020;
                if (sym_mode.perm.execute) new_mode |= 0o010;
                if (sym_mode.perm.setgid) new_mode |= 0o2000;
            }
            if (sym_mode.who == .o or sym_mode.who == .a) {
                new_mode &= ~@as(u32, 0o007); // Clear other permissions
                if (sym_mode.perm.read) new_mode |= 0o004;
                if (sym_mode.perm.write) new_mode |= 0o002;
                if (sym_mode.perm.execute) new_mode |= 0o001;
                if (sym_mode.perm.sticky) new_mode |= 0o1000;
            }
        },
    }

    return new_mode;
}

fn applyMode(allocator: std.mem.Allocator, file: []const u8, parsed_mode: ParsedMode, options: *const ChmodOptions) !void {
    const stat = std.fs.cwd().statFile(file) catch |err| {
        switch (err) {
            error.FileNotFound => return ChmodError.FileNotFound,
            error.AccessDenied => return ChmodError.PermissionDenied,
            else => return ChmodError.Unexpected,
        }
    };

    const final_mode = switch (parsed_mode) {
        .octal => |mode| mode,
        .symbolic => |sym_mode| try applySymbolicMode(file, sym_mode, @as(u32, @intCast(stat.mode))),
    };

    if (stat.kind == .directory) {
        if (options.recursive) {
            try applyModeRecursive(allocator, file, final_mode, options);
        } else {
            try applyModeToDirectory(file, final_mode);
        }
    } else {
        try applyModeToFile(file, final_mode);
    }
}

fn applyModeToFile(file: []const u8, mode: u32) !void {
    const file_handle = std.fs.cwd().openFile(file, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => return ChmodError.FileNotFound,
            error.AccessDenied => return ChmodError.PermissionDenied,
            else => return ChmodError.Unexpected,
        }
    };
    defer file_handle.close();

    file_handle.chmod(mode) catch |err| {
        switch (err) {
            error.AccessDenied => return ChmodError.PermissionDenied,
            else => return ChmodError.Unexpected,
        }
    };
}

fn applyModeToDirectory(dir_path: []const u8, mode: u32) !void {
    // For now, skip directory chmod due to Zig API limitations
    // In a full implementation, we would use POSIX system calls directly
    _ = dir_path;
    _ = mode;
    // TODO: Implement directory chmod using system calls
}

fn applyModeRecursive(allocator: std.mem.Allocator, dir_path: []const u8, mode: u32, options: *const ChmodOptions) !void {
    // Apply mode to the directory itself first
    try applyModeToDirectory(dir_path, mode);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => return ChmodError.FileNotFound,
            error.AccessDenied => return ChmodError.PermissionDenied,
            else => return ChmodError.Unexpected,
        }
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        // Skip . and ..
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) {
            continue;
        }

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            try applyModeRecursive(allocator, full_path, mode, options);
        } else {
            try applyModeToFile(full_path, mode);
        }
    }
}

fn handleChmodError(prog: []const u8, file: []const u8, err: anyerror) void {
    switch (err) {
        ChmodError.InvalidMode => {
            xio.xerrorf(prog, "chmod: invalid mode: '{s}'", .{file});
        },
        ChmodError.PermissionDenied => {
            xio.xerrorf(prog, "chmod: cannot change permissions of '{s}': Permission denied", .{file});
        },
        ChmodError.FileNotFound => {
            xio.xerrorf(prog, "chmod: cannot access '{s}': No such file or directory", .{file});
        },
        else => {
            xio.xerrorf(prog, "chmod: cannot change permissions of '{s}': {}", .{ file, err });
        },
    }
}

fn printUsage() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "Usage: chmod [OPTION]... MODE[,MODE]... FILE...\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Change the file mode bits of each FILE to MODE.\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -R                    change files and directories recursively\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --help            display this help and exit\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --version         output version information and exit\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Each MODE is of the form '[ugoa]*([-+=]([rwxXst]*|[ugo]))+|[-+=][0-7]+'.\n\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Examples:\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  chmod 755 file        set permissions to rwxr-xr-x\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  chmod u+x file        add execute permission for owner\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  chmod g-w file        remove write permission for group\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  chmod a=r file        set permissions to r--r--r--\n");
}

fn printVersion() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "chmod (zig-coreutils) 1.0.0\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Copyright (C) 2025 Dongjun \"Aurorasphere\" Kim\n");
    try xio.xwrite(posix.STDOUT_FILENO, "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "This is free software: you are free to change and redistribute it.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "There is NO WARRANTY, to the extent permitted by law.\n");
}
