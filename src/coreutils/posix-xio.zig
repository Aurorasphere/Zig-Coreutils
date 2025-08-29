// I/O utilities - Safe file I/O functions for Zig coreutils
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

/// Safe write function that handles partial writes and common errors
///
/// This function ensures that all data is written to the file descriptor,
/// handling partial writes by continuing until all data is written.
///
/// Args:
///   fd: File descriptor to write to
///   buf: Buffer containing data to write
///
/// Returns:
///   void on success, error on failure
///
/// Special handling:
///   - BrokenPipe: Returns silently (common for pipes/stdout redirection)
///   - Other errors: Propagated to caller
pub fn xwrite(fd: posix.fd_t, buf: []const u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.write(fd, buf[off..]) catch |e| switch (e) {
            error.BrokenPipe => return,
            else => return e,
        };
        if (n == 0) return error.Unexpected;
        off += n;
    }
}

/// Safe read function that handles EINTR
///
/// This function performs a single read operation, handling EINTR
/// by retrying. Unlike the previous version, this follows standard
/// POSIX behavior by not trying to fill the entire buffer.
///
/// Args:
///   fd: File descriptor to read from
///   buf: Buffer to store read data
///
/// Returns:
///   Number of bytes actually read (0 indicates EOF)
///
/// Special handling:
///   - Handles EINTR by retrying the read operation
///   - Returns after first successful read (standard POSIX behavior)
pub fn xread(fd: posix.fd_t, buf: []u8) !usize {
    while (true) {
        const n = posix.read(fd, buf) catch |e| switch (e) {
            error.Interrupted => continue, // EINTR - retry
            else => return e,
        };
        return n;
    }
}

/// Read exactly the requested number of bytes
///
/// This function continues reading until the buffer is completely filled
/// or EOF is reached. Use this when you need to read a specific amount.
///
/// Args:
///   fd: File descriptor to read from
///   buf: Buffer to store read data
///
/// Returns:
///   Number of bytes actually read (may be less than buffer size if EOF)
pub fn xreadfull(fd: posix.fd_t, buf: []u8) !usize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try xread(fd, buf[off..]);
        if (n == 0) break; // EOF reached
        off += n;
    }
    return off;
}

/// Safe open function with EINTR handling
///
/// This function opens a file with the specified flags and mode,
/// handling EINTR by retrying the operation. This follows the
/// same pattern as xread and xwrite.
///
/// Args:
///   path: Path to the file to open
///   flags: Open flags (O_RDONLY, O_WRONLY, O_RDWR, etc.)
///   mode: File permissions (used when creating files)
///
/// Returns:
///   File descriptor on success, error on failure
///
/// Special handling:
///   - Handles EINTR by retrying the open operation
///   - Consistent with other x-prefixed functions
pub fn xopen(path: []const u8, flags: u32, mode: posix.mode_t) !posix.fd_t {
    while (true) {
        const fd = posix.open(path, flags, mode) catch |e| switch (e) {
            error.Interrupted => continue, // EINTR - retry
            else => return e,
        };
        return fd;
    }
}

/// Print error message to stderr with program name prefix
///
/// This function provides consistent error reporting across all utilities,
/// following POSIX conventions for error messages.
///
/// Args:
///   prog: Program name (typically from argv[0])
///   message: Error message to display
///
/// Returns:
///   void
///
/// Special handling:
///   - Always writes to stderr (fd=2)
///   - Follows format: "program: message\n"
///   - Handles write errors silently (as per POSIX convention)
pub fn xerror(prog: []const u8, message: []const u8) void {
    xwrite(posix.STDERR_FILENO, prog) catch return;
    xwrite(posix.STDERR_FILENO, ": ") catch return;
    xwrite(posix.STDERR_FILENO, message) catch return;
    xwrite(posix.STDERR_FILENO, "\n") catch return;
}

/// Print formatted error message to stderr
///
/// Similar to xerror but allows formatted messages.
///
/// Args:
///   prog: Program name
///   comptime fmt: Format string
///   args: Format arguments
pub fn xerrorf(prog: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(buf[0..], fmt, args) catch "format error";
    xerror(prog, message);
}
