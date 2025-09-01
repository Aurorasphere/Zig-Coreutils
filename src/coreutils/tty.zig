// tty - print the file name of the terminal connected to standard input
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

pub const TtyNameError = error{
    NotATerminal,
    InvalidFd,
    NotFound,
    Unexpected,
};

/// Get terminal name using /proc/self/fd/{fd} if available, otherwise fallback to defaults
/// Pure Zig implementation without C dependencies for POSIX compatibility
pub fn ttynameAlloc(ally: std.mem.Allocator, fd: i32) ![]u8 {
    if (fd < 0) return TtyNameError.InvalidFd;

    if (!posix.isatty(fd)) return TtyNameError.NotATerminal;

    // Fast path: Linux /proc filesystem
    if (std.fs.accessAbsolute("/proc/self/fd", .{})) {
        const link = try std.fmt.allocPrintZ(ally, "/proc/self/fd/{d}", .{fd});
        defer ally.free(link);

        var link_buf: [4096]u8 = undefined;
        if (std.fs.readLinkAbsolute(link, &link_buf)) |target| {
            // Remove "(deleted)" suffix if kernel added it
            const suffix = " (deleted)";
            if (std.mem.endsWith(u8, target, suffix)) {
                const trimmed = try ally.alloc(u8, target.len - suffix.len);
                for (target[0..trimmed.len], 0..) |byte, i| {
                    trimmed[i] = byte;
                }
                return trimmed;
            }
            return try ally.dupe(u8, target);
        } else |_| {
            // /proc readlink failed, fallback to defaults
        }
    } else |_| {
        // /proc not available, use defaults
    }

    // Fallback: return common terminal device paths
    if (std.fs.accessAbsolute("/dev/tty", .{})) {
        return try ally.dupe(u8, "/dev/tty");
    } else |_| {
        // /dev/tty not available
    }

    return try ally.dupe(u8, "/dev/stdin");
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const prog = std.fs.path.basename(argv[0]);

    // Process arguments
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
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--silent") or std.mem.eql(u8, arg, "--quiet")) {
                try printTtyName(allocator, true);
                return 0;
            } else {
                xio.xerrorf(prog, "tty: invalid option -- '{s}'", .{arg});
                xio.xerror(prog, "Try 'tty --help' for more information.");
                return 1;
            }
        } else {
            xio.xerrorf(prog, "tty: extra operand '{s}'", .{arg});
            xio.xerror(prog, "Try 'tty --help' for more information.");
            return 1;
        }
        i += 1;
    }

    try printTtyName(allocator, false);
    return 0;
}

fn printTtyName(allocator: std.mem.Allocator, silent: bool) !void {
    const stdin_fd = posix.STDIN_FILENO;

    if (posix.isatty(stdin_fd)) {
        const tty_name = ttynameAlloc(allocator, stdin_fd) catch |err| {
            switch (err) {
                TtyNameError.NotATerminal => {
                    if (!silent) {
                        try xio.xwrite(posix.STDOUT_FILENO, "not a tty\n");
                    }
                    std.process.exit(1);
                },
                TtyNameError.NotFound => {
                    if (!silent) {
                        try xio.xwrite(posix.STDOUT_FILENO, "unknown\n");
                    }
                    return;
                },
                TtyNameError.Unexpected => {
                    if (!silent) {
                        try xio.xwrite(posix.STDOUT_FILENO, "unknown\n");
                    }
                    return;
                },
                TtyNameError.InvalidFd => {
                    if (!silent) {
                        try xio.xwrite(posix.STDOUT_FILENO, "unknown\n");
                    }
                    return;
                },
                error.OutOfMemory => {
                    if (!silent) {
                        try xio.xwrite(posix.STDOUT_FILENO, "unknown\n");
                    }
                    return;
                },
            }
        };
        defer allocator.free(tty_name);

        if (!silent) {
            try xio.xwrite(posix.STDOUT_FILENO, tty_name);
            try xio.xwrite(posix.STDOUT_FILENO, "\n");
        }
    } else {
        if (!silent) {
            try xio.xwrite(posix.STDOUT_FILENO, "not a tty\n");
        }
        std.process.exit(1);
    }
}

fn printUsage() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "Usage: tty [OPTION]...\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Print the file name of the terminal connected to standard input.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -s, --silent, --quiet    print nothing, only return an exit status\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --help               display this help and exit\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --version            output version information and exit\n");
    try xio.xwrite(posix.STDOUT_FILENO, "\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Exit status:\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  0  if standard input is a terminal\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  1  if standard input is not a terminal\n");
}

fn printVersion() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "tty (zig-coreutils) 1.0.0\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Copyright (C) 2025 Dongjun \"Aurorasphere\" Kim\n");
    try xio.xwrite(posix.STDOUT_FILENO, "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "This is free software: you are free to change and redistribute it.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "There is NO WARRANTY, to the extent permitted by law.\n");
}
