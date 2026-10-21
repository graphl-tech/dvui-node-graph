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
const BaseNode = @import("BaseNode.zig");
const BaseSocket = @import("BaseSocket.zig");
const socket_row = @import("socket_row.zig");

const NodeId = types.NodeId;
const Sockets = types.Sockets;
const SocketId = types.SocketId;

pub const Node = struct {
    id: NodeId,
    title: ?[]const u8 = null,
    inputs: Sockets = .none(.input),
    outputs: Sockets = .none(.output),
    /// Initial position; afterwards `graph` remembers where the user dragged it.
    position: dvui.Point = .{},
};

/// A node "type" whose sockets come from the fields of two struct types.
pub fn NodeType(comptime Inputs: type, comptime Outputs: type) type {
    return struct {
        pub const inputs = types.socketsOfType(Inputs, .input);
        pub const outputs = types.socketsOfType(Outputs, .output);

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

pub fn Spec(comptime Ctx: type) type {
    return struct {
        nodes: []const Node,
        edges: []const types.Edge = &.{},
        graph: GraphWidget.InitOptions = .{},
        /// Replace the default title row.
        draw_node_title: ?*const fn (ctx: Ctx, node: *BaseNode, desc: Node) void = null,
        /// Replace the name label of an input row; draw into the row (it is the current parent).
        /// `name` is the socket's entry in `desc.inputs.names`.
        draw_input_label: ?*const fn (ctx: Ctx, row: *socket_row.BaseInput, desc: Node, name: []const u8) void = null,
        draw_output_label: ?*const fn (ctx: Ctx, row: *socket_row.BaseOutput, desc: Node, name: []const u8) void = null,
        /// Every event from every socket.
        on_socket_event: ?*const fn (ctx: Ctx, socket: SocketId, event: BaseSocket.Event) void = null,
        /// Shorthand for `on_socket_event` filtered to clicks.
        on_click_socket: ?*const fn (ctx: Ctx, socket: SocketId, click: BaseSocket.Click) void = null,
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

/// Render a whole graph from `spec`. Returns this frame's graph events (arena memory).
pub fn graph(src: std.builtin.SourceLocation, ctx: anytype, spec: Spec(@TypeOf(ctx)), opts: dvui.Options) []const GraphWidget.Event {
    var g = GraphWidget.init(src, spec.graph, opts);
    defer g.deinit();

    for (spec.nodes) |desc| {
        var n = BaseNode.init(@src(), g, desc.id, positionPtr(g, desc), .{}, .{});
        defer n.deinit();

        if (spec.draw_node_title) |f| f(ctx, n, desc) else if (desc.title) |t| n.titleLabel("{s}", .{t});

        inline for (.{ socket_row.BaseInput, socket_row.BaseOutput }, .{ desc.inputs, desc.outputs }, .{ spec.draw_input_label, spec.draw_output_label }) |Row, list, draw_label| {
            for (0..list.len()) |i| {
                var row = Row.initEx(@src(), n, list.socket(i).index, .{
                    .socket = .{ .style = list.style(i), .color = list.color(i) },
                }, .{ .id_extra = i });
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
                if (draw_label) |f| f(ctx, row, desc, list.names[i]) else dvui.label(@src(), "{s}", .{list.names[i]}, .{});
            }
        }
    }

    for (spec.edges) |edge| {
        if (g.linkEdge(edge, .{}).clicked) {
            if (spec.on_click_edge) |f| f(ctx, edge);
        }
    }

    const evs = g.events();
    if (spec.on_event) |f| for (evs) |e| f(ctx, e);
    return evs;
}

test {
    std.testing.refAllDecls(@This());
}
