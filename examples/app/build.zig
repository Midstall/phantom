const std = @import("std");
const phantom = @import("phantom");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const phantom_dep = b.dependency("phantom", .{
        .target = target,
        .optimize = optimize,
    });

    const app = phantom.addApp(b, phantom_dep, .{
        .id = "org.example.phantom.demo",
        .name = .{ .default = "Phantom Demo" },
        .summary = .{ .default = "A minimal PhantomUI demo application" },
        .description = .{ .default = "Padded blue box rendered by the PhantomUI framework." },
        .categories = &.{.utility},
        .root = b.path("src/app.zig"),
        .developer = "Example Developer",
        .license = "Apache-2.0",
        .icons = &.{},
        .target = target,
        .optimize = optimize,
    });

    b.getInstallStep().dependOn(app);
}
