// ls — list directory contents
// Copyright (C) 2025 Dongjun "Aurorasphere" Kim
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.

// TODO:
// - Fix the terminal width detection to use ioctl()
// - Add support for more options

const std = @import("std");
const posix = std.posix;
const xio = @import("posix-xio");

const builtin = @import("builtin");

const Options = struct {
    // Uppercase
    A: bool = false, // -A
    C: bool = false, // -C
    F: bool = false, // -F
    H: bool = false, // -H
    L: bool = false, // -L
    R: bool = false, // -R
    S: bool = false, // -S

    // Lowercase
    a: bool = false, // -a
    c: bool = false, // -c
    d: bool = false, // -d
    f: bool = false, // -f
    g: bool = false, // -g
    i: bool = false, // -i
    k: bool = false, // -k
    l: bool = false, // -l
    m: bool = false, // -m
    n: bool = false, // -n
    o: bool = false, // -o
    p: bool = false, // -p
    q: bool = false, // -q
    r: bool = false, // -r
    s: bool = false, // -s
    t: bool = false, // -t
    u: bool = false, // -u
    x: bool = false, // -x
};

const ParseResult = struct {
    options: Options,
    paths: [][]const u8,
};

fn parseArgs(allocator: std.mem.Allocator) !ParseResult {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = Options{};
    var paths = std.ArrayList([]const u8).init(allocator);

    for (args[1..]) |arg| {
        if (arg.len == 0) continue;

        if (arg[0] == '-' and arg.len > 1) {
            for (arg[1..]) |flag| {
                switch (flag) {
                    'A' => options.A = true,
                    'C' => options.C = true,
                    'F' => options.F = true,
                    'H' => options.H = true,
                    'L' => options.L = true,
                    'R' => options.R = true,
                    'S' => options.S = true,
                    'a' => options.a = true,
                    'c' => options.c = true,
                    'd' => options.d = true,
                    'f' => options.f = true,
                    'g' => options.g = true,
                    'i' => options.i = true,
                    'k' => options.k = true,
                    'l' => options.l = true,
                    'm' => options.m = true,
                    'n' => options.n = true,
                    'o' => options.o = true,
                    'p' => options.p = true,
                    'q' => options.q = true,
                    'r' => options.r = true,
                    's' => options.s = true,
                    't' => options.t = true,
                    'u' => options.u = true,
                    'x' => options.x = true,
                    else => {
                        std.debug.print("ls: invalid option -- '{c}'\n", .{flag});
                        std.process.exit(1);
                    },
                }
            }
        } else {
            // This is a path argument
            const path_copy = try allocator.dupe(u8, arg);
            try paths.append(path_copy);
        }
    }

    // If no paths specified, use current directory
    if (paths.items.len == 0) {
        const current_dir = try allocator.dupe(u8, ".");
        try paths.append(current_dir);
    }

    return ParseResult{
        .options = options,
        .paths = try paths.toOwnedSlice(),
    };
}

fn getTerminalWidth() u16 {
    // Try to get terminal width from COLUMNS environment variable
    // THIS CODE USE COLUMNS ENVIRONMENT VARIABLE, WHICH IS NOT POSIX STANDARD
    // TODO: Fix this to use ioctl()
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLUMNS")) |cols_str| {
        defer std.heap.page_allocator.free(cols_str);
        if (std.fmt.parseInt(u16, cols_str, 10)) |width| {
            return width;
        } else |_| {}
    } else |_| {}

    return 80; // fallback
}

fn printInColumns(entries: [][]const u8, terminal_width: u16) void {
    if (entries.len == 0) return;

    // Find the maximum filename length
    var max_len: usize = 0;
    for (entries) |entry| {
        if (entry.len > max_len) {
            max_len = entry.len;
        }
    }

    // Calculate number of columns (add 2 for spacing between columns)
    const col_width = max_len + 2;
    const num_cols = @max(1, @min(entries.len, terminal_width / col_width));
    const rows = (entries.len + num_cols - 1) / num_cols; // Ceiling division

    // Print entries column by column
    for (0..rows) |row| {
        var col: usize = 0;
        while (col < num_cols) : (col += 1) {
            const index = col * rows + row;
            if (index >= entries.len) break;

            const entry = entries[index];
            std.debug.print("{s}", .{entry});

            // Add spacing if not the last column
            if (col + 1 < num_cols and index + rows < entries.len) {
                const spaces_needed = col_width - entry.len;
                for (0..spaces_needed) |_| {
                    std.debug.print(" ", .{});
                }
            }
        }
        std.debug.print("\n", .{});
    }
}

fn listDirectory(allocator: std.mem.Allocator, path: []const u8, options: Options) !void {
    // Try to open as directory first
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            // It's a file, just print the filename
            std.debug.print("{s}\n", .{path});
            return;
        },
        else => {
            std.debug.print("ls: cannot access '{s}': {}\n", .{ path, err });
            return;
        },
    };
    defer dir.close();

    // List of directory entries
    var entries = std.ArrayList([]const u8).init(allocator);
    defer {
        for (entries.items) |entry| {
            allocator.free(entry);
        }
        entries.deinit();
    }

    // Add . and .. entries if -a option is used
    if (options.a) {
        const dot = try allocator.dupe(u8, ".");
        try entries.append(dot);
        const dotdot = try allocator.dupe(u8, "..");
        try entries.append(dotdot);
    }

    // Iterate over directory entries
    var iterator = dir.iterate();
    while (iterator.next() catch null) |entry| {
        // Handle hidden files based on options
        if (entry.name[0] == '.') {
            // -a: show all files including . and .. (already added above)
            // -A: show all files except . and ..
            if (!options.a and !options.A) {
                continue; // Skip hidden files by default
            }
            if (options.A and (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, ".."))) {
                continue; // Skip . and .. with -A option
            }
        }

        // Copy file name
        const name_copy = try allocator.dupe(u8, entry.name);
        try entries.append(name_copy);
    }

    // Sort
    std.mem.sort([]const u8, entries.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Print
    if (options.C) {
        const terminal_width = getTerminalWidth();
        printInColumns(entries.items, terminal_width);
    } else {
        for (entries.items) |entry| {
            std.debug.print("{s}\n", .{entry});
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const parse_result = parseArgs(allocator) catch |err| {
        std.debug.print("ls: error parsing arguments: {}\n", .{err});
        return;
    };
    defer {
        for (parse_result.paths) |path| {
            allocator.free(path);
        }
        allocator.free(parse_result.paths);
    }

    // Process each path
    for (parse_result.paths, 0..) |path, i| {
        // If multiple paths, print path header (except for single path)
        if (parse_result.paths.len > 1) {
            if (i > 0) std.debug.print("\n", .{});
            std.debug.print("{s}:\n", .{path});
        }

        try listDirectory(allocator, path, parse_result.options);
    }
}
