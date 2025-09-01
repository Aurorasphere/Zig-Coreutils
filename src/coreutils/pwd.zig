// Print the current working directory
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

    // pwd doesn't typically take arguments, but we'll handle -L and -P flags for compatibility
    var logical = true; // default to logical path (like most pwd implementations)

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-L")) {
            logical = true;
        } else if (std.mem.eql(u8, arg, "-P")) {
            logical = false;
        } else if (std.mem.eql(u8, arg, "--help")) {
            xio.xwrite(1, "Usage: pwd [-L|-P]\n") catch {};
            xio.xwrite(1, "Print the current working directory.\n") catch {};
            xio.xwrite(1, "  -L  use PWD from environment (default)\n") catch {};
            xio.xwrite(1, "  -P  use physical directory structure\n") catch {};
            xio.xwrite(1, "      --version              output version information and exit\n") catch {};
            return 0;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try printVersion();
            return 0;
        } else {
            xio.xwrite(2, "pwd: invalid option -- ") catch {};
            xio.xwrite(2, arg) catch {};
            xio.xwrite(2, "\n") catch {};
            return 1;
        }
    }

    if (logical) {
        // Try to use PWD environment variable first
        if (std.process.getEnvVarOwned(allocator, "PWD")) |pwd_env| {
            defer allocator.free(pwd_env);
            xio.xwrite(1, pwd_env) catch {};
            xio.xwrite(1, "\n") catch {};
            return 0;
        } else |_| {
            // Fall back to physical path if PWD is not available
        }
    }

    // Get physical current working directory
    const cwd = std.process.getCwdAlloc(allocator) catch |e| {
        xio.xwrite(2, "pwd: cannot get current directory: ") catch {};
        switch (e) {
            error.OutOfMemory => xio.xwrite(2, "out of memory\n") catch {},
            error.CurrentWorkingDirectoryUnlinked => xio.xwrite(2, "directory unlinked\n") catch {},
            else => xio.xwrite(2, "unknown error\n") catch {},
        }
        return 1;
    };
    defer allocator.free(cwd);

    xio.xwrite(1, cwd) catch {};
    xio.xwrite(1, "\n") catch {};

    return 0;
}

fn printVersion() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "pwd (zig-coreutils) 1.0.0\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Copyright (C) 2025 Dongjun \"Aurorasphere\" Kim\n");
    try xio.xwrite(posix.STDOUT_FILENO, "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "This is free software: you are free to change and redistribute it.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "There is NO WARRANTY, to the extent permitted by law.\n");
}
