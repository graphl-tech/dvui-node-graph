const std = @import("std");

pub fn build(b: *std.Build) void {
    // The library module has no `dvui` import: a program must contain exactly one dvui, so the
    // consumer adds their own:
    //
    //     const ng = b.dependency("dvui_node_graph", .{}).module("dvui_node_graph");
    //     ng.addImport("dvui", my_dvui_module);
    _ = b.addModule("dvui_node_graph", .{ .root_source_file = b.path("src/dvui_node_graph.zig") });

    // The demo and tests pin their own dvui. Only set them up when this package is the root of
    // the build, so consumers never fetch or configure that dvui (or its SDL3).
    if (b.dep_prefix.len != 0) return;
    devSteps(b);
}

fn devSteps(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filter = b.option([]const u8, "test_filter", "filter tests by name");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const dvui_sdl3_dep = b.lazyDependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 }) orelse return;
    const dvui_testing_dep = b.lazyDependency("dvui", .{ .target = target, .optimize = optimize, .backend = .testing }) orelse return;
    const dvui_sdl3 = dvui_sdl3_dep.module("dvui_sdl3");
    const dvui_testing = dvui_testing_dep.module("dvui_testing");

    // demo
    {
        const demo = b.addExecutable(.{
            .name = "dvui-node-graph-demo",
            .root_module = withNodeGraph(b, target, optimize, dvui_sdl3, "examples/demo.zig"),
        });
        const install = b.addInstallArtifact(demo, .{});
        b.getInstallStep().dependOn(&install.step);
        const run = b.addRunArtifact(demo);
        run.step.dependOn(&install.step);
        if (b.args) |args| run.addArgs(args);
        b.step("demo", "Run the SDL3 demo").dependOn(&run.step);
    }

    // `zig build test`: unit tests + headless interaction tests (dvui testing backend)
    {
        const tests = b.addTest(.{
            .name = "dvui-node-graph-test",
            .root_module = withNodeGraph(b, target, optimize, dvui_testing, "src/tests.zig"),
            .filters = test_filters,
        });
        tests.root_module.addOptions("test_options", testOptions(b, false));
        const run = b.addRunArtifact(tests);
        run.has_side_effects = true;
        const test_step = b.step("test", "Run tests (headless)");
        test_step.dependOn(&run.step);

        const unit_mod = b.createModule(.{
            .root_source_file = b.path("src/dvui_node_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        unit_mod.addImport("dvui", dvui_testing);
        const unit = b.addTest(.{ .name = "dvui-node-graph-unit", .root_module = unit_mod, .filters = test_filters });
        test_step.dependOn(&b.addRunArtifact(unit).step);
    }

    // `zig build test-images`: same tests on sdl3, writing PNGs to snapshots/images
    {
        const tests = b.addTest(.{
            .name = "dvui-node-graph-test-images",
            .root_module = withNodeGraph(b, target, optimize, dvui_sdl3, "src/tests.zig"),
            .filters = test_filters,
        });
        tests.root_module.addOptions("test_options", testOptions(b, true));
        const run = b.addRunArtifact(tests);
        run.has_side_effects = true;
        b.step("test-images", "Render snapshot tests to PNGs in snapshots/images").dependOn(&run.step);
    }
}

fn testOptions(b: *std.Build, images: bool) *std.Build.Step.Options {
    const opts = b.addOptions();
    opts.addOption(bool, "images", images);
    return opts;
}

/// A module rooted at `root` that can import `dvui` and `dvui_node_graph`, both on `dvui_mod`.
fn withNodeGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dvui_mod: *std.Build.Module,
    root: []const u8,
) *std.Build.Module {
    const lib = b.createModule(.{
        .root_source_file = b.path("src/dvui_node_graph.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.addImport("dvui", dvui_mod);
    const m = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
    });
    m.addImport("dvui", dvui_mod);
    m.addImport("dvui_node_graph", lib);
    return m;
}
