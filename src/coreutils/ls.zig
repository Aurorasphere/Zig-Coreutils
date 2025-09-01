// ls - list directory contents
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

const LsOptions = struct {
    // Basic display options
    long_format: bool = false,
    all_files: bool = false,
    almost_all: bool = false,
    one_per_line: bool = false,
    multi_column: bool = false,
    stream_format: bool = false,
    cross_format: bool = false,

    // File type indicators
    show_indicators: bool = false,
    show_slash: bool = false,

    // Symbolic link handling
    follow_links: bool = false,
    follow_links_cmdline: bool = false,

    // Sorting options
    sort_by_time: bool = false,
    sort_by_size: bool = false,
    sort_by_access_time: bool = false,
    sort_by_status_time: bool = false,
    sort_none: bool = false,
    reverse: bool = false,

    // Recursive listing
    recursive: bool = false,

    // Directory handling
    list_directories: bool = false,

    // File information display
    show_inode: bool = false,
    show_blocks: bool = false,
    show_owner: bool = true,
    show_group: bool = true,
    numeric_ids: bool = false,

    // Time display
    show_access_time: bool = false,
    show_status_time: bool = false,

    // Output formatting
    show_quotes: bool = false,
    show_nonprintable: bool = false,
    block_size: ?usize = null,
    show_width: ?usize = null,

    // Special modes
    force_order: bool = false,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const prog = std.fs.path.basename(argv[0]);

    var options = LsOptions{};
    var paths = std.ArrayList([]const u8).init(allocator);
    defer paths.deinit();

    // Process arguments
    var i: usize = 1;
    while (i < argv.len) {
        const arg = argv[i];
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) {
                // End of options - add remaining args as paths
                i += 1;
                while (i < argv.len) {
                    try paths.append(argv[i]);
                    i += 1;
                }
                break;
            } else if (std.mem.eql(u8, arg, "--help")) {
                try printUsage();
                return 0;
            } else if (std.mem.eql(u8, arg, "--version")) {
                try printVersion();
                return 0;
            } else {
                // Process short options
                var j: usize = 1;
                while (j < arg.len) {
                    const opt = arg[j];
                    switch (opt) {
                        // Basic display options
                        'a' => options.all_files = true,
                        'A' => options.almost_all = true,
                        'l' => options.long_format = true,
                        '1' => options.one_per_line = true,
                        'C' => options.multi_column = true,
                        'm' => options.stream_format = true,
                        'x' => options.cross_format = true,

                        // File type indicators
                        'F' => options.show_indicators = true,
                        'p' => options.show_slash = true,

                        // Symbolic link handling
                        'H' => options.follow_links_cmdline = true,
                        'L' => options.follow_links = true,

                        // Sorting options
                        't' => options.sort_by_time = true,
                        'S' => options.sort_by_size = true,
                        'u' => options.sort_by_access_time = true,
                        'c' => options.sort_by_status_time = true,
                        'U' => options.sort_none = true,
                        'r' => options.reverse = true,

                        // Recursive listing
                        'R' => options.recursive = true,

                        // Directory handling
                        'd' => options.list_directories = true,

                        // File information display
                        'i' => options.show_inode = true,
                        's' => options.show_blocks = true,
                        'g' => {
                            options.long_format = true;
                            options.show_owner = false;
                        },
                        'n' => {
                            options.long_format = true;
                            options.numeric_ids = true;
                        },
                        'o' => {
                            options.long_format = true;
                            options.show_group = false;
                        },

                        // Output formatting
                        'Q' => options.show_quotes = true,
                        'q' => options.show_nonprintable = true,
                        'k' => options.block_size = 1024,

                        // Special modes
                        'f' => {
                            options.force_order = true;
                            options.all_files = true;
                        },
                        'w' => {
                            // Handle width option
                            if (j + 1 < arg.len) {
                                const width_str = arg[j + 1 ..];
                                options.show_width = std.fmt.parseInt(usize, width_str, 10) catch null;
                                j = arg.len - 1; // Skip to end
                            } else if (i + 1 < argv.len) {
                                options.show_width = std.fmt.parseInt(usize, argv[i + 1], 10) catch null;
                                i += 1; // Skip next argument
                                j = arg.len - 1; // Skip to end
                            }
                        },
                        else => {
                            xio.xerrorf(prog, "ls: invalid option -- '{c}'", .{opt});
                            xio.xerror(prog, "Try 'ls --help' for more information.");
                            return 1;
                        },
                    }
                    j += 1;
                }
            }
        } else {
            // Non-flag argument - add to paths
            try paths.append(arg);
        }
        i += 1;
    }

    // If no paths provided, use current directory
    const target_paths = if (paths.items.len == 0) &[_][]const u8{"."} else paths.items;

    var exit_code: u8 = 0;
    for (target_paths) |path| {
        if (listDirectory(allocator, path, options)) |_| {
            // Success
        } else |err| {
            exit_code = 1;
            switch (err) {
                error.FileNotFound => xio.xerrorf(prog, "ls: cannot access '{s}': No such file or directory", .{path}),
                error.AccessDenied => xio.xerrorf(prog, "ls: cannot open directory '{s}': Permission denied", .{path}),
                error.NotDir => xio.xerrorf(prog, "ls: '{s}': Not a directory", .{path}),
                else => xio.xerrorf(prog, "ls: '{s}': {}", .{ path, err }),
            }
        }
    }

    return exit_code;
}

fn listDirectory(allocator: std.mem.Allocator, path: []const u8, options: LsOptions) !void {
    var entries = std.ArrayList(DirEntry).init(allocator);
    defer entries.deinit();

    // Check if path is a file or directory
    const stat = try std.fs.cwd().statFile(path);

    if ((stat.mode & posix.S.IFMT) == posix.S.IFDIR) {
        // It's a directory
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();

        // Add . and .. entries if -a is specified
        if (options.all_files) {
            // Add . entry
            const dot_path = try std.fs.path.join(allocator, &[_][]const u8{ path, "." });
            defer allocator.free(dot_path);
            const dot_stat = try std.fs.cwd().statFile(dot_path);
            try entries.append(DirEntry{
                .name = try allocator.dupe(u8, "."),
                .stat = dot_stat,
                .path = try allocator.dupe(u8, dot_path),
            });

            // Add .. entry
            const dotdot_path = try std.fs.path.join(allocator, &[_][]const u8{ path, ".." });
            defer allocator.free(dotdot_path);
            const dotdot_stat = try std.fs.cwd().statFile(dotdot_path);
            try entries.append(DirEntry{
                .name = try allocator.dupe(u8, ".."),
                .stat = dotdot_stat,
                .path = try allocator.dupe(u8, dotdot_path),
            });
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            // Handle -a and -A options
            if (entry.name[0] == '.') {
                if (!options.all_files and !options.almost_all) {
                    continue; // Skip hidden files
                }
                if (options.almost_all and (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, ".."))) {
                    continue; // Skip . and .. with -A
                }
            }

            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });
            defer allocator.free(full_path);

            const entry_stat = try std.fs.cwd().statFile(full_path);

            try entries.append(DirEntry{
                .name = try allocator.dupe(u8, entry.name),
                .stat = entry_stat,
                .path = try allocator.dupe(u8, full_path),
            });
        }
    } else {
        // It's a file - create a single entry
        try entries.append(DirEntry{
            .name = try allocator.dupe(u8, std.fs.path.basename(path)),
            .stat = stat,
            .path = try allocator.dupe(u8, path),
        });
    }

    // Sort entries (unless -f is specified)
    if (!options.force_order) {
        if (options.sort_by_size) {
            std.mem.sort(DirEntry, entries.items, {}, sortBySize);
        } else if (options.sort_by_time) {
            if (options.sort_by_access_time) {
                std.mem.sort(DirEntry, entries.items, {}, sortByAccessTime);
            } else if (options.sort_by_status_time) {
                std.mem.sort(DirEntry, entries.items, {}, sortByStatusTime);
            } else {
                std.mem.sort(DirEntry, entries.items, {}, sortByModTime);
            }
        } else if (!options.sort_none) {
            std.mem.sort(DirEntry, entries.items, {}, sortByName);
        }

        if (options.reverse) {
            std.mem.reverse(DirEntry, entries.items);
        }
    }

    // Print entries
    if (options.long_format) {
        try printLongFormat(allocator, entries.items, options);
    } else if (options.stream_format) {
        try printStreamFormat(allocator, entries.items, options);
    } else if (options.multi_column or options.cross_format) {
        try printMultiColumnFormat(allocator, entries.items, options);
    } else {
        try printSimpleFormat(allocator, entries.items, options);
    }

    // Clean up
    for (entries.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
    }
}

const DirEntry = struct {
    name: []const u8,
    stat: std.fs.File.Stat,
    path: []const u8,
};

fn sortByName(context: void, a: DirEntry, b: DirEntry) bool {
    _ = context;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn sortByModTime(context: void, a: DirEntry, b: DirEntry) bool {
    _ = context;
    return a.stat.mtime > b.stat.mtime;
}

fn sortByAccessTime(context: void, a: DirEntry, b: DirEntry) bool {
    _ = context;
    return a.stat.atime > b.stat.atime;
}

fn sortByStatusTime(context: void, a: DirEntry, b: DirEntry) bool {
    _ = context;
    return a.stat.ctime > b.stat.ctime;
}

fn sortBySize(context: void, a: DirEntry, b: DirEntry) bool {
    _ = context;
    if (a.stat.size != b.stat.size) {
        return a.stat.size > b.stat.size;
    }
    return std.mem.lessThan(u8, a.name, b.name);
}

fn printSimpleFormat(allocator: std.mem.Allocator, entries: []DirEntry, options: LsOptions) !void {
    for (entries) |entry| {
        var name = entry.name;
        var allocated_name: ?[]const u8 = null;
        defer if (allocated_name) |alloc_name| allocator.free(alloc_name);

        if (options.show_indicators) {
            allocated_name = try addIndicator(allocator, entry.name, entry.stat.mode, options);
            name = allocated_name.?;
        }

        try xio.xwrite(posix.STDOUT_FILENO, name);
        try xio.xwrite(posix.STDOUT_FILENO, "  ");
    }

    if (entries.len > 0) {
        try xio.xwrite(posix.STDOUT_FILENO, "\n");
    }
}

fn printStreamFormat(allocator: std.mem.Allocator, entries: []DirEntry, options: LsOptions) !void {
    for (entries, 0..) |entry, i| {
        var name = entry.name;
        var allocated_name: ?[]const u8 = null;
        defer if (allocated_name) |alloc_name| allocator.free(alloc_name);

        if (options.show_indicators) {
            allocated_name = try addIndicator(allocator, entry.name, entry.stat.mode, options);
            name = allocated_name.?;
        }

        try xio.xwrite(posix.STDOUT_FILENO, name);

        if (i < entries.len - 1) {
            try xio.xwrite(posix.STDOUT_FILENO, ", ");
        }
    }

    if (entries.len > 0) {
        try xio.xwrite(posix.STDOUT_FILENO, "\n");
    }
}

fn printMultiColumnFormat(allocator: std.mem.Allocator, entries: []DirEntry, options: LsOptions) !void {
    // Simple multi-column format - just print entries with spaces
    const width = options.show_width orelse 80;
    var current_width: usize = 0;

    for (entries) |entry| {
        var name = entry.name;
        var allocated_name: ?[]const u8 = null;
        defer if (allocated_name) |alloc_name| allocator.free(alloc_name);

        if (options.show_indicators) {
            allocated_name = try addIndicator(allocator, entry.name, entry.stat.mode, options);
            name = allocated_name.?;
        }

        if (current_width + name.len + 2 > width) {
            try xio.xwrite(posix.STDOUT_FILENO, "\n");
            current_width = 0;
        }

        try xio.xwrite(posix.STDOUT_FILENO, name);
        try xio.xwrite(posix.STDOUT_FILENO, "  ");
        current_width += name.len + 2;
    }

    if (entries.len > 0) {
        try xio.xwrite(posix.STDOUT_FILENO, "\n");
    }
}

fn printLongFormat(allocator: std.mem.Allocator, entries: []DirEntry, options: LsOptions) !void {
    for (entries) |entry| {
        // File type and permissions
        const mode_str = try formatMode(allocator, entry.stat.mode);
        defer allocator.free(mode_str);

        // Number of links (hardcoded to 1 for now since Stat doesn't expose nlink)
        const links_str = try std.fmt.allocPrint(allocator, "1", .{});
        defer allocator.free(links_str);

        // Owner and group (hardcoded for now since Stat doesn't expose uid/gid)
        var owner_str: []const u8 = undefined;
        var group_str: []const u8 = undefined;

        if (options.numeric_ids) {
            owner_str = try std.fmt.allocPrint(allocator, "1000", .{});
            group_str = try std.fmt.allocPrint(allocator, "1000", .{});
        } else {
            owner_str = try std.fmt.allocPrint(allocator, "user", .{});
            group_str = try std.fmt.allocPrint(allocator, "user", .{});
        }
        defer allocator.free(owner_str);
        defer allocator.free(group_str);

        // File size or blocks
        var size_str: []const u8 = undefined;
        if (options.show_blocks) {
            const block_size = options.block_size orelse 512;
            const blocks = (entry.stat.size + block_size - 1) / block_size;
            size_str = try std.fmt.allocPrint(allocator, "{d}", .{blocks});
        } else {
            size_str = try std.fmt.allocPrint(allocator, "{d}", .{entry.stat.size});
        }
        defer allocator.free(size_str);

        // Time (modification, access, or status)
        var time_str: []const u8 = undefined;
        if (options.sort_by_access_time) {
            time_str = try formatTime(allocator, entry.stat.atime);
        } else if (options.sort_by_status_time) {
            time_str = try formatTime(allocator, entry.stat.ctime);
        } else {
            time_str = try formatTime(allocator, entry.stat.mtime);
        }
        defer allocator.free(time_str);

        // File name
        var name = entry.name;
        var allocated_name: ?[]const u8 = null;
        defer if (allocated_name) |alloc_name| allocator.free(alloc_name);

        if (options.show_indicators) {
            allocated_name = try addIndicator(allocator, entry.name, entry.stat.mode, options);
            name = allocated_name.?;
        }

        // Print the line
        try xio.xwrite(posix.STDOUT_FILENO, mode_str);
        try xio.xwrite(posix.STDOUT_FILENO, " ");
        try xio.xwrite(posix.STDOUT_FILENO, links_str);
        try xio.xwrite(posix.STDOUT_FILENO, " ");

        if (options.show_owner) {
            try xio.xwrite(posix.STDOUT_FILENO, owner_str);
            try xio.xwrite(posix.STDOUT_FILENO, " ");
        }

        if (options.show_group) {
            try xio.xwrite(posix.STDOUT_FILENO, group_str);
            try xio.xwrite(posix.STDOUT_FILENO, " ");
        }

        try xio.xwrite(posix.STDOUT_FILENO, size_str);
        try xio.xwrite(posix.STDOUT_FILENO, " ");
        try xio.xwrite(posix.STDOUT_FILENO, time_str);
        try xio.xwrite(posix.STDOUT_FILENO, " ");
        try xio.xwrite(posix.STDOUT_FILENO, name);
        try xio.xwrite(posix.STDOUT_FILENO, "\n");
    }
}

fn formatMode(allocator: std.mem.Allocator, mode: posix.mode_t) ![]const u8 {
    var buf: [11]u8 = undefined;
    var i: usize = 0;

    // File type
    switch (mode & posix.S.IFMT) {
        posix.S.IFREG => buf[i] = '-',
        posix.S.IFDIR => buf[i] = 'd',
        posix.S.IFLNK => buf[i] = 'l',
        posix.S.IFBLK => buf[i] = 'b',
        posix.S.IFCHR => buf[i] = 'c',
        posix.S.IFIFO => buf[i] = 'p',
        posix.S.IFSOCK => buf[i] = 's',
        else => buf[i] = '?',
    }
    i += 1;

    // Owner permissions
    buf[i] = if ((mode & posix.S.IRUSR) != 0) 'r' else '-';
    i += 1;
    buf[i] = if ((mode & posix.S.IWUSR) != 0) 'w' else '-';
    i += 1;
    buf[i] = if ((mode & posix.S.IXUSR) != 0) 'x' else '-';
    i += 1;

    // Group permissions
    buf[i] = if ((mode & posix.S.IRGRP) != 0) 'r' else '-';
    i += 1;
    buf[i] = if ((mode & posix.S.IWGRP) != 0) 'w' else '-';
    i += 1;
    buf[i] = if ((mode & posix.S.IXGRP) != 0) 'x' else '-';
    i += 1;

    // Other permissions
    buf[i] = if ((mode & posix.S.IROTH) != 0) 'r' else '-';
    i += 1;
    buf[i] = if ((mode & posix.S.IWOTH) != 0) 'w' else '-';
    i += 1;
    buf[i] = if ((mode & posix.S.IXOTH) != 0) 'x' else '-';
    i += 1;

    return try allocator.dupe(u8, buf[0..10]);
}

fn formatTime(allocator: std.mem.Allocator, mtime: i128) ![]const u8 {
    // Simple time formatting - just show the timestamp for now
    const time_str = try std.fmt.allocPrint(allocator, "{d}", .{mtime});

    return time_str;
}

fn addIndicator(allocator: std.mem.Allocator, name: []const u8, mode: posix.mode_t, options: LsOptions) ![]const u8 {
    var indicator: u8 = 0;

    switch (mode & posix.S.IFMT) {
        posix.S.IFDIR => indicator = '/',
        posix.S.IFLNK => indicator = '@',
        posix.S.IFIFO => indicator = '|',
        posix.S.IFSOCK => indicator = '=',
        posix.S.IFREG => {
            if (mode & posix.S.IXUSR != 0) {
                indicator = '*';
            }
        },
        else => {},
    }

    // Handle -p option (only show slash for directories)
    if (options.show_slash and (mode & posix.S.IFMT) == posix.S.IFDIR) {
        indicator = '/';
    }

    if (indicator != 0) {
        return try std.fmt.allocPrint(allocator, "{s}{c}", .{ name, indicator });
    } else {
        return try allocator.dupe(u8, name);
    }
}

fn printUsage() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "Usage: ls [OPTION]... [FILE]...\n");
    try xio.xwrite(posix.STDOUT_FILENO, "List information about the FILEs (the current directory by default).\n");
    try xio.xwrite(posix.STDOUT_FILENO, "\n");
    try xio.xwrite(posix.STDOUT_FILENO, "POSIX Options:\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -a    Write out all directory entries, including those whose names begin with a '.'\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -A    Write out all directory entries, except '.' and '..'\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -C    Write multi-text-column output with entries sorted down the columns\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -F    Write indicators after certain types of files (*/=>@|)\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -H    Follow symbolic links specified on command line\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -L    Follow all symbolic links\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -R    Recursively list subdirectories\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -S    Sort by file size, largest first\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -c    Use time of last modification of file status information\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -d    Do not treat directories differently than other files\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -f    List entries in directory order (no sorting)\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -g    Like -l but do not list owner\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -i    Print inode number of each file\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -k    Use 1024-byte blocks for -s option\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -l    Use long listing format\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -m    Stream output format (comma separated)\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -n    Like -l but list numeric user and group IDs\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -o    Like -l but do not list group information\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -p    Write a '/' after each pathname that is a directory\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -q    Force printing of non-graphic characters as '?'\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -r    Reverse the order of the sort\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -s    Indicate the total number of file system blocks\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -t    Sort by modification time, newest first\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -u    Use time of last access instead of last modification\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -x    Same as -C, except that entries are sorted across the columns\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -1    Force output to be one entry per line\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -Q    Enclose entry names in double quotes\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -U    Do not sort; list entries in directory order\n");
    try xio.xwrite(posix.STDOUT_FILENO, "  -w    Assume screen width instead of current value\n");
    try xio.xwrite(posix.STDOUT_FILENO, "\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --help                 display this help and exit\n");
    try xio.xwrite(posix.STDOUT_FILENO, "      --version              output version information and exit\n");
}

fn printVersion() !void {
    try xio.xwrite(posix.STDOUT_FILENO, "ls (zig-coreutils) 1.0.0\n");
    try xio.xwrite(posix.STDOUT_FILENO, "Copyright (C) 2025 Dongjun \"Aurorasphere\" Kim\n");
    try xio.xwrite(posix.STDOUT_FILENO, "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "This is free software: you are free to change and redistribute it.\n");
    try xio.xwrite(posix.STDOUT_FILENO, "There is NO WARRANTY, to the extent permitted by law.\n");
}
