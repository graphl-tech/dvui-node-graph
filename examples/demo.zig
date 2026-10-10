//! `zig build demo`
//!
//! Drag from a socket to wire it up, drop a wire on empty space to spawn a node, click an edge
//! to delete it, drag nodes (shift/ctrl-drag the canvas to box select), delete/backspace removes
//! the selection, scroll to zoom, drag the canvas to pan. "add" takes any number of inputs: wire
//! into (or click) its "+" to add one.

const std = @import("std");
const dvui = @import("dvui");
const ng = @import("dvui_node_graph");

pub const dvui_app: dvui.App = .{
    .config = .{ .options = .{
        .size = .{ .w = 1000, .h = 700 },
        .min_size = .{ .w = 300, .h = 300 },
        .title = "dvui-node-graph demo",
    } },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

const gpa = std.heap.smp_allocator;

const Kind = enum { number, add, print };

pub const Node = struct {
    id: ng.NodeId,
    kind: Kind,
    value: f32 = 0,
    /// Number of inputs of an `add` node.
    arity: u31 = 2,
    position: dvui.Point,
};

pub var nodes: std.ArrayList(Node) = .empty;
pub var edges: std.ArrayList(ng.Edge) = .empty;
var next_id: ng.NodeId = 1;
var use_declarative = false;

fn addNode(kind: Kind, p: dvui.Point) !ng.NodeId {
    const id = next_id;
    next_id += 1;
    try nodes.append(gpa, .{ .id = id, .kind = kind, .position = p });
    return id;
}

pub fn init(win: *dvui.Window) !void {
    _ = win;
    const a = try addNode(.number, .{ .x = 40, .y = 60 });
    const b = try addNode(.number, .{ .x = 40, .y = 220 });
    const c = try addNode(.add, .{ .x = 320, .y = 120 });
    const d = try addNode(.print, .{ .x = 580, .y = 140 });
    nodes.items[0].value = 2;
    nodes.items[1].value = 3;
    try edges.append(gpa, .{ .source = .output(a, 0), .target = .input(c, 0) });
    try edges.append(gpa, .{ .source = .output(b, 0), .target = .input(c, 1) });
    try edges.append(gpa, .{ .source = .output(c, 0), .target = .input(d, 1) });
}

pub fn deinit(win: *dvui.Window) void {
    _ = win;
    nodes.deinit(gpa);
    edges.deinit(gpa);
}

/// Execution-order sockets: an arrow in a ring, faded until connected.
const flow_socket: ng.Style.Socket = .{
    .icon = .{ .name = "demo_flow", .tvg = dvui.entypo.arrow_with_circle_right },
    .icon_connected = null,
    .unconnected_opacity = 0.4,
};

/// The socket an `add` node would add next: input `arity`, drawn as a "+". It is an ordinary
/// socket; `addEdge`/`handleEvent` create the input when a wire or click lands on it.
const plus_socket: ng.Style.Socket = .{
    .icon = .{ .name = "demo_plus", .tvg = dvui.entypo.circle_with_plus },
    .icon_connected = null,
    .unconnected_opacity = 0.6,
};

const letters = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };

fn inputsOf(n: *const Node) !ng.Ports {
    return switch (n.kind) {
        .number => .none(.input),
        .add => blk: {
            const arena = dvui.currentWindow().arena();
            const count = @min(n.arity, letters.len);
            const names = try arena.alloc([]const u8, count + 1);
            const styles = try arena.alloc(?ng.Style.Socket, count + 1);
            for (names[0..count], styles[0..count], letters[0..count]) |*name, *st, l| {
                name.* = l;
                st.* = null;
            }
            names[count] = "";
            styles[count] = plus_socket;
            break :blk .{ .side = .input, .names = names, .styles = styles };
        },
        .print => .{ .side = .input, .names = &.{ "exec", "value" }, .styles = &.{flow_socket} },
    };
}

fn nodeById(id: ng.NodeId) ?*Node {
    for (nodes.items) |*n| if (n.id == id) return n;
    return null;
}

/// Grow an `add` node so that its input `index` exists.
fn ensureInput(s: ng.SocketId) void {
    if (s.side() != .input) return;
    const n = nodeById(s.node) orelse return;
    if (n.kind == .add and s.socket.index >= n.arity) n.arity = @min(s.socket.index + 1, letters.len);
}

fn addEdge(edge: ng.Edge) !void {
    ensureInput(edge.source);
    ensureInput(edge.target);
    // an input accepts a single edge
    removeEdgesAt(edge.target);
    if (!hasEdge(edge)) try edges.append(gpa, edge);
}

fn outputsOf(kind: Kind) ng.Ports {
    return switch (kind) {
        .number, .add => comptime ng.portsOfType(struct { value: f32 }, .output),
        .print => .{ .side = .output, .names = &.{"then"}, .styles = &.{flow_socket} },
    };
}

fn removeNode(id: ng.NodeId) void {
    for (nodes.items, 0..) |n, i| if (n.id == id) {
        _ = nodes.orderedRemove(i);
        break;
    };
    var i: usize = 0;
    while (i < edges.items.len) {
        const e = edges.items[i];
        if (e.source.node == id or e.target.node == id) _ = edges.orderedRemove(i) else i += 1;
    }
}

fn hasEdge(edge: ng.Edge) bool {
    for (edges.items) |e| if (e.eql(edge)) return true;
    return false;
}

pub fn frame() !dvui.App.Result {
    {
        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(4) });
        defer bar.deinit();
        dvui.label(@src(), "{d} nodes, {d} edges", .{ nodes.items.len, edges.items.len }, .{ .gravity_y = 0.5 });
        _ = dvui.checkbox(@src(), &use_declarative, "declarative API", .{ .gravity_x = 1.0 });
    }

    if (use_declarative) try declarativeGraph() else try imperativeGraph();
    return .ok;
}

fn imperativeGraph() !void {
    var graph = ng.graph(@src(), .{}, .{ .margin = .all(8), .tag = "demo-graph" });
    defer graph.deinit();

    for (nodes.items) |*n| {
        var node = graph.node(@src(), n.id, &n.position, try inputsOf(n), outputsOf(n.kind), .{
            .title = @tagName(n.kind),
        }, .{});
        defer node.deinit();

        for (0..node.inputs.len()) |i| {
            var row = ng.BaseInput.init(@src(), node, i, .{ .id_extra = i });
            defer row.deinit();
            row.defaultLabel();

            for (row.events()) |e| switch (e) {
                .socket => |se| switch (se) {
                    // clicking a connected input disconnects it
                    .mouse => |me| switch (me) {
                        .click => removeEdgesAt(row.socketId()),
                        else => {},
                    },
                    else => {},
                },
            };
        }

        if (n.kind == .number) {
            var row = ng.BaseOutput.init(@src(), node, 0, .{});
            defer row.deinit();
            // narrower than dvui's default; a plain .min_size_content would also cap the height
            _ = dvui.textEntryNumber(@src(), f32, .{ .value = &n.value }, (dvui.Options{ .gravity_y = 0.5 }).min_sizeM(5, 1));
        } else {
            for (0..node.outputs.len()) |i| node.baseOutput(@src(), i, .{ .id_extra = i });
        }
    }

    for (edges.items) |e| _ = graph.link(e.source.node, e.source.socket, e.target.node, e.target.socket);

    for (graph.events()) |e| try handleEvent(graph, e);
}

fn removeEdgesAt(s: ng.SocketId) void {
    var i: usize = 0;
    while (i < edges.items.len) {
        const e = edges.items[i];
        if (e.source.eql(s) or e.target.eql(s)) _ = edges.orderedRemove(i) else i += 1;
    }
}

fn handleEvent(graph: ?*ng.GraphWidget, e: ng.GraphWidget.Event) !void {
    switch (e) {
        .link_created => |edge| try addEdge(edge),
        .socket_clicked => |s| ensureInput(s),
        .link_clicked => |edge| for (edges.items, 0..) |x, i| if (x.eql(edge)) {
            _ = edges.orderedRemove(i);
            break;
        },
        .link_dropped => |drop| {
            const id = try addNode(.add, drop.point);
            try addEdge(ng.Edge.normalized(drop.source, if (drop.source.side() == .output) .input(id, 0) else .output(id, 0)));
        },
        .delete_selection => if (graph) |g| {
            for (g.selectedNodes()) |id| removeNode(id);
            g.clearSelection();
        },
        .context_menu => |cm| if (cm.target == .canvas) {
            _ = try addNode(.number, cm.point);
        },
        else => {},
    }
}

const Ctx = struct {
    fn onEvent(_: Ctx, e: ng.GraphWidget.Event) void {
        handleEvent(null, e) catch {};
    }
};

fn declarativeGraph() !void {
    const arena = dvui.currentWindow().arena();
    const decl_nodes = try arena.alloc(ng.declarative.Node, nodes.items.len);
    for (nodes.items, decl_nodes) |*n, *d| d.* = .{
        .id = n.id,
        .title = @tagName(n.kind),
        .inputs = try inputsOf(n),
        .outputs = outputsOf(n.kind),
        .position = n.position,
    };
    _ = ng.declarative.graph(@src(), Ctx{}, .{
        .nodes = decl_nodes,
        .edges = edges.items,
        .on_event = Ctx.onEvent,
    }, .{ .margin = .all(8) });
}
