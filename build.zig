const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("dvui_node_graph", .{ .root_source_file = b.path("src/dvui_node_graph.zig") });
    // Only set up dvui+sdl3 dep when we are the root (e.g. testing), not a dependency
    // FIXME: check if the lazy dependency is installed in edge cases
    const is_build_root = b.dep_prefix.len == 0;
    if (!is_build_root) return;
    devSteps(b);
}

fn devSteps(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filter = b.option([]const u8, "test_filter", "filter tests by name");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const dvui_sdl3_dep = b.lazyDependency("dvui", .{ .target = target, .optimize = optimize, .backend = .sdl3 }) orelse return;
    const dvui_testing_dep = b.lazyDependency("dvui", .{ .target = target, .optimize = optimize, .backend = .testing }) orelse return;
    const sdl3: Backend = .init(b, target, optimize, dvui_sdl3_dep.module("dvui_sdl3"));
    const testing: Backend = .init(b, target, optimize, dvui_testing_dep.module("dvui_testing"));

    // demo
    {
        const demo_step = b.step("demo", "Run the SDL3 demo");
        const demo = b.addExecutable(.{
            .name = "dvui-node-graph-demo",
            .root_module = sdl3.module(b, "examples/demo.zig"),
        });
        const install = b.addInstallArtifact(demo, .{});
        b.getInstallStep().dependOn(&install.step);
        const run = b.addRunArtifact(demo);
        run.step.dependOn(&install.step);
        run.addPassthruArgs();
        demo_step.dependOn(&run.step);
    }

    {
        const test_step = b.step("test", "Run tests (headless)");
        const e2e_tests = b.addTest(.{
            .name = "dvui-node-graph-test-e2e",
            .root_module = testing.tests(b, false),
            .filters = test_filters,
        });
        const run = b.addRunArtifact(e2e_tests);
        run.has_side_effects = true;
        test_step.dependOn(&run.step);

        const unit_tests = b.addTest(.{ .name = "dvui-node-graph-unit", .root_module = testing.lib, .filters = test_filters });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    {
        const test_images_step = b.step("test-images", "Render snapshot tests to PNGs in snapshots/images");
        const tests = b.addTest(.{
            .name = "dvui-node-graph-test-images",
            .root_module = sdl3.tests(b, true),
            .filters = test_filters,
        });
        const run = b.addRunArtifact(tests);
        run.has_side_effects = true;
        test_images_step.dependOn(&run.step);
    }
}

const Backend = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    dvui: *std.Build.Module,
    lib: *std.Build.Module,

    fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, dvui: *std.Build.Module) Backend {
        const lib = b.createModule(.{
            .root_source_file = b.path("src/dvui_node_graph.zig"),
            .target = target,
            .optimize = optimize,
        });
        lib.addImport("dvui", dvui);
        return .{ .target = target, .optimize = optimize, .dvui = dvui, .lib = lib };
    }

    fn module(self: Backend, b: *std.Build, root: []const u8) *std.Build.Module {
        const m = b.createModule(.{
            .root_source_file = b.path(root),
            .target = self.target,
            .optimize = self.optimize,
        });
        m.addImport("dvui", self.dvui);
        m.addImport("dvui_node_graph", self.lib);
        return m;
    }

    /// e2e tests, which also drive the demo.
    fn tests(self: Backend, b: *std.Build, images: bool) *std.Build.Module {
        const m = self.module(b, "src/tests.zig");
        m.addImport("demo", self.module(b, "examples/demo.zig"));
        const opts = b.addOptions();
        opts.addOption(bool, "images", images);
        m.addOptions("test_options", opts);
        return m;
    }
};
