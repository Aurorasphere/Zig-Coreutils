// posix-xio.zig - Safe file I/O utilities for Zig coreutils
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

const std = @import("std");
const posix = std.posix;

/// Write policy: controls how xwrite behaves
pub const WritePolicy = struct {
    silent_broken_pipe: bool = true,
    nonblocking: bool = false, // POSIX O_NONBLOCK behavior
    prog: []const u8 = "prog", // Error message prefix
};

/// Read policy (POSIX compliant)
pub const ReadPolicy = struct {
    nonblocking: bool = false, // POSIX O_NONBLOCK behavior
    prog: []const u8 = "prog",
};

/// Open policy (POSIX compliant)
pub const OpenPolicy = struct {
    prog: []const u8 = "prog",
    cloexec: bool = true, // POSIX FD_CLOEXEC
    nofollow: bool = false, // POSIX O_NOFOLLOW
    directory: bool = false, // POSIX O_DIRECTORY
    nonblocking: bool = false, // POSIX O_NONBLOCK
};

/// Ignore SIGPIPE globally, so EPIPE surfaces as error.BrokenPipe
pub fn init_io_policy() void {
    posix.sigaction(posix.SIG.PIPE, &posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.empty_sigset,
        .flags = 0,
    }, null);
}

/// Print "prog: message\n" to stderr using xwrite policy
pub fn xerror(prog: []const u8, message: []const u8) void {
    const pol: WritePolicy = .{ .prog = prog };
    _ = xwrite(posix.STDERR_FILENO, prog, pol) catch return;
    _ = xwrite(posix.STDERR_FILENO, ": ", pol) catch return;
    _ = xwrite(posix.STDERR_FILENO, message, pol) catch return;
    _ = xwrite(posix.STDERR_FILENO, "\n", pol) catch return;
}

/// Print formatted error message
pub fn xerrorf(prog: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(buf[0..], fmt, args) catch "format error";
    xerror(prog, msg);
}

/// ----- internal: error reporters -----
fn report_ops_issue(pol: WritePolicy, e: anyerror) void {
    const m = switch (e) {
        error.NoSpaceLeft => "No space left on device",
        error.DiskQuota => "Disk quota exceeded",
        error.FileTooBig => "File too large",
        error.DeviceBusy => "Device or resource busy",
        error.NoDevice => "No such device",
        error.InputOutput => "I/O error",
        error.SystemResources => "Out of system resources",
        error.LockViolation => "Lock violation",
        error.OperationAborted => "Operation aborted",
        else => @errorName(e),
    };
    xerror(pol.prog, m);
}

fn report_read_issue(pol: ReadPolicy, e: anyerror) void {
    const m = switch (e) {
        error.SystemResources => "Out of system resources",
        error.InputOutput => "I/O error",
        error.OperationAborted => "Operation aborted",
        error.Canceled => "Operation canceled",
        error.ConnectionTimedOut => "Connection timed out",
        error.LockViolation => "Locked by another process",
        else => @errorName(e),
    };
    xerror(pol.prog, m);
}

fn report_open_issue(pol: OpenPolicy, e: anyerror) void {
    const m = switch (e) {
        error.FileNotFound => "No such file or directory", // ENOENT
        error.NotDir => "Not a directory", // ENOTDIR
        error.IsDir => "Is a directory", // EISDIR
        error.SymLinkLoop => "Too many levels of symbolic links", // ELOOP
        error.NameTooLong => "File name too long", // ENAMETOOLONG
        error.NoSpaceLeft => "No space left on device", // ENOSPC
        error.AccessDenied => "Permission denied", // EACCES/EPERM
        error.FileBusy, error.DeviceBusy => "Device or resource busy", // EBUSY
        error.ProcessFdQuotaExceeded => "Too many open files", // EMFILE
        error.SystemFdQuotaExceeded => "File table overflow", // ENFILE
        error.SystemResources => "Cannot allocate memory", // ENOMEM
        else => @errorName(e),
    };
    xerror(pol.prog, m);
}

/// ----- write -----
pub fn xwrite(fd: posix.fd_t, buf: []const u8, pol: WritePolicy) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = posix.write(fd, buf[off..]) catch |e| switch (e) {
            // Flow control
            error.WouldBlock => return e,
            error.BrokenPipe => if (pol.silent_broken_pipe) return else return e,

            // Operational issues: report & return
            error.NoSpaceLeft, error.DiskQuota, error.FileTooBig, error.DeviceBusy, error.NoDevice, error.InputOutput, error.SystemResources, error.LockViolation, error.OperationAborted => {
                report_ops_issue(pol, e);
                return e;
            },

            // Permission / FD / arg errors
            error.AccessDenied, error.NotOpenForWriting => return e,

            // Other network/process cases
            error.ConnectionResetByPeer, error.ProcessNotFound => return e,

            // Unclassified
            error.Unexpected => {
                xerrorf(pol.prog, "{s}", .{@errorName(e)});
                return e;
            },
            else => return e,
        };

        if (n == 0) return error.Unexpected; // unexpected 0-byte write
        off += n;
    }
}

/// ----- read -----
pub fn xread(fd: posix.fd_t, buf: []u8, pol: ReadPolicy) !usize {
    while (true) {
        const n = posix.read(fd, buf) catch |e| switch (e) {
            // Flow control
            error.WouldBlock => return e,

            // Operational issues: report & return
            error.SystemResources, error.InputOutput, error.OperationAborted, error.Canceled, error.ConnectionTimedOut => {
                report_read_issue(pol, e);
                return e;
            },

            // Permission / FD / arg / type errors
            error.AccessDenied, error.NotOpenForReading, error.IsDir, error.SocketNotConnected => return e,

            // Peer/process termination
            error.ConnectionResetByPeer, error.ProcessNotFound => return e,

            // Unclassified
            error.Unexpected => {
                xerrorf(pol.prog, "{s}", .{@errorName(e)});
                return e;
            },
            else => return e,
        };
        return n; // 0 => EOF
    }
}

pub fn xreadfull(fd: posix.fd_t, buf: []u8, pol: ReadPolicy) !usize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try xread(fd, buf[off..], pol);
        if (n == 0) break; // EOF
        off += n;
    }
    return off;
}

pub fn xread_exact(fd: posix.fd_t, buf: []u8, pol: ReadPolicy) !void {
    if (try xreadfull(fd, buf, pol) != buf.len) return error.UnexpectedEOF;
}

/// ----- open -----
inline fn compose_flags(base: u32, pol: OpenPolicy) u32 {
    var f = base;
    if (pol.cloexec) f |= posix.O.CLOEXEC;
    if (pol.directory) f |= posix.O.DIRECTORY;
    if (pol.nonblocking) f |= posix.O.NONBLOCK;
    if (pol.nofollow and @hasDecl(posix.O, "NOFOLLOW")) f |= posix.O.NOFOLLOW;
    return f;
}

pub fn xopen(path: []const u8, base_flags: u32, mode: posix.mode_t, pol: OpenPolicy) !posix.fd_t {
    const flags = compose_flags(base_flags, pol);
    while (true) {
        const fd = posix.open(path, flags, mode) catch |e| switch (e) {
            // Existence / Type / Permission / Resources
            error.FileNotFound, error.NotDir, error.IsDir, error.SymLinkLoop, error.NameTooLong, error.NoSpaceLeft, error.SystemFdQuotaExceeded, error.ProcessFdQuotaExceeded, error.SystemResources, error.FileBusy, error.DeviceBusy, error.AccessDenied, error.InvalidUtf8, error.InvalidWtf8, error.NetworkNotFound => {
                report_open_issue(pol, e);
                return e;
            },

            // Creation race and others: propagate
            error.PathAlreadyExists => return e,
            error.ProcessNotFound, error.WouldBlock => return e,

            // Unclassified
            error.Unexpected => {
                xerrorf(pol.prog, "{s}", .{@errorName(e)});
                return e;
            },
            else => return e,
        };
        return fd;
    }
}
