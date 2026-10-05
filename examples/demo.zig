//! `zig build demo`
//!
//! Drag from a socket to wire it up, drop a wire on empty space to spawn a node, click an edge
//! to delete it, drag nodes (shift/ctrl-drag the canvas to box select), delete/backspace removes
//! the selection, scroll to zoom, drag the canvas to pan.

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

const Node = struct {
    id: ng.NodeId,
    kind: Kind,
    value: f32 = 0,
    initial_position: dvui.Point,
};

var nodes: std.ArrayList(Node) = .empty;
var edges: std.ArrayList(ng.Edge) = .empty;
var next_id: ng.NodeId = 1;
var use_declarative = false;

fn addNode(kind: Kind, p: dvui.Point) !ng.NodeId {
    const id = next_id;
    next_id += 1;
    try nodes.append(gpa, .{ .id = id, .kind = kind, .initial_position = p });
    return id;
}

fn init(win: *dvui.Window) !void {
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

fn deinit(win: *dvui.Window) void {
    _ = win;
    nodes.deinit(gpa);
    edges.deinit(gpa);
}

fn inputsOf(kind: Kind) ng.Ports {
    return switch (kind) {
        .number => .none(.input),
        .add => comptime ng.portsOfType(struct { a: f32, b: f32 }, .input),
        .print => .{ .side = .input, .names = &.{ "exec", "value" }, .kinds = &.{.flow} },
    };
}

fn outputsOf(kind: Kind) ng.Ports {
    return switch (kind) {
        .number, .add => comptime ng.portsOfType(struct { value: f32 }, .output),
        .print => .{ .side = .output, .names = &.{"then"}, .kinds = &.{.flow} },
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

fn frame() !dvui.App.Result {
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
    var graph = ng.graph(@src(), .{}, .{ .margin = .all(8) });
    defer graph.deinit();

    for (nodes.items) |*n| {
        var node = graph.node(@src(), n.id, inputsOf(n.kind), outputsOf(n.kind), .{
            .title = @tagName(n.kind),
            .default_position = n.initial_position,
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
            const res = dvui.textEntryNumber(@src(), f32, .{ .value = &n.value }, .{ .min_size_content = .{ .w = 50 } });
            _ = res;
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
        .link_created => |edge| {
            // an input accepts a single edge
            removeEdgesAt(edge.target);
            if (!hasEdge(edge)) try edges.append(gpa, edge);
        },
        .link_clicked => |edge| for (edges.items, 0..) |x, i| if (x.eql(edge)) {
            _ = edges.orderedRemove(i);
            break;
        },
        .link_dropped => |drop| {
            const id = try addNode(.add, drop.point);
            const edge = ng.Edge.normalized(drop.source, if (drop.source.side() == .output) .input(id, 0) else .output(id, 0));
            try edges.append(gpa, edge);
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
    for (nodes.items, decl_nodes) |n, *d| d.* = .{
        .id = n.id,
        .title = @tagName(n.kind),
        .inputs = inputsOf(n.kind),
        .outputs = outputsOf(n.kind),
        .position = n.initial_position,
    };
    _ = ng.declarative.graph(@src(), Ctx{}, .{
        .nodes = decl_nodes,
        .edges = edges.items,
        .on_event = Ctx.onEvent,
    }, .{ .margin = .all(8) });
}
