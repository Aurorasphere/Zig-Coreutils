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
    // Support multiple architectures for POSIX compatibility
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Multi-architecture support option
    const multi_arch = b.option(bool, "multi-arch", "Build for multiple architectures") orelse false;

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
        "true",
        "false",
        "ls",
    };

    // Supported architectures for POSIX systems
    // Note: Some architectures may have limited support in Zig/LLVM
    const supported_targets = [_]std.Target.Query{
        // Linux - x86 architectures (fully supported)
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .gnu },

        // Linux - ARM architectures (fully supported)
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .gnueabihf },

        // Linux - RISC-V (good support)
        .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .riscv32, .os_tag = .linux, .abi = .gnu },

        // Linux - POWER architecture (limited support - may require additional setup)
        .{ .cpu_arch = .powerpc64le, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .powerpc64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .powerpc, .os_tag = .linux, .abi = .gnu },

        // Linux - SPARC architecture (limited support - may require additional setup)
        .{ .cpu_arch = .sparc64, .os_tag = .linux, .abi = .gnu },

        // Linux - MIPS architecture (basic support)
        .{ .cpu_arch = .mips64el, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .mips64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .mipsel, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .mips, .os_tag = .linux, .abi = .gnu },

        // Linux - LoongArch (emerging architecture)
        .{ .cpu_arch = .loongarch64, .os_tag = .linux, .abi = .gnu },

        // BSD systems (well supported)
        .{ .cpu_arch = .x86_64, .os_tag = .freebsd },
        .{ .cpu_arch = .x86_64, .os_tag = .openbsd },
        .{ .cpu_arch = .x86_64, .os_tag = .netbsd },
        .{ .cpu_arch = .x86_64, .os_tag = .dragonfly },
        .{ .cpu_arch = .aarch64, .os_tag = .freebsd },
        .{ .cpu_arch = .aarch64, .os_tag = .openbsd },
        .{ .cpu_arch = .aarch64, .os_tag = .netbsd },
        .{ .cpu_arch = .sparc64, .os_tag = .freebsd },

        // macOS (Darwin) - Apple Silicon and Intel (fully supported)
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },

        // IBM AIX: POWER architecture (limited support)
        .{ .cpu_arch = .powerpc, .os_tag = .aix, .abi = .gnu },
        .{ .cpu_arch = .powerpc64, .os_tag = .aix, .abi = .gnu },
        .{ .cpu_arch = .powerpc64le, .os_tag = .aix, .abi = .gnu },

        // Solaris/illumos
        .{ .cpu_arch = .sparc, .os_tag = .solaris, .abi = .gnu },
        .{ .cpu_arch = .sparc64, .os_tag = .solaris, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .solaris, .abi = .gnu },
        .{ .cpu_arch = .sparc, .os_tag = .illumos, .abi = .gnu },
        .{ .cpu_arch = .sparc64, .os_tag = .illumos, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .illumos, .abi = .gnu },

        // Additional embedded/specialized systems
        .{ .cpu_arch = .x86_64, .os_tag = .freestanding },
        .{ .cpu_arch = .aarch64, .os_tag = .freestanding },

        // Haiku (BeOS successor)
        .{ .cpu_arch = .x86_64, .os_tag = .haiku },
        .{ .cpu_arch = .x86, .os_tag = .haiku },
    };

    // Multi-architecture build
    if (multi_arch) {
        for (supported_targets) |target_query| {
            const resolved_target = b.resolveTargetQuery(target_query);
            const arch_name = @tagName(target_query.cpu_arch.?);
            const os_name = @tagName(target_query.os_tag.?);

            for (coreutils) |util_name| {
                const exe_name = b.fmt("{s}-{s}-{s}", .{ util_name, arch_name, os_name });
                const exe = b.addExecutable(.{
                    .name = exe_name,
                    .root_module = b.createModule(.{
                        .root_source_file = .{ .cwd_relative = b.fmt("src/coreutils/{s}.zig", .{util_name}) },
                        .target = resolved_target,
                        .optimize = if (release_build) .ReleaseFast else optimize,
                    }),
                });

                // Add common dependencies
                exe.root_module.addImport("posix-xio", posix_xio);
                exe.root_module.addOptions("coreutils_options", coreutils_options);

                // Install the executable
                b.installArtifact(exe);
            }
        }

        // Multi-arch build step
        const multi_arch_step = b.step("multi-arch", "Build all coreutils for multiple architectures");
        multi_arch_step.dependOn(b.getInstallStep());
    }
    // Dynamic build (default)
    else if (!static_build) {
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
            });

            // Strip debug info is handled by optimize mode for release builds

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
        .root_module = b.createModule(.{
            .root_source_file = .{ .cwd_relative = "src/coreutils/posix-xio.zig" },
            .target = target,
            .optimize = optimize,
        }),
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
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  zig build                    - Build dynamic executables" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  zig build -Dstatic           - Build static executables" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  zig build -Drelease          - Build release executables" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  zig build -Dmulti-arch       - Build for multiple architectures" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  zig build -Dstatic -Drelease - Build static release executables" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "Supported architectures:" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  Fully supported: x86_64, x86, aarch64, arm" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  Good support: riscv64, riscv32" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  Limited support: powerpc64le, powerpc64, powerpc, mips64el, mips64, mipsel, mips" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  Experimental: sparc64, loongarch64" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  Note: SPARC, POWER, and MIPS may require additional setup" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "Supported operating systems:" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  Linux (all supported architectures)" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  BSD: FreeBSD, OpenBSD, NetBSD, DragonFly BSD" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  macOS (Intel and Apple Silicon)" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  Solaris/illumos (x86_64, SPARC)" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  AIX (POWER architecture - limited support)" }).step);
    help_step.dependOn(&b.addSystemCommand(&.{ "echo", "  Other: Haiku, Freestanding (embedded)" }).step);
}
