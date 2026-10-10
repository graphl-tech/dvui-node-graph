//! Interaction tests driven through `dvui.testing`. `zig build test` runs them headless;
//! `zig build test-images` runs them on sdl3 and writes PNGs to snapshots/images.

const std = @import("std");
const dvui = @import("dvui");
const ng = @import("dvui_node_graph");

test {
    std.testing.refAllDecls(ng);
}

/// Mutable state the frame functions read and write. Reset by each test.
const Fixture = struct {
    view: ng.GraphWidget.View = .{},
    edges: std.ArrayList(ng.Edge) = .empty,
    events: std.ArrayList(ng.GraphWidget.Event) = .empty,
    socket_events: std.ArrayList(struct { socket: ng.SocketId, event: ng.BaseSocket.Event }) = .empty,
    node1_pos: dvui.Point = .{ .x = 20, .y = 40 },
    node2_pos: dvui.Point = .{ .x = 260, .y = 140 },
    node3_pos: dvui.Point = .{ .x = 20, .y = 220 },
    allow_same_side_links: bool = false,
    selected_socket: ?ng.SocketId = null,
    /// Copy of the last `nodes_moved` node list (event slices only live for one frame).
    moved_nodes: std.ArrayList(ng.NodeId) = .empty,

    fn deinit(self: *Fixture) void {
        self.edges.deinit(std.testing.allocator);
        self.events.deinit(std.testing.allocator);
        self.socket_events.deinit(std.testing.allocator);
        self.moved_nodes.deinit(std.testing.allocator);
        self.* = .{};
    }

    fn hasEvent(self: *const Fixture, comptime tag: std.meta.Tag(ng.GraphWidget.Event)) ?ng.GraphWidget.Event {
        for (self.events.items) |e| if (e == tag) return e;
        return null;
    }
};

var fx: Fixture = .{};

fn imperativeFrame() anyerror!dvui.App.Result {
    const alloc = std.testing.allocator;
    var graph = ng.graph(@src(), .{ .view = &fx.view, .allow_same_side_links = fx.allow_same_side_links }, .{ .tag = "graph" });
    defer graph.deinit();

    {
        var node = graph.node(@src(), 1, &fx.node1_pos, struct { x: i32 }{ .x = 5 }, struct { s: []const u8 }{ .s = "" }, .{
            .title = "one",
        }, .{ .tag = "node-1" });
        defer node.deinit();
        for (0..node.inputs.len()) |i| node.baseInput(@src(), i, .{ .id_extra = i });
        for (0..node.outputs.len()) |i| {
            var row = ng.BaseOutput.initEx(@src(), node, i, .{ .socket_opts = .{ .tag = "out-1-0" } }, .{ .id_extra = i });
            defer row.deinit();
            row.defaultLabel();
        }
    }

    graph.baseNodeEx(@src(), 3, &fx.node3_pos, struct { a: bool, b: f32 }{ .a = true, .b = 1.5 }, struct { c: u8 }{ .c = 0 }, .{
        .title = "three",
    }, .{ .tag = "node-3" });

    {
        var node = graph.node(@src(), 2, &fx.node2_pos, struct { s: []const u8 }{ .s = "" }, struct { out: f32 }{ .out = 0 }, .{
            .title = "two",
        }, .{ .tag = "node-2" });
        defer node.deinit();

        for (0..node.inputs.len()) |i| {
            var row = ng.BaseInput.initEx(@src(), node, i, .{ .socket_opts = .{ .tag = "in-2-0" } }, .{ .id_extra = i });
            defer row.deinit();
            dvui.labelNoFmt(@src(), row.name(), .{}, .{});

            for (row.events()) |e| switch (e) {
                .socket => |se| try fx.socket_events.append(alloc, .{ .socket = row.socketId(), .event = se }),
            };
        }
        for (0..node.outputs.len()) |i| {
            var row = ng.BaseOutput.initEx(@src(), node, i, .{ .socket_opts = .{ .tag = "out-2-0" } }, .{ .id_extra = i });
            defer row.deinit();
            row.defaultLabel();
        }
    }

    for (fx.edges.items) |e| _ = graph.link(e.source.node, e.source.socket, e.target.node, e.target.socket);

    defer fx.selected_socket = graph.selectedSocket();
    for (graph.events()) |e| {
        try fx.events.append(alloc, e);
        switch (e) {
            .link_created => |edge| try fx.edges.append(alloc, edge),
            .nodes_moved => |m| {
                fx.moved_nodes.clearRetainingCapacity();
                try fx.moved_nodes.appendSlice(alloc, m.nodes);
            },
            else => {},
        }
    }
    return .ok;
}

fn initTest() !dvui.testing {
    fx.deinit();
    return dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 }, .snapshot_dir = "snapshots" });
}

/// In `zig build test-images`, renders the next frame to
/// `<snapshot_dir>/images/<file>-<test>-<n>.png`. Writes the PNG directly instead of using
/// `dvui.testing.snapshot`, which does not build on zig 0.16 in upstream dvui yet.
fn snapshotIfImages(t: *dvui.testing, src: std.builtin.SourceLocation, frame: dvui.App.frameFunction) !void {
    if (!@import("test_options").images) return;
    defer t.snapshot_index += 1;
    const io = dvui.io;
    const alloc = std.testing.allocator;
    const dir_path = try std.fmt.allocPrint(alloc, "{s}/images", .{t.snapshot_dir});
    defer alloc.free(dir_path);
    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}-{s}-{d}.png", .{ dir_path, src.file, src.fn_name, t.snapshot_index });
    defer alloc.free(path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [512]u8 = undefined;
    var writer = file.writer(io, &buf);
    try dvui.testing.capturePng(frame, null, &writer.interface);
    try writer.end();
}

test "imperative graph renders and remembers node positions" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(imperativeFrame);
    try dvui.testing.expectVisible("node-1");
    try dvui.testing.expectVisible("node-2");
    try dvui.testing.expectVisible("in-2-0");

    const n1 = dvui.tagGet("node-1").?.rect;
    const n2 = dvui.tagGet("node-2").?.rect;
    try std.testing.expect(n1.x < n2.x);
}

test "dragging a node moves it and reports nodes_moved" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(imperativeFrame);
    const before = fx.node2_pos;

    try dvui.testing.moveTo("node-2");
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(imperativeFrame);
    const start = cw.mouse_pt;
    for (1..5) |i| {
        _ = try cw.addEventMouseMotion(.{ .pt = start.plus(.{ .x = @floatFromInt(i * 10), .y = @floatFromInt(i * 5) }) });
        _ = try dvui.testing.step(imperativeFrame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(imperativeFrame);

    // 40x20 physical pixels at zoom 1 is 40x20 natural pixels in graph space
    const s = cw.natural_scale;
    try std.testing.expectApproxEqAbs(before.x + 40 / s, fx.node2_pos.x, 0.01);
    try std.testing.expectApproxEqAbs(before.y + 20 / s, fx.node2_pos.y, 0.01);
    const moved = fx.hasEvent(.nodes_moved) orelse return error.NoNodesMoved;
    try std.testing.expectEqualSlices(ng.NodeId, &.{2}, fx.moved_nodes.items);
    try std.testing.expectApproxEqAbs(40 / s, moved.nodes_moved.delta.x, 0.01);
    try std.testing.expect(fx.hasEvent(.selection_changed) != null);
}

/// Press on `from_tag`, drag a wire onto `to_tag` and release.
fn dragWire(t: *dvui.testing, from_tag: []const u8, to_tag: []const u8, src: std.builtin.SourceLocation) !void {
    const cw = dvui.currentWindow();
    const target = dvui.tagGet(to_tag).?.rect.center();
    try dvui.testing.moveTo(from_tag);
    _ = try dvui.testing.step(imperativeFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(imperativeFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = target.plus(.{ .x = -60, .y = 70 }) });
    _ = try dvui.testing.step(imperativeFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = target.plus(.{ .x = -60, .y = 70 }) });
    _ = try dvui.testing.step(imperativeFrame);
    try snapshotIfImages(t, src, imperativeFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = target });
    _ = try dvui.testing.step(imperativeFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = target });
    _ = try dvui.testing.step(imperativeFrame);
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(imperativeFrame);
}

test "dragging a wire from an output onto an input creates a link" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(imperativeFrame);
    try dragWire(&t, "out-1-0", "in-2-0", @src());

    try std.testing.expectEqual(1, fx.edges.items.len);
    try std.testing.expect(fx.edges.items[0].eql(.{ .source = .output(1, 0), .target = .input(2, 0) }));
    try snapshotIfImages(&t, @src(), imperativeFrame);
}

test "output to output wires need allow_same_side_links" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(imperativeFrame);
    try dragWire(&t, "out-1-0", "out-2-0", @src());
    try std.testing.expectEqual(0, fx.edges.items.len);
    try std.testing.expect(fx.hasEvent(.link_dropped) != null);

    fx.allow_same_side_links = true;
    try dvui.testing.settle(imperativeFrame);
    try dragWire(&t, "out-1-0", "out-2-0", @src());
    try std.testing.expectEqual(1, fx.edges.items.len);
    try std.testing.expect(fx.edges.items[0].eql(.{ .source = .output(1, 0), .target = .output(2, 0) }));
    try snapshotIfImages(&t, @src(), imperativeFrame);
}

test "clicking a socket reports a socket click event" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(imperativeFrame);
    try dvui.testing.moveTo("in-2-0");
    try dvui.testing.click(.left);
    try dvui.testing.settle(imperativeFrame);

    var saw_click = false;
    for (fx.socket_events.items) |se| switch (se.event) {
        .mouse => |me| switch (me) {
            .click => saw_click = se.socket.eql(.input(2, 0)),
            .press => {},
        },
        .wire => {},
    };
    try std.testing.expect(saw_click);
    try std.testing.expect(fx.hasEvent(.socket_clicked) != null);
}

test "dragging empty canvas pans and wheel zooms" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(imperativeFrame);
    const cw = dvui.currentWindow();
    const empty: dvui.Point.Physical = blk: {
        const g = dvui.tagGet("graph").?.rect;
        break :blk .{ .x = g.x + g.w - 20, .y = g.y + g.h - 20 };
    };
    _ = try cw.addEventMouseMotion(.{ .pt = empty });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(imperativeFrame);
    for (1..4) |i| {
        _ = try cw.addEventMouseMotion(.{ .pt = empty.plus(.{ .x = -@as(f32, @floatFromInt(i * 10)), .y = 0 }) });
        _ = try dvui.testing.step(imperativeFrame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(imperativeFrame);
    try std.testing.expect(fx.view.origin.x > 10);

    const before = fx.view.scale;
    _ = try cw.addEventMouseWheel(120, .vertical, null);
    try dvui.testing.settle(imperativeFrame);
    try std.testing.expect(fx.view.scale != before);
}

const Decl = struct {
    clicks: usize = 0,
    links: usize = 0,

    const Add = ng.declarative.NodeType(struct { a: i32, b: i32 }, struct { sum: i32 });

    fn onClickSocket(self: *Decl, socket: ng.SocketId, click: ng.BaseSocket.Click) void {
        _ = socket;
        _ = click;
        self.clicks += 1;
    }

    fn onEvent(self: *Decl, e: ng.GraphWidget.Event) void {
        if (e == .link_created) self.links += 1;
    }

    fn drawInputLabel(self: *Decl, row: *ng.BaseInput, desc: ng.declarative.Node) void {
        _ = self;
        dvui.label(@src(), "{s}.{s}", .{ desc.title orelse "?", row.name() }, .{});
    }
};
var decl: Decl = .{};

fn declarativeFrame() anyerror!dvui.App.Result {
    _ = ng.declarative.graph(@src(), &decl, .{
        .nodes = &.{
            Decl.Add.nodeAt(1, "add", .{ .x = 20, .y = 20 }),
            Decl.Add.nodeAt(2, "add2", .{ .x = 260, .y = 120 }),
        },
        .edges = &.{.{ .source = .output(1, 0), .target = .input(2, 0) }},
        .draw_input_label = Decl.drawInputLabel,
        .on_click_socket = Decl.onClickSocket,
        .on_event = Decl.onEvent,
    }, .{ .tag = "decl-graph" });
    return .ok;
}

test "declarative graph renders nodes, edges and custom labels" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 }, .snapshot_dir = "snapshots" });
    defer t.deinit();
    decl = .{};

    try dvui.testing.settle(declarativeFrame);
    try dvui.testing.expectVisible("decl-graph");
    try snapshotIfImages(&t, @src(), declarativeFrame);
}

/// Verbatim copy of the README's imperative example, kept compiling.
fn readmeFrame() anyerror!dvui.App.Result {

    // node positions live in your model; dragging a node writes through its pointer
    const model = struct {
        var positions = [_]dvui.Point{ .{ .x = 20, .y = 40 }, .{ .x = 260, .y = 140 } };
    };

    // start from the default style and override what you need
    var style = ng.Style.default;
    style.edge.shadow = null;
    style.node.corner_radius = 4;

    var graph = ng.graph(@src(), .{ .style = style }, .{});
    defer graph.deinit();

    // a default node
    graph.baseNode(@src(), 1, &model.positions[0], struct { x: i32 }{ .x = 5 }, struct { s: []const u8 }{ .s = "" });

    {
        var node = graph.node(@src(), 2, &model.positions[1], struct { s: []const u8 }{ .s = "" }, struct {}{}, .{ .title = "two" }, .{});
        defer node.deinit();

        for (0..node.inputs.len()) |i| {
            var row = ng.BaseInput.init(@src(), node, i, .{ .id_extra = i });
            defer row.deinit();
            // anything drawn here lands next to the socket
            dvui.label(@src(), "{s}", .{row.name()}, .{});

            for (row.events()) |e| switch (e) {
                .socket => |se| switch (se) {
                    .mouse => |me| switch (me) {
                        .click => |click| std.log.info("clicked at {any}", .{click.p}),
                        .press => {},
                    },
                    .wire => |we| switch (we) {
                        .start => {},
                        .connect => |other| std.log.info("wired to {any}", .{other}),
                        .drop => |graph_point| std.log.info("dropped at {any}", .{graph_point}),
                    },
                },
            };
        }
        for (0..node.outputs.len()) |i| node.baseOutput(@src(), i, .{ .id_extra = i });
    }

    // edges go after the nodes that own their sockets
    _ = graph.link(1, .output(0), 2, .input(0)); // node 1's first output -> node 2's first input

    for (graph.events()) |e| switch (e) {
        .link_created => {}, // wire released on a compatible socket (opposite sides: output -> input)
        .link_dropped => {}, // wire released on empty canvas, `.point` is graph space
        .link_clicked => {},
        .nodes_moved => {}, // `.nodes` moved by `.delta`
        .delete_selection => {},
        .context_menu => {}, // right click on canvas/node/socket
        else => {},
    };
    return .ok;
}

test "README imperative example" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 } });
    defer t.deinit();
    try dvui.testing.settle(readmeFrame);
}

/// A graph whose node 2 has a free-floating "+" socket for input 5, which it doesn't have yet.
const PlusFixture = struct {
    var events: std.ArrayList(ng.GraphWidget.Event) = .empty;
    var selected: std.ArrayList(ng.NodeId) = .empty;

    fn isSelected(_: *anyopaque, id: ng.NodeId) bool {
        return std.mem.indexOfScalar(ng.NodeId, selected.items, id) != null;
    }
    fn setSelected(_: *anyopaque, id: ng.NodeId, on: bool) void {
        const i = std.mem.indexOfScalar(ng.NodeId, selected.items, id);
        if (on and i == null) selected.append(std.testing.allocator, id) catch {};
        if (!on) if (i) |at| {
            _ = selected.orderedRemove(at);
        };
    }
    fn clear(_: *anyopaque) void {
        selected.clearRetainingCapacity();
    }
    fn list(_: *anyopaque, alloc: std.mem.Allocator) []const ng.NodeId {
        return alloc.dupe(ng.NodeId, selected.items) catch &.{};
    }
    const vtable: ng.GraphWidget.Selection.VTable = .{ .isSelected = isSelected, .setSelected = setSelected, .clear = clear, .list = list };
    var dummy: u8 = 0;
    var positions = [_]dvui.Point{ .{ .x = 20, .y = 40 }, .{ .x = 260, .y = 140 } };

    fn frame() anyerror!dvui.App.Result {
        var graph = ng.graph(@src(), .{ .selection = .{ .ctx = &dummy, .vtable = &vtable } }, .{});
        defer graph.deinit();

        {
            var node = graph.node(@src(), 1, &positions[0], struct {}{}, struct { out: i32 }{ .out = 0 }, .{}, .{ .tag = "pn-1" });
            defer node.deinit();
            var row = ng.BaseOutput.initEx(@src(), node, 0, .{ .socket_opts = .{ .tag = "pn-out" } }, .{});
            defer row.deinit();
            row.defaultLabel();
        }
        {
            var node = graph.node(@src(), 2, &positions[1], struct { a: i32 }{ .a = 0 }, struct {}{}, .{}, .{ .tag = "pn-2" });
            defer node.deinit();
            node.baseInput(@src(), 0, .{});
            // floats left of the card, not part of the layout
            const card = node.card.data().borderRectScale().r;
            var plus = ng.BaseSocket.init(@src(), graph, .input(2, 5), .{
                .style = .{ .icon = .{ .name = "test_plus", .tvg = dvui.entypo.circle_with_plus } },
                .edge_overlap = false,
            }, .{ .rect = node.column.data().contentRectScale().rectFromPhysical(.{ .x = card.x - 30, .y = card.y, .w = 20, .h = 20 }), .tag = "plus" });
            plus.deinit();
        }
        for (graph.events()) |e| try events.append(std.testing.allocator, e);
        return .ok;
    }
};

fn dragBetween(from: []const u8, to: []const u8, frame: dvui.App.frameFunction) !void {
    const cw = dvui.currentWindow();
    const target = dvui.tagGet(to).?.rect.center();
    try dvui.testing.moveTo(from);
    _ = try dvui.testing.step(frame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(frame);
    for (0..2) |_| {
        _ = try cw.addEventMouseMotion(.{ .pt = target });
        _ = try dvui.testing.step(frame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(frame);
}

test "a socket the model doesn't have yet works both ways; selection can be caller-owned" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 } });
    defer t.deinit();
    defer PlusFixture.events.deinit(std.testing.allocator);
    defer PlusFixture.selected.deinit(std.testing.allocator);

    try dvui.testing.settle(PlusFixture.frame);
    try dvui.testing.expectVisible("plus");

    const want: ng.Edge = .{ .source = .output(1, 0), .target = .input(2, 5) };
    for ([_][2][]const u8{ .{ "plus", "pn-out" }, .{ "pn-out", "plus" } }) |drag| {
        PlusFixture.events.clearRetainingCapacity();
        try dragBetween(drag[0], drag[1], PlusFixture.frame);
        var created: ?ng.Edge = null;
        for (PlusFixture.events.items) |e| if (e == .link_created) {
            created = e.link_created;
        };
        try std.testing.expect(created.?.eql(want));
    }

    // clicking a node selects it through the caller's selection
    try dvui.testing.moveTo("pn-1");
    try dvui.testing.click(.left);
    try dvui.testing.settle(PlusFixture.frame);
    try std.testing.expectEqualSlices(ng.NodeId, &.{1}, PlusFixture.selected.items);
}

fn styledFrame() anyerror!dvui.App.Result {
    var style = ng.Style.default;
    style.node.corner_radius = 0;
    style.node.shadow = null;
    style.edge.shadow = null;
    style.edge.color = .{ .r = 0xd0, .g = 0x40, .b = 0x40 };
    style.edge.thickness = 4;
    style.canvas.grid = null;
    style.canvas.vignette = null;
    _ = ng.declarative.graph(@src(), &decl, .{
        .nodes = &.{
            Decl.Add.nodeAt(1, "add", .{ .x = 20, .y = 20 }),
            Decl.Add.nodeAt(2, "add2", .{ .x = 260, .y = 120 }),
        },
        .edges = &.{.{ .source = .output(1, 0), .target = .input(2, 0) }},
        .graph = .{ .style = style },
    }, .{ .tag = "styled-graph" });
    return .ok;
}

test "style overrides render" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 }, .snapshot_dir = "snapshots" });
    defer t.deinit();
    decl = .{};
    try dvui.testing.settle(styledFrame);
    try dvui.testing.expectVisible("styled-graph");
    try snapshotIfImages(&t, @src(), styledFrame);
}

const demo = @import("demo");

fn demoFrame() anyerror!dvui.App.Result {
    return demo.frame();
}

fn demoNode(id: ng.NodeId) *demo.Node {
    for (demo.nodes.items) |*n| if (n.id == id) return n;
    unreachable;
}

test "demo: the add node's + adds inputs" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1000, .h = 700 }, .snapshot_dir = "snapshots" });
    defer t.deinit();
    try demo.init(t.window);
    defer demo.deinit(t.window);
    try dvui.testing.settle(demoFrame);

    // node 3 is the add node, starting with inputs a and b; its "+" is input 2
    const gid = dvui.tagGet("demo-graph").?.id;
    const cw = dvui.currentWindow();
    try std.testing.expectEqual(2, demoNode(3).arity);

    // clicking the + adds an input
    _ = try cw.addEventMouseMotion(.{ .pt = ng.GraphWidget.lastFrameSocket(gid, .input(3, 2)).?.center });
    _ = try dvui.testing.step(demoFrame);
    try dvui.testing.click(.left);
    try dvui.testing.settle(demoFrame);
    try std.testing.expectEqual(3, demoNode(3).arity);

    // wiring a number into the new + adds another input, linked
    const from = ng.GraphWidget.lastFrameSocket(gid, .output(1, 0)).?.center;
    const to = ng.GraphWidget.lastFrameSocket(gid, .input(3, 3)).?.center;
    _ = try cw.addEventMouseMotion(.{ .pt = from });
    _ = try dvui.testing.step(demoFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(demoFrame);
    for (0..2) |_| {
        _ = try cw.addEventMouseMotion(.{ .pt = to });
        _ = try dvui.testing.step(demoFrame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(demoFrame);
    try std.testing.expectEqual(4, demoNode(3).arity);
    var linked = false;
    for (demo.edges.items) |e| linked = linked or e.eql(.{ .source = .output(1, 0), .target = .input(3, 3) });
    try std.testing.expect(linked);
    try snapshotIfImages(&t, @src(), demoFrame);
}

fn clickTag(tag: []const u8) !void {
    try dvui.testing.moveTo(tag);
    _ = try dvui.testing.step(imperativeFrame);
    try dvui.testing.click(.left);
    try dvui.testing.settle(imperativeFrame);
}

test "click-to-link: click two sockets to link them; other clicks drop the selection" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();
    try dvui.testing.settle(imperativeFrame);

    try clickTag("out-1-0");
    try std.testing.expect(fx.selected_socket.?.eql(.output(1, 0)));
    try snapshotIfImages(&t, @src(), imperativeFrame);
    // hovering a socket it can link to previews the edge
    try dvui.testing.moveTo("in-2-0");
    try dvui.testing.settle(imperativeFrame);
    try snapshotIfImages(&t, @src(), imperativeFrame);

    try clickTag("in-2-0");
    try std.testing.expect(fx.selected_socket == null);
    try std.testing.expectEqual(1, fx.edges.items.len);
    try std.testing.expect(fx.edges.items[0].eql(.{ .source = .output(1, 0), .target = .input(2, 0) }));

    // a click on empty canvas drops the selection without linking
    try clickTag("out-2-0");
    try std.testing.expect(fx.selected_socket.?.eql(.output(2, 0)));
    const g = dvui.tagGet("graph").?.rect;
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = g.x + g.w - 20, .y = g.y + g.h - 20 } });
    _ = try dvui.testing.step(imperativeFrame);
    try dvui.testing.click(.left);
    try dvui.testing.settle(imperativeFrame);
    try std.testing.expect(fx.selected_socket == null);
    try std.testing.expectEqual(1, fx.edges.items.len);

    // escape cancels it too
    try clickTag("out-2-0");
    try dvui.testing.pressKey(.escape, .none);
    try dvui.testing.settle(imperativeFrame);
    try std.testing.expect(fx.selected_socket == null);
}
