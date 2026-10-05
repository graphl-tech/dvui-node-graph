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
    node2_pos: dvui.Point = .{ .x = 260, .y = 140 },
    allow_same_side_links: bool = false,
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
        var node = graph.node(@src(), 1, struct { x: i32 }{ .x = 5 }, struct { s: []const u8 }{ .s = "" }, .{
            .title = "one",
            .default_position = .{ .x = 20, .y = 40 },
        }, .{ .tag = "node-1" });
        defer node.deinit();
        for (0..node.inputs.len()) |i| node.baseInput(@src(), i, .{ .id_extra = i });
        for (0..node.outputs.len()) |i| {
            var row = ng.BaseOutput.initEx(@src(), node, i, .{ .socket_opts = .{ .tag = "out-1-0" } }, .{ .id_extra = i });
            defer row.deinit();
            row.defaultLabel();
        }
    }

    graph.baseNodeEx(@src(), 3, struct { a: bool, b: f32 }{ .a = true, .b = 1.5 }, struct { c: u8 }{ .c = 0 }, .{
        .title = "three",
        .default_position = .{ .x = 20, .y = 220 },
    }, .{ .tag = "node-3" });

    {
        var node = graph.node(@src(), 2, struct { s: []const u8 }{ .s = "" }, struct { out: f32 }{ .out = 0 }, .{
            .title = "two",
            .position = &fx.node2_pos,
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

fn snapshotIfImages(t: *dvui.testing, src: std.builtin.SourceLocation, frame: dvui.App.frameFunction) !void {
    if (!@import("test_options").images) return;
    try std.Io.Dir.cwd().createDirPath(dvui.io, t.snapshot_dir);
    try t.snapshot(src, frame);
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
    var graph = ng.graph(@src(), .{}, .{});
    defer graph.deinit();

    // a node with default port rows
    graph.baseNode(@src(), 1, struct { x: i32 }{ .x = 5 }, struct { s: []const u8 }{ .s = "" });

    {
        var node = graph.node(@src(), 2, struct { s: []const u8 }{ .s = "" }, struct {}{}, .{ .title = "two" }, .{});
        defer node.deinit();

        for (0..node.inputs.len()) |i| {
            var row = ng.BaseInput.init(@src(), node, i, .{ .id_extra = i });
            defer row.deinit();
            // anything drawn here lands beside the socket
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
        .link_created => {}, // wire released on a compatible socket
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

/// A graph whose node 2 has a free-floating "+" slot that, when dragged, wires from input 5
/// (a socket that would be created on press in a real app).
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

    fn frame() anyerror!dvui.App.Result {
        var graph = ng.graph(@src(), .{ .selection = .{ .ctx = &dummy, .vtable = &vtable } }, .{});
        defer graph.deinit();

        graph.baseNodeEx(@src(), 1, struct {}{}, struct { out: i32 }{ .out = 0 }, .{ .default_position = .{ .x = 20, .y = 40 } }, .{ .tag = "pn-1" });
        {
            var node = graph.node(@src(), 2, struct { a: i32 }{ .a = 0 }, struct {}{}, .{ .default_position = .{ .x = 260, .y = 140 } }, .{ .tag = "pn-2" });
            defer node.deinit();
            node.baseInput(@src(), 0, .{});
            // floats left of the card, not part of the layout
            const card = node.card.data().borderRectScale().r;
            var plus = ng.BaseSocket.init(@src(), graph, .{ .node = 2, .socket = .input(7) }, .{
                .kind = .plus,
                .edge_overlap = false,
                .wire_source = .input(2, 5),
            }, .{ .rect = node.column.data().contentRectScale().rectFromPhysical(.{ .x = card.x - 30, .y = card.y, .w = 20, .h = 20 }), .tag = "plus" });
            plus.deinit();
        }
        for (graph.events()) |e| try events.append(std.testing.allocator, e);
        return .ok;
    }
};

test "a .plus socket's wire comes from its wire_source; selection can be caller-owned" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 } });
    defer t.deinit();
    defer PlusFixture.events.deinit(std.testing.allocator);
    defer PlusFixture.selected.deinit(std.testing.allocator);

    try dvui.testing.settle(PlusFixture.frame);
    try dvui.testing.expectVisible("plus");

    // drag from the "+" onto node 1's output
    const cw = dvui.currentWindow();
    var out_pt: dvui.Point.Physical = undefined;
    {
        const n1 = dvui.tagGet("pn-1").?.rect;
        out_pt = .{ .x = n1.x + n1.w, .y = n1.y + n1.h * 0.7 };
    }
    try dvui.testing.moveTo("plus");
    _ = try dvui.testing.step(PlusFixture.frame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(PlusFixture.frame);
    // find the output socket center by sweeping up the right edge of node 1
    var y = out_pt.y;
    var created: ?ng.Edge = null;
    while (y > out_pt.y - 40 and created == null) : (y -= 3) {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = out_pt.x - 6, .y = y } });
        _ = try dvui.testing.step(PlusFixture.frame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(PlusFixture.frame);
    var saw_wire = false;
    for (PlusFixture.events.items) |e| switch (e) {
        .link_created => |edge| {
            created = edge;
            saw_wire = true;
        },
        .link_dropped => |d| {
            try std.testing.expect(d.source.eql(.input(2, 5)));
            saw_wire = true;
        },
        else => {},
    };
    try std.testing.expect(saw_wire);
    // either way the wire came from the redirected source, never the "+" itself
    if (created) |edge| try std.testing.expect(edge.target.eql(.input(2, 5)));

    // clicking a node selects it through the caller's selection
    try dvui.testing.moveTo("pn-1");
    try dvui.testing.click(.left);
    try dvui.testing.settle(PlusFixture.frame);
    try std.testing.expectEqualSlices(ng.NodeId, &.{1}, PlusFixture.selected.items);
}
