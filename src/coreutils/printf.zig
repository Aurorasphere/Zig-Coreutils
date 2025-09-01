// printf - write formatted output
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

const PrintfError = error{
    InvalidFormat,
    MissingArgument,
    InvalidArgument,
    Overflow,
    NotCompletelyConverted,
    ExpectedNumericValue,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const prog = std.fs.path.basename(argv[0]);

    // printf requires at least one argument (the format string)
    if (argv.len < 2) {
        xio.xerror(prog, "printf: missing format string");
        xio.xerror(prog, "Try 'printf --help' for more information.");
        return 1;
    }

    const format = argv[1];
    const arguments = if (argv.len > 2) argv[2..] else &[_][]const u8{};

    // Process printf format and arguments
    if (printfFormat(allocator, format, arguments)) |_| {
        return 0;
    } else |err| {
        switch (err) {
            PrintfError.InvalidFormat => {
                xio.xerror(prog, "printf: invalid format string");
                return 1;
            },
            PrintfError.MissingArgument => {
                xio.xerror(prog, "printf: missing argument");
                return 1;
            },
            PrintfError.InvalidArgument => {
                xio.xerror(prog, "printf: invalid argument");
                return 1;
            },
            PrintfError.Overflow => {
                xio.xerror(prog, "printf: arithmetic overflow");
                return 1;
            },
            PrintfError.NotCompletelyConverted => {
                xio.xerror(prog, "printf: not completely converted");
                return 1;
            },
            PrintfError.ExpectedNumericValue => {
                xio.xerror(prog, "printf: expected numeric value");
                return 1;
            },
            else => {
                xio.xerrorf(prog, "printf: {}", .{err});
                return 1;
            },
        }
    }
}

fn printfFormat(allocator: std.mem.Allocator, format: []const u8, arguments: []const []const u8) !void {
    var arg_index: usize = 0;
    var i: usize = 0;

    while (i < format.len) {
        const c = format[i];
        if (c == '%') {
            i += 1;
            if (i >= format.len) {
                return PrintfError.InvalidFormat;
            }

            // Handle %% (literal %)
            if (format[i] == '%') {
                try xio.xwrite(posix.STDOUT_FILENO, "%");
                i += 1;
                continue;
            }

            // Parse conversion specification
            const result = try parseConversionSpec(allocator, format[i..], arguments, &arg_index);
            i += result.consumed;
            try xio.xwrite(posix.STDOUT_FILENO, result.output);
            allocator.free(result.output);
        } else if (c == '\\') {
            // Handle escape sequences in format string
            i += 1;
            if (i >= format.len) {
                try xio.xwrite(posix.STDOUT_FILENO, "\\");
                break;
            }

            switch (format[i]) {
                '\\' => try xio.xwrite(posix.STDOUT_FILENO, "\\"),
                'a' => try xio.xwrite(posix.STDOUT_FILENO, &[_]u8{7}), // BEL
                'b' => try xio.xwrite(posix.STDOUT_FILENO, &[_]u8{8}), // BS
                'f' => try xio.xwrite(posix.STDOUT_FILENO, &[_]u8{12}), // FF
                'n' => try xio.xwrite(posix.STDOUT_FILENO, "\n"),
                'r' => try xio.xwrite(posix.STDOUT_FILENO, "\r"),
                't' => try xio.xwrite(posix.STDOUT_FILENO, "\t"),
                'v' => try xio.xwrite(posix.STDOUT_FILENO, &[_]u8{11}), // VT
                '0'...'7' => {
                    // Octal escape
                    var oct: u8 = 0;
                    var digits: u8 = 0;
                    while (i < format.len and digits < 3 and format[i] >= '0' and format[i] <= '7') {
                        oct = oct * 8 + (format[i] - '0');
                        i += 1;
                        digits += 1;
                    }
                    try xio.xwrite(posix.STDOUT_FILENO, &[_]u8{oct});
                    continue;
                },
                else => try xio.xwrite(posix.STDOUT_FILENO, &[_]u8{format[i]}),
            }
            i += 1;
        } else {
            // Regular character
            try xio.xwrite(posix.STDOUT_FILENO, &[_]u8{c});
            i += 1;
        }
    }
}

const ConversionResult = struct {
    output: []const u8,
    consumed: usize,
};

fn parseConversionSpec(allocator: std.mem.Allocator, format: []const u8, arguments: []const []const u8, arg_index: *usize) !ConversionResult {
    var i: usize = 0;
    var width: ?usize = null;
    var precision: ?usize = null;
    var flags: u32 = 0;
    var arg_num: ?usize = null;

    // Parse numbered argument (%n$)
    if (i < format.len and format[i] >= '1' and format[i] <= '9') {
        var num: usize = 0;
        while (i < format.len and format[i] >= '0' and format[i] <= '9') {
            num = num * 10 + (format[i] - '0');
            i += 1;
        }
        if (i < format.len and format[i] == '$') {
            arg_num = num - 1; // Convert to 0-based index
            i += 1;
        } else {
            // Not a numbered argument, reset
            i = 0;
        }
    }

    // Parse flags
    while (i < format.len) {
        switch (format[i]) {
            '-' => flags |= 0x01, // Left justify
            '+' => flags |= 0x02, // Always show sign
            ' ' => flags |= 0x04, // Space for positive
            '0' => flags |= 0x08, // Zero pad
            '#' => flags |= 0x10, // Alternative form
            else => break,
        }
        i += 1;
    }

    // Parse width
    if (i < format.len and format[i] >= '1' and format[i] <= '9') {
        var w: usize = 0;
        while (i < format.len and format[i] >= '0' and format[i] <= '9') {
            w = w * 10 + (format[i] - '0');
            i += 1;
        }
        width = w;
    }

    // Parse precision
    if (i < format.len and format[i] == '.') {
        i += 1;
        if (i < format.len and format[i] >= '0' and format[i] <= '9') {
            var p: usize = 0;
            while (i < format.len and format[i] >= '0' and format[i] <= '9') {
                p = p * 10 + (format[i] - '0');
                i += 1;
            }
            precision = p;
        } else {
            precision = 0;
        }
    }

    // Parse conversion specifier
    if (i >= format.len) {
        return PrintfError.InvalidFormat;
    }

    const specifier = format[i];
    i += 1;

    // Get argument
    const current_arg_index = if (arg_num) |num| num else arg_index.*;
    if (current_arg_index >= arguments.len) {
        return PrintfError.MissingArgument;
    }

    const arg = arguments[current_arg_index];
    if (arg_num == null) {
        arg_index.* += 1;
    }

    // Process conversion
    const output = try processConversion(allocator, specifier, arg, width, precision, flags);
    return ConversionResult{ .output = output, .consumed = i };
}

fn processConversion(allocator: std.mem.Allocator, specifier: u8, arg: []const u8, width: ?usize, precision: ?usize, flags: u32) ![]const u8 {
    switch (specifier) {
        'd', 'i' => return formatInteger(allocator, arg, 10, width, precision, flags, false),
        'u' => return formatInteger(allocator, arg, 10, width, precision, flags, true),
        'o' => return formatInteger(allocator, arg, 8, width, precision, flags, true),
        'x' => return formatInteger(allocator, arg, 16, width, precision, flags, true),
        'X' => return formatInteger(allocator, arg, 16, width, precision, flags, true),
        'c' => return formatCharacter(allocator, arg, width, flags),
        's' => return formatString(allocator, arg, width, precision, flags),
        'b' => return formatBackslash(allocator, arg, width, precision, flags),
        else => return PrintfError.InvalidFormat,
    }
}

fn formatInteger(allocator: std.mem.Allocator, arg: []const u8, base: u8, width: ?usize, precision: ?usize, flags: u32, unsigned: bool) ![]const u8 {
    // Parse argument as integer
    const value = try parseInteger(arg, base, unsigned);

    // Format the number
    var buf: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "{d}", .{value});

    // Apply width and precision
    return applyFormatting(allocator, formatted, width, precision, flags);
}

fn formatCharacter(allocator: std.mem.Allocator, arg: []const u8, width: ?usize, flags: u32) ![]const u8 {
    const char = if (arg.len > 0) arg[0] else 0;
    var buf: [4]u8 = undefined;
    buf[0] = char;
    const formatted = buf[0..1];

    return applyFormatting(allocator, formatted, width, null, flags);
}

fn formatString(allocator: std.mem.Allocator, arg: []const u8, width: ?usize, precision: ?usize, flags: u32) ![]const u8 {
    const str = if (precision) |p|
        if (p < arg.len) arg[0..p] else arg
    else
        arg;

    return applyFormatting(allocator, str, width, null, flags);
}

fn formatBackslash(allocator: std.mem.Allocator, arg: []const u8, width: ?usize, precision: ?usize, flags: u32) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    const max_len = if (precision) |p| p else arg.len;

    while (i < arg.len and i < max_len) {
        if (arg[i] == '\\') {
            i += 1;
            if (i >= arg.len) break;

            switch (arg[i]) {
                '\\' => try result.append('\\'),
                'a' => try result.append(7), // BEL
                'b' => try result.append(8), // BS
                'f' => try result.append(12), // FF
                'n' => try result.append('\n'),
                'r' => try result.append('\r'),
                't' => try result.append('\t'),
                'v' => try result.append(11), // VT
                '0'...'7' => {
                    // Octal escape
                    var oct: u8 = 0;
                    var digits: u8 = 0;
                    while (i < arg.len and digits < 3 and arg[i] >= '0' and arg[i] <= '7') {
                        oct = oct * 8 + (arg[i] - '0');
                        i += 1;
                        digits += 1;
                    }
                    try result.append(oct);
                    continue;
                },
                'c' => {
                    // Stop processing
                    return result.toOwnedSlice();
                },
                else => try result.append(arg[i]),
            }
        } else {
            try result.append(arg[i]);
        }
        i += 1;
    }

    const formatted = try result.toOwnedSlice();
    defer allocator.free(formatted);
    return applyFormatting(allocator, formatted, width, null, flags);
}

fn parseInteger(arg: []const u8, base: u8, unsigned: bool) !i64 {
    // Handle special cases for integer parsing
    if (arg.len == 0) return 0;

    // Handle quoted characters
    if (arg.len >= 3 and (arg[0] == '\'' or arg[0] == '"')) {
        if (arg[arg.len - 1] == arg[0]) {
            return @as(i64, arg[1]);
        }
    }

    // Parse as integer
    if (unsigned) {
        const value = std.fmt.parseInt(u64, arg, base) catch |err| {
            switch (err) {
                error.Overflow => return PrintfError.Overflow,
                error.InvalidCharacter => return PrintfError.ExpectedNumericValue,
            }
        };
        return @as(i64, @intCast(value));
    } else {
        const value = std.fmt.parseInt(i64, arg, base) catch |err| {
            switch (err) {
                error.Overflow => return PrintfError.Overflow,
                error.InvalidCharacter => return PrintfError.ExpectedNumericValue,
            }
        };
        return value;
    }
}

fn applyFormatting(allocator: std.mem.Allocator, input: []const u8, width: ?usize, precision: ?usize, flags: u32) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    // Apply precision if specified
    const processed_input = if (precision) |p|
        if (p < input.len) input[0..p] else input
    else
        input;

    const w = width orelse 0;
    const input_len = processed_input.len;

    if (w > input_len) {
        const padding = w - input_len;
        if ((flags & 0x01) != 0) {
            // Left justify
            try result.appendSlice(processed_input);
            try result.appendNTimes(' ', padding);
        } else {
            // Right justify
            const pad_char: u8 = if ((flags & 0x08) != 0) '0' else ' ';
            try result.appendNTimes(pad_char, padding);
            try result.appendSlice(processed_input);
        }
    } else {
        try result.appendSlice(processed_input);
    }

    return result.toOwnedSlice();
}
