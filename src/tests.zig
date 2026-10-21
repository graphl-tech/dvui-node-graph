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
    socket_events: std.ArrayList(struct { socket: ng.SocketId, event: ng.SocketWidget.Event }) = .empty,
    node1_pos: dvui.Point = .{ .x = 20, .y = 40 },
    node2_pos: dvui.Point = .{ .x = 260, .y = 140 },
    node3_pos: dvui.Point = .{ .x = 20, .y = 220 },
    allow_same_side_edges: bool = false,
    selected_socket: ?ng.SocketId = null,
    /// Copy of the last `nodes_moved` node list (event slices only live for one frame).
    moved_nodes: std.ArrayList(ng.NodeId) = .empty,
    /// The app's selection, kept up to date from graph events.
    selected: std.ArrayList(ng.NodeId) = .empty,

    fn deinit(self: *Fixture) void {
        self.selected.deinit(std.testing.allocator);
        self.edges.deinit(std.testing.allocator);
        self.events.deinit(std.testing.allocator);
        self.socket_events.deinit(std.testing.allocator);
        self.moved_nodes.deinit(std.testing.allocator);
        self.* = .{};
    }

    fn isSelected(self: *const Fixture, id: ng.NodeId) bool {
        return std.mem.indexOfScalar(ng.NodeId, self.selected.items, id) != null;
    }

    fn setSelected(self: *Fixture, id: ng.NodeId, on: bool) !void {
        const i = std.mem.indexOfScalar(ng.NodeId, self.selected.items, id);
        if (on and i == null) try self.selected.append(std.testing.allocator, id);
        if (!on) if (i) |at| {
            _ = self.selected.orderedRemove(at);
        };
    }

    fn applySelection(self: *Fixture, e: ng.GraphWidget.Event, all: []const ng.NodeId) !void {
        switch (e) {
            .select => |sel| switch (sel.mode) {
                .replace => {
                    self.selected.clearRetainingCapacity();
                    try self.setSelected(sel.node, true);
                },
                .add => try self.setSelected(sel.node, true),
                .remove => try self.setSelected(sel.node, false),
            },
            .select_all => for (all) |id| try self.setSelected(id, true),
            .deselect_all => self.selected.clearRetainingCapacity(),
            .box_select => |b| for (b.nodes) |id| try self.setSelected(id, b.mode == .include),
            else => {},
        }
    }

    fn hasEvent(self: *const Fixture, comptime tag: std.meta.Tag(ng.GraphWidget.Event)) ?ng.GraphWidget.Event {
        for (self.events.items) |e| if (e == tag) return e;
        return null;
    }
};

var fx: Fixture = .{};

fn graphFrame() anyerror!dvui.App.Result {
    const alloc = std.testing.allocator;
    var graph = ng.graph(@src(), .{ .view = &fx.view, .allow_same_side_edges = fx.allow_same_side_edges }, .{ .tag = "graph" });
    defer graph.deinit();

    {
        var node = graph.node(@src(), 1, &fx.node1_pos, .{ .selected = fx.isSelected(1) }, .{ .tag = "node-1" });
        defer node.deinit();
        dvui.label(@src(), "one", .{}, .{});
        var area = node.socketArea(@src(), .{});
        defer area.deinit();
        area.managedInput(@src(), 0, "x", .{});
        var row = ng.Output.initEx(@src(), area, 0, .{ .socket_opts = .{ .tag = "out-1-0" } }, .{});
        defer row.deinit();
        dvui.label(@src(), "s", .{}, .{});
    }

    graph.managedNode(@src(), 3, &fx.node3_pos, struct { a: bool, b: f32 }, struct { c: u8 }, .{
        .title = "three",
        .node = .{ .selected = fx.isSelected(3) },
    }, .{ .tag = "node-3" });

    {
        var node = graph.node(@src(), 2, &fx.node2_pos, .{ .selected = fx.isSelected(2) }, .{ .tag = "node-2" });
        defer node.deinit();
        dvui.label(@src(), "two", .{}, .{});
        var area = node.socketArea(@src(), .{});
        defer area.deinit();

        {
            var row = ng.Input.initEx(@src(), area, 0, .{ .socket_opts = .{ .tag = "in-2-0" } }, .{});
            defer row.deinit();
            dvui.labelNoFmt(@src(), "s", .{}, .{});

            for (row.events()) |e| switch (e) {
                .socket => |se| try fx.socket_events.append(alloc, .{ .socket = row.socketId(), .event = se }),
            };
        }
        {
            var row = ng.Output.initEx(@src(), area, 0, .{ .socket_opts = .{ .tag = "out-2-0" } }, .{});
            defer row.deinit();
            dvui.label(@src(), "out", .{}, .{});
        }
    }

    for (fx.edges.items) |e| _ = graph.link(e.source.node, e.source.socket, e.target.node, e.target.socket);

    defer fx.selected_socket = graph.selectedSocket();
    for (graph.events()) |e| {
        try fx.events.append(alloc, e);
        try fx.applySelection(e, &.{ 1, 2, 3 });
        switch (e) {
            .edge_created => |edge| try fx.edges.append(alloc, edge),
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

test "graph renders and remembers node positions" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(graphFrame);
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

    try dvui.testing.settle(graphFrame);
    const before = fx.node2_pos;

    try dvui.testing.moveTo("node-2");
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(graphFrame);
    const start = cw.mouse_pt;
    for (1..5) |i| {
        _ = try cw.addEventMouseMotion(.{ .pt = start.plus(.{ .x = @floatFromInt(i * 10), .y = @floatFromInt(i * 5) }) });
        _ = try dvui.testing.step(graphFrame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(graphFrame);

    // 40x20 physical pixels at zoom 1 is 40x20 natural pixels in graph space
    const s = cw.natural_scale;
    try std.testing.expectApproxEqAbs(before.x + 40 / s, fx.node2_pos.x, 0.01);
    try std.testing.expectApproxEqAbs(before.y + 20 / s, fx.node2_pos.y, 0.01);
    const moved = fx.hasEvent(.nodes_moved) orelse return error.NoNodesMoved;
    try std.testing.expectEqualSlices(ng.NodeId, &.{2}, fx.moved_nodes.items);
    try std.testing.expectApproxEqAbs(40 / s, moved.nodes_moved.delta.x, 0.01);
    try std.testing.expect(fx.hasEvent(.select) != null);
    try std.testing.expectEqualSlices(ng.NodeId, &.{2}, fx.selected.items);
}

test "box select previews while dragging and reports the boxed nodes on release" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(graphFrame);
    const cw = dvui.currentWindow();
    const graph_rect = dvui.tagGet("graph").?.rect;
    const n3 = dvui.tagGet("node-3").?.rect;

    // ctrl-drag from above-left of node 1 to inside node 3 (the left column)
    cw.mouse_pt = .{ .x = graph_rect.x + 4, .y = graph_rect.y + 4 };
    cw.modifiers = .lcontrol;
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(graphFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = n3.x + n3.w / 2, .y = n3.y + n3.h / 2 } });
    try dvui.testing.settle(graphFrame);
    // nodes 1 and 3 draw selected, but nothing is selected until release
    try snapshotIfImages(&t, @src(), graphFrame);
    try std.testing.expect(fx.selected.items.len == 0);

    _ = try cw.addEventMouseButton(.left, .release);
    cw.modifiers = .none;
    try dvui.testing.settle(graphFrame);
    const boxed = fx.hasEvent(.box_select) orelse return error.NoBoxSelect;
    try std.testing.expectEqual(ng.GraphWidget.BoxSelectMode.include, boxed.box_select.mode);
    std.mem.sort(ng.NodeId, fx.selected.items, {}, std.sort.asc(ng.NodeId));
    try std.testing.expectEqualSlices(ng.NodeId, &.{ 1, 3 }, fx.selected.items);
}

test "ctrl+a selects all and escape deselects" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(graphFrame);
    // focus the canvas
    const graph_rect = dvui.tagGet("graph").?.rect;
    dvui.currentWindow().mouse_pt = .{ .x = graph_rect.x + graph_rect.w - 10, .y = graph_rect.y + graph_rect.h - 10 };
    try dvui.testing.click(.left);
    try dvui.testing.settle(graphFrame);
    try std.testing.expect(fx.hasEvent(.deselect_all) == null);

    try dvui.testing.pressKey(.a, .lcontrol);
    try dvui.testing.settle(graphFrame);
    try std.testing.expectEqual(3, fx.selected.items.len);

    try dvui.testing.pressKey(.escape, .none);
    try dvui.testing.settle(graphFrame);
    try std.testing.expect(fx.hasEvent(.deselect_all) != null);
    try std.testing.expectEqual(0, fx.selected.items.len);
}

/// Press on `from_tag`, drag a preview edge onto `to_tag` and release.
fn dragPreviewEdge(t: *dvui.testing, from_tag: []const u8, to_tag: []const u8, src: std.builtin.SourceLocation) !void {
    const cw = dvui.currentWindow();
    const target = dvui.tagGet(to_tag).?.rect.center();
    try dvui.testing.moveTo(from_tag);
    _ = try dvui.testing.step(graphFrame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(graphFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = target.plus(.{ .x = -60, .y = 70 }) });
    _ = try dvui.testing.step(graphFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = target.plus(.{ .x = -60, .y = 70 }) });
    _ = try dvui.testing.step(graphFrame);
    try snapshotIfImages(t, src, graphFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = target });
    _ = try dvui.testing.step(graphFrame);
    _ = try cw.addEventMouseMotion(.{ .pt = target });
    _ = try dvui.testing.step(graphFrame);
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(graphFrame);
}

test "dragging a preview edge from an output onto an input creates an edge" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(graphFrame);
    try dragPreviewEdge(&t, "out-1-0", "in-2-0", @src());

    try std.testing.expectEqual(1, fx.edges.items.len);
    try std.testing.expect(fx.edges.items[0].eql(.{ .source = .output(1, 0), .target = .input(2, 0) }));
    try snapshotIfImages(&t, @src(), graphFrame);
}

test "output to output edges need allow_same_side_edges" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(graphFrame);
    try dragPreviewEdge(&t, "out-1-0", "out-2-0", @src());
    try std.testing.expectEqual(0, fx.edges.items.len);
    try std.testing.expect(fx.hasEvent(.preview_edge_dropped) != null);

    fx.allow_same_side_edges = true;
    try dvui.testing.settle(graphFrame);
    try dragPreviewEdge(&t, "out-1-0", "out-2-0", @src());
    try std.testing.expectEqual(1, fx.edges.items.len);
    try std.testing.expect(fx.edges.items[0].eql(.{ .source = .output(1, 0), .target = .output(2, 0) }));
    try snapshotIfImages(&t, @src(), graphFrame);
}

test "clicking a socket reports a socket click event" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(graphFrame);
    try dvui.testing.moveTo("in-2-0");
    try dvui.testing.click(.left);
    try dvui.testing.settle(graphFrame);

    var saw_click = false;
    for (fx.socket_events.items) |se| switch (se.event) {
        .mouse => |me| switch (me) {
            .click => saw_click = se.socket.eql(.input(2, 0)),
            .press => {},
        },
        .preview_edge => {},
    };
    try std.testing.expect(saw_click);
    try std.testing.expect(fx.hasEvent(.socket_clicked) != null);
}

test "dragging empty canvas pans and wheel zooms" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();

    try dvui.testing.settle(graphFrame);
    const cw = dvui.currentWindow();
    const empty: dvui.Point.Physical = blk: {
        const g = dvui.tagGet("graph").?.rect;
        break :blk .{ .x = g.x + g.w - 20, .y = g.y + g.h - 20 };
    };
    _ = try cw.addEventMouseMotion(.{ .pt = empty });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(graphFrame);
    for (1..4) |i| {
        _ = try cw.addEventMouseMotion(.{ .pt = empty.plus(.{ .x = -@as(f32, @floatFromInt(i * 10)), .y = 0 }) });
        _ = try dvui.testing.step(graphFrame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(graphFrame);
    try std.testing.expect(fx.view.origin.x > 10);

    const before = fx.view.scale;
    _ = try cw.addEventMouseWheel(120, .vertical, null);
    try dvui.testing.settle(graphFrame);
    try std.testing.expect(fx.view.scale != before);
}

/// Verbatim copy of the README's example, kept compiling.
fn readmeFrame() anyerror!dvui.App.Result {

    // node positions live in your model; dragging a node writes through its pointer
    const model = struct {
        var positions = [_]dvui.Point{ .{ .x = 20, .y = 40 }, .{ .x = 260, .y = 140 } };
        // can change from frame to frame
        var input_names: []const []const u8 = &.{ "a", "b" };
    };

    // start from the default style and override what you need
    var style = ng.Style.default;
    style.edge.shadow = null;
    style.node.corner_radius = 4;

    var graph = ng.graph(@src(), .{ .style = style }, .{});
    defer graph.deinit();

    // a title and a named row per field
    graph.managedNode(@src(), 1, &model.positions[0], struct { x: f32 }, struct { s: []const u8 }, .{ .title = "one" }, .{});

    // node that draws everything itself; its sockets are whatever rows it declares
    {
        var node = graph.node(@src(), 2, &model.positions[1], .{}, .{});
        defer node.deinit();
        {
            var header = node.header(@src(), .{});
            defer header.deinit();
            dvui.label(@src(), "two", .{}, .{});
        }

        {
            var area = node.socketArea(@src(), .{});
            defer area.deinit();
            for (model.input_names, 0..) |name, i| {
                var row = ng.Input.init(@src(), area, i, .{ .id_extra = i }); // socket .input(i)
                defer row.deinit();
                // anything drawn here is next to the socket
                dvui.label(@src(), "{s}", .{name}, .{});

                for (row.events()) |e| switch (e) {
                    .socket => |se| switch (se) {
                        .mouse => |me| switch (me) {
                            .click => |click| std.log.info("clicked at {any}", .{click.p}),
                            .press => {},
                        },
                        .preview_edge => |pe| switch (pe) {
                            .start => {},
                            .connect => |other| std.log.info("linked to {any}", .{other}),
                            .drop => |graph_point| std.log.info("dropped at {any}", .{graph_point}),
                        },
                    },
                };
            }
            area.managedOutput(@src(), 0, "out", .{}); // shorthand for an output with just a label
        }
        {
            var footer = node.footer(@src(), .{});
            defer footer.deinit();
            dvui.label(@src(), "below the sockets", .{}, .{});
        }
    }

    // edges go after the nodes that own their sockets
    _ = graph.link(1, .output(0), 2, .input(0)); // node 1's first output -> node 2's first input

    for (graph.events()) |e| switch (e) {
        .edge_created => {}, // preview edge released on a compatible socket (opposite sides: output -> input)
        .preview_edge_dropped => {}, // preview edge released on empty canvas, `.point` is graph space
        .edge_clicked => {},
        .nodes_moved => {}, // `.nodes` moved by `.delta`
        // the selection is yours: update it here and pass each node `.selected`
        .select, .select_all, .deselect_all, .box_select => {},
        .delete_selection => {},
        .context_menu => {}, // right click on canvas/node/socket
        else => {},
    };
    return .ok;
}

test "README example" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 } });
    defer t.deinit();
    try dvui.testing.settle(readmeFrame);
}

const ReserveFixture = struct {
    var positions = [_]dvui.Point{ .{ .x = 20, .y = 40 }, .{ .x = 200, .y = 40 } };
    var socket_capacity: usize = 0;
    var node_capacity: usize = 0;

    fn frame() anyerror!dvui.App.Result {
        var graph = ng.graph(@src(), .{}, .{});
        defer graph.deinit();
        socket_capacity = graph.sockets.capacity;
        node_capacity = graph.nodes.capacity;
        graph.managedNode(@src(), 1, &positions[0], struct { a: f32, b: f32 }, struct { c: f32 }, .{}, .{});
        graph.managedNode(@src(), 2, &positions[1], struct { a: f32 }, struct {}, .{}, .{});
        return .ok;
    }
};

test "a graph reserves last frame's sockets and nodes up front" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 } });
    defer t.deinit();
    try dvui.testing.settle(ReserveFixture.frame);
    try std.testing.expect(ReserveFixture.socket_capacity >= 4);
    try std.testing.expect(ReserveFixture.node_capacity >= 2);
}

/// A graph whose node 2 has a free-floating "+" socket for input 5, which it doesn't have yet.
const PlusFixture = struct {
    var events: std.ArrayList(ng.GraphWidget.Event) = .empty;
    /// The app ignores selection events, so nothing is ever selected.
    var positions = [_]dvui.Point{ .{ .x = 20, .y = 40 }, .{ .x = 260, .y = 140 } };

    fn frame() anyerror!dvui.App.Result {
        var graph = ng.graph(@src(), .{}, .{});
        defer graph.deinit();

        {
            var node = graph.node(@src(), 1, &positions[0], .{}, .{ .tag = "pn-1" });
            defer node.deinit();
            var area = node.socketArea(@src(), .{});
            defer area.deinit();
            var row = ng.Output.initEx(@src(), area, 0, .{ .socket_opts = .{ .tag = "pn-out" } }, .{});
            defer row.deinit();
            dvui.label(@src(), "out", .{}, .{});
        }
        {
            var node = graph.node(@src(), 2, &positions[1], .{}, .{ .tag = "pn-2" });
            defer node.deinit();
            var area = node.socketArea(@src(), .{});
            defer area.deinit();
            area.managedInput(@src(), 0, "a", .{});
            // floats left of the card, not part of the layout
            const card = node.card.data().borderRectScale().r;
            var plus = ng.SocketWidget.init(@src(), graph, .input(2, 5), .{
                .style = .{ .icon = .{ .name = "test_plus", .tvg = dvui.entypo.circle_with_plus } },
                .edge_overlap = false,
            }, .{ .rect = area.column.data().contentRectScale().rectFromPhysical(.{ .x = card.x - 30, .y = card.y, .w = 20, .h = 20 }), .tag = "plus" });
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

test "a socket the model doesn't have yet works both ways" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 } });
    defer t.deinit();
    defer PlusFixture.events.deinit(std.testing.allocator);

    try dvui.testing.settle(PlusFixture.frame);
    try dvui.testing.expectVisible("plus");

    const want: ng.Edge = .{ .source = .output(1, 0), .target = .input(2, 5) };
    for ([_][2][]const u8{ .{ "plus", "pn-out" }, .{ "pn-out", "plus" } }) |drag| {
        PlusFixture.events.clearRetainingCapacity();
        try dragBetween(drag[0], drag[1], PlusFixture.frame);
        var created: ?ng.Edge = null;
        for (PlusFixture.events.items) |e| if (e == .edge_created) {
            created = e.edge_created;
        };
        try std.testing.expect(created.?.eql(want));
    }

    // clicking a node reports it; the app decides whether it becomes selected
    PlusFixture.events.clearRetainingCapacity();
    try dvui.testing.moveTo("pn-1");
    try dvui.testing.click(.left);
    try dvui.testing.settle(PlusFixture.frame);
    var clicked: ?ng.NodeId = null;
    for (PlusFixture.events.items) |e| if (e == .select) {
        clicked = e.select.node;
    };
    try std.testing.expectEqual(1, clicked.?);

    // a node the app never selects still follows a drag that starts on it
    const before = PlusFixture.positions[1];
    try dvui.testing.moveTo("pn-2");
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(PlusFixture.frame);
    const start = cw.mouse_pt;
    for (1..3) |i| {
        _ = try cw.addEventMouseMotion(.{ .pt = start.plus(.{ .x = @floatFromInt(i * 10), .y = 0 }) });
        _ = try dvui.testing.step(PlusFixture.frame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(PlusFixture.frame);
    try std.testing.expect(PlusFixture.positions[1].x > before.x);
}

fn styledFrame() anyerror!dvui.App.Result {
    const positions = struct {
        var p = [_]dvui.Point{ .{ .x = 20, .y = 20 }, .{ .x = 260, .y = 120 } };
    };
    var style = ng.Style.default;
    style.node.corner_radius = 0;
    style.node.shadow = null;
    style.edge.shadow = null;
    style.edge.color = .{ .r = 0xd0, .g = 0x40, .b = 0x40 };
    style.edge.thickness = 4;
    style.canvas.grid = null;
    style.canvas.vignette = null;

    var graph = ng.graph(@src(), .{ .style = style }, .{ .tag = "styled-graph" });
    defer graph.deinit();
    graph.managedNode(@src(), 1, &positions.p[0], struct { a: i32, b: i32 }, struct { sum: i32 }, .{ .title = "add" }, .{});
    graph.managedNode(@src(), 2, &positions.p[1], struct { a: i32, b: i32 }, struct { sum: i32 }, .{ .title = "add2" }, .{});
    _ = graph.link(1, .output(0), 2, .input(0));
    return .ok;
}

test "style overrides render" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 600, .h = 400 }, .snapshot_dir = "snapshots" });
    defer t.deinit();
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
    try std.testing.expectEqual(2, demoNode(3).kind.add.arity);

    // clicking the + adds an input
    _ = try cw.addEventMouseMotion(.{ .pt = ng.GraphWidget.lastFrameSocket(gid, .input(3, 2)).?.center });
    _ = try dvui.testing.step(demoFrame);
    try dvui.testing.click(.left);
    try dvui.testing.settle(demoFrame);
    try std.testing.expectEqual(3, demoNode(3).kind.add.arity);

    // linking a number into the new + adds another input with the edge
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
    try std.testing.expectEqual(4, demoNode(3).kind.add.arity);
    var linked = false;
    for (demo.edges.items) |e| linked = linked or e.eql(.{ .source = .output(1, 0), .target = .input(3, 3) });
    try std.testing.expect(linked);
    try snapshotIfImages(&t, @src(), demoFrame);
}

fn clickTag(tag: []const u8) !void {
    try dvui.testing.moveTo(tag);
    _ = try dvui.testing.step(graphFrame);
    try dvui.testing.click(.left);
    try dvui.testing.settle(graphFrame);
}

test "click-to-link: click two sockets to link them; other clicks drop the selection" {
    var t = try initTest();
    defer t.deinit();
    defer fx.deinit();
    try dvui.testing.settle(graphFrame);

    try clickTag("out-1-0");
    try std.testing.expect(fx.selected_socket.?.eql(.output(1, 0)));
    try snapshotIfImages(&t, @src(), graphFrame);
    // hovering a socket it can link to previews the edge
    try dvui.testing.moveTo("in-2-0");
    try dvui.testing.settle(graphFrame);
    try snapshotIfImages(&t, @src(), graphFrame);

    try clickTag("in-2-0");
    try std.testing.expect(fx.selected_socket == null);
    try std.testing.expectEqual(1, fx.edges.items.len);
    try std.testing.expect(fx.edges.items[0].eql(.{ .source = .output(1, 0), .target = .input(2, 0) }));

    // a click on empty canvas drops the selection without linking
    try clickTag("out-2-0");
    try std.testing.expect(fx.selected_socket.?.eql(.output(2, 0)));
    const g = dvui.tagGet("graph").?.rect;
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = g.x + g.w - 20, .y = g.y + g.h - 20 } });
    _ = try dvui.testing.step(graphFrame);
    try dvui.testing.click(.left);
    try dvui.testing.settle(graphFrame);
    try std.testing.expect(fx.selected_socket == null);
    try std.testing.expectEqual(1, fx.edges.items.len);

    // escape cancels it too
    try clickTag("out-2-0");
    try dvui.testing.pressKey(.escape, .none);
    try dvui.testing.settle(graphFrame);
    try std.testing.expect(fx.selected_socket == null);
}
