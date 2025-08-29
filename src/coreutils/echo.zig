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
const xio = @import("posix-xio.zig");
pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    _ = std.fs.path.basename(argv[0]); // prog variable not used in this implementation
    var args = if (argv.len > 1) argv[1..] else &[_][]const u8{};

    var nflag: bool = false;

    if (args.len > 0 and std.mem.eql(u8, args[0], "-n")) {
        nflag = true;
        args = args[1..];
    }

    var first = true;
    for (args) |arg| {
        if (!first) {
            xio.xwrite(1, " ") catch {};
        }
        xio.xwrite(1, arg) catch {};
        first = false;
    }

    if (!nflag) {
        xio.xwrite(1, "\n") catch {};
    }

    return 0;
}
