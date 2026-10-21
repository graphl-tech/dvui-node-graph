//! Declarative wrapper: describe nodes and edges as data, customize with callbacks.
//!
//! ```zig
//! const Add = dvui_node_graph.declarative.NodeType(struct { a: i32, b: i32 }, struct { sum: i32 });
//! const events = dvui_node_graph.declarative.graph(@src(), &my_app, .{
//!     .nodes = &.{ Add.node(1, "add"), Add.node(2, "add") },
//!     .edges = &.{ .{ .source = .output(1, 0), .target = .input(2, 0) } },
//!     .on_click_socket = MyApp.onClickSocket,
//! }, .{});
//! ```

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const GraphWidget = @import("GraphWidget.zig");
const ManagedNode = @import("ManagedNode.zig");
const ManagedSocket = @import("ManagedSocket.zig");
const socket_row = @import("socket_row.zig");

const NodeId = types.NodeId;
const SocketId = types.SocketId;

pub const Node = struct {
    id: NodeId,
    title: ?[]const u8 = null,
    /// One named row per socket: socket `i` of a side is `(side, i)`.
    inputs: []const []const u8 = &.{},
    outputs: []const []const u8 = &.{},
    /// Initial position; afterwards `graph` remembers where the user dragged it.
    position: dvui.Point = .{},
};

/// A node "type" whose sockets come from the fields of two struct types.
pub fn NodeType(comptime Inputs: type, comptime Outputs: type) type {
    return struct {
        pub const inputs = fieldNames(Inputs);
        pub const outputs = fieldNames(Outputs);

        pub fn node(id: NodeId, title: ?[]const u8) Node {
            return .{ .id = id, .title = title, .inputs = inputs, .outputs = outputs };
        }

        pub fn nodeAt(id: NodeId, title: ?[]const u8, position: dvui.Point) Node {
            var n = node(id, title);
            n.position = position;
            return n;
        }
    };
}

fn fieldNames(comptime T: type) []const []const u8 {
    const names = comptime blk: {
        const src = std.meta.fieldNames(T);
        var out: [src.len][]const u8 = undefined;
        for (src, &out) |n, *o| o.* = n;
        break :blk out;
    };
    return &names;
}

pub fn Spec(comptime Ctx: type) type {
    return struct {
        nodes: []const Node,
        edges: []const types.Edge = &.{},
        graph: GraphWidget.InitOptions = .{},
        /// Replace the default title row.
        draw_node_title: ?*const fn (ctx: Ctx, node: *ManagedNode, desc: Node) void = null,
        /// Replace the name label of an input row; draw into the row (it is the current parent).
        /// `name` is the socket's entry in `desc.inputs`.
        draw_input_label: ?*const fn (ctx: Ctx, row: *socket_row.ManagedInput, desc: Node, name: []const u8) void = null,
        draw_output_label: ?*const fn (ctx: Ctx, row: *socket_row.ManagedOutput, desc: Node, name: []const u8) void = null,
        /// Every event from every socket.
        on_socket_event: ?*const fn (ctx: Ctx, socket: SocketId, event: ManagedSocket.Event) void = null,
        /// Shorthand for `on_socket_event` filtered to clicks.
        on_click_socket: ?*const fn (ctx: Ctx, socket: SocketId, click: ManagedSocket.Click) void = null,
        /// Every graph-level event (`link_created`, `nodes_moved`, ...).
        on_event: ?*const fn (ctx: Ctx, event: GraphWidget.Event) void = null,
        /// Called for each edge that was clicked (also reported through `on_event`).
        on_click_edge: ?*const fn (ctx: Ctx, edge: types.Edge) void = null,
    };
}

/// Dragged position of `desc`, kept in dvui's data store under the graph. dvui frees entries
/// that go a frame without use, so a node left out for a frame comes back at `desc.position`.
fn positionPtr(g: *GraphWidget, desc: Node) *dvui.Point {
    const key = g.id().update(std.mem.asBytes(&desc.id));
    return dvui.dataGetPtrDefault(null, key, "_pos", dvui.Point, desc.position);
}

/// Apply a selection event to `sel`, the selected node ids.
fn applySelection(sel: *std.ArrayList(NodeId), e: GraphWidget.Event, nodes: []const Node) void {
    const a = dvui.currentWindow().arena();
    switch (e) {
        .select => |s| switch (s.mode) {
            .replace => {
                sel.clearRetainingCapacity();
                sel.append(a, s.node) catch {};
            },
            .add => setSelected(sel, s.node, true),
            .remove => setSelected(sel, s.node, false),
        },
        .select_all => {
            sel.clearRetainingCapacity();
            for (nodes) |n| sel.append(a, n.id) catch {};
        },
        .deselect_all => sel.clearRetainingCapacity(),
        .box_select => |b| for (b.nodes) |n| setSelected(sel, n, b.mode == .include),
        else => {},
    }
}

fn setSelected(sel: *std.ArrayList(NodeId), id: NodeId, selected: bool) void {
    const i = std.mem.indexOfScalar(NodeId, sel.items, id);
    if (selected and i == null) sel.append(dvui.currentWindow().arena(), id) catch {};
    if (!selected) if (i) |at| {
        _ = sel.orderedRemove(at);
    };
}

/// Render a whole graph from `spec`. Returns this frame's graph events (arena memory).
pub fn graph(src: std.builtin.SourceLocation, ctx: anytype, spec: Spec(@TypeOf(ctx)), opts: dvui.Options) []const GraphWidget.Event {
    var g = GraphWidget.init(src, spec.graph, opts);
    defer g.deinit();

    // selection is kept in dvui's data store, like dragged positions
    var sel: std.ArrayList(NodeId) = .empty;
    sel.appendSlice(dvui.currentWindow().arena(), dvui.dataGetSlice(null, g.id(), "_selection", []NodeId) orelse &.{}) catch {};

    for (spec.nodes) |desc| {
        const selected = std.mem.indexOfScalar(NodeId, sel.items, desc.id) != null;
        var n = ManagedNode.init(@src(), g, desc.id, positionPtr(g, desc), .{ .selected = selected }, .{});
        defer n.deinit();

        if (spec.draw_node_title) |f| f(ctx, n, desc) else if (desc.title) |t| {
            dvui.labelEx(@src(), "{s}", .{t}, .{ .ellipsize = false }, .{ .padding = .all(2), .expand = .horizontal });
        }

        var area = n.socketArea(@src(), .{});
        defer area.deinit();
        inline for (.{ socket_row.ManagedInput, socket_row.ManagedOutput }, .{ desc.inputs, desc.outputs }, .{ spec.draw_input_label, spec.draw_output_label }) |Row, names, draw_label| {
            for (names, 0..) |name, i| {
                var row = Row.init(@src(), area, i, .{ .id_extra = i });
                defer row.deinit();
                for (row.events()) |e| switch (e) {
                    .socket => |se| {
                        if (spec.on_socket_event) |f| f(ctx, row.socketId(), se);
                        if (spec.on_click_socket) |f| switch (se) {
                            .mouse => |me| switch (me) {
                                .click => |c| f(ctx, row.socketId(), c),
                                .press => {},
                            },
                            .wire => {},
                        };
                    },
                };
                if (draw_label) |f| f(ctx, row, desc, name) else dvui.label(@src(), "{s}", .{name}, .{});
            }
        }
    }

    for (spec.edges) |edge| {
        if (g.linkEdge(edge, .{}).clicked) {
            if (spec.on_click_edge) |f| f(ctx, edge);
        }
    }

    const evs = g.events();
    for (evs) |e| applySelection(&sel, e, spec.nodes);
    dvui.dataSetSlice(null, g.id(), "_selection", sel.items);
    if (spec.on_event) |f| for (evs) |e| f(ctx, e);
    return evs;
}

test {
    std.testing.refAllDecls(@This());
}
