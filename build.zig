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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const static_build = b.option(bool, "static", "Build static executables") orelse false;
    const release_build = b.option(bool, "release", "Build release executables") orelse false;

    // Common options for all coreutils
    const coreutils_options = b.addOptions();
    coreutils_options.addOption([]const u8, "version", "1.0.0");

    // Common dependencies
    const posix_xio = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/coreutils/posix-xio.zig" },
    });

    // Build all coreutils
    const coreutils = [_][]const u8{
        "echo",
        "true",
        "false",
        "pwd",
        "mkdir",
        "cat",
        "tty",
        "ls",
        "printf",
    };

    // Dynamic build (default)
    if (!static_build) {
        for (coreutils) |util_name| {
            const exe = b.addExecutable(.{
                .name = util_name,
                .root_module = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = b.fmt("src/coreutils/{s}.zig", .{util_name}) },
                    .target = target,
                    .optimize = if (release_build) .ReleaseFast else optimize,
                }),
            });

            // Add common dependencies
            exe.root_module.addImport("posix-xio", posix_xio);
            exe.root_module.addOptions("coreutils_options", coreutils_options);

            // Install the executable
            b.installArtifact(exe);

            // Add run step for testing
            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }

            const run_step = b.step(b.fmt("run-{s}", .{util_name}), b.fmt("Run the {s} utility", .{util_name}));
            run_step.dependOn(&run_cmd.step);
        }

        // Dynamic build step
        const dynamic_step = b.step("dynamic", "Build all coreutils as dynamic executables");
        dynamic_step.dependOn(b.getInstallStep());
    }

    // Static build
    if (static_build) {
        for (coreutils) |util_name| {
            const static_exe = b.addExecutable(.{
                .name = util_name,
                .root_module = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = b.fmt("src/coreutils/{s}.zig", .{util_name}) },
                    .target = target,
                    .optimize = if (release_build) .ReleaseSmall else .Debug,
                }),
                .single_threaded = true,
                .strip = release_build,
            });

            // Add common dependencies
            static_exe.root_module.addImport("posix-xio", posix_xio);
            static_exe.root_module.addOptions("coreutils_options", coreutils_options);

            // Link statically
            static_exe.linkage = .static;

            // Install the static executable
            b.installArtifact(static_exe);
        }

        // Static build step
        const static_step = b.step("static", "Build all coreutils as static executables");
        static_step.dependOn(b.getInstallStep());
    }

    // Test step
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/coreutils/posix-xio.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Build all step
    const build_all_step = b.step("all", "Build all coreutils (dynamic by default)");
    if (static_build) {
        // Static build step is already created above
        build_all_step.dependOn(b.getInstallStep());
    } else {
        // Dynamic build step is already created above
        build_all_step.dependOn(b.getInstallStep());
    }

    // Clean step
    const clean_step = b.step("clean", "Clean build artifacts");
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = "zig-out" }).step);
    clean_step.dependOn(&b.addRemoveDirTree(.{ .cwd_relative = "zig-cache" }).step);

    // Help step
    const help_step = b.step("help", "Show build options");
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "Available build options:" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  zig build              - Build dynamic executables" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  zig build -Dstatic     - Build static executables" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  zig build -Drelease    - Build release executables" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  zig build -Dstatic -Drelease - Build static release executables" }).step);
}
