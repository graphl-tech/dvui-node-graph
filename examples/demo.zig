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

const Kind = union(enum) {
    number: struct { value: f32 = 0 },
    /// `arity` is its number of inputs.
    add: struct { arity: u31 = 2 },
    print,
};

pub const Node = struct {
    id: ng.NodeId,
    kind: Kind,
    position: dvui.Point,
    selected: bool = false,
};

pub var nodes: std.ArrayList(Node) = .empty;
pub var edges: std.ArrayList(ng.Edge) = .empty;
var next_id: ng.NodeId = 1;

fn addNode(kind: Kind, p: dvui.Point) !ng.NodeId {
    const id = next_id;
    next_id += 1;
    try nodes.append(gpa, .{ .id = id, .kind = kind, .position = p });
    return id;
}

pub fn init(win: *dvui.Window) !void {
    _ = win;
    const a = try addNode(.{ .number = .{ .value = 2 } }, .{ .x = 40, .y = 60 });
    const b = try addNode(.{ .number = .{ .value = 3 } }, .{ .x = 40, .y = 220 });
    const c = try addNode(.{ .add = .{} }, .{ .x = 320, .y = 120 });
    const d = try addNode(.print, .{ .x = 580, .y = 140 });
    try edges.append(gpa, .{ .source = .output(a, 0), .target = .input(c, 0) });
    try edges.append(gpa, .{ .source = .output(b, 0), .target = .input(c, 1) });
    try edges.append(gpa, .{ .source = .output(c, 0), .target = .input(d, 1) });
}

pub fn deinit(win: *dvui.Window) void {
    _ = win;
    nodes.deinit(gpa);
    edges.deinit(gpa);
}

const flow_socket: ng.Style.Socket = .{
    .icon = .{ .name = "demo_flow", .tvg = dvui.entypo.arrow_with_circle_right },
    .icon_connected = null,
    .unconnected_opacity = 0.4,
};

const plus_socket: ng.Style.Socket = .{
    .icon = .{ .name = "demo_plus", .tvg = dvui.entypo.circle_with_plus },
    .icon_connected = null,
    .unconnected_opacity = 0.6,
};

const letters = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };

/// One side's socket rows, in socket order.
const Rows = struct {
    names: []const []const u8 = &.{},
    /// Shorter than `names` to use the graph's style for the rest.
    styles: []const ?ng.Style.Socket = &.{},

    fn style(self: Rows, i: usize) ?ng.Style.Socket {
        return if (i < self.styles.len) self.styles[i] else null;
    }
};

fn inputsOf(n: *const Node) !Rows {
    return switch (n.kind) {
        .number => .{},
        .add => |add| blk: {
            const arena = dvui.currentWindow().arena();
            const count = @min(add.arity, letters.len);
            const names = try arena.alloc([]const u8, count + 1);
            const styles = try arena.alloc(?ng.Style.Socket, count + 1);
            for (names[0..count], styles[0..count], letters[0..count]) |*name, *st, l| {
                name.* = l;
                st.* = null;
            }
            names[count] = "";
            styles[count] = plus_socket;
            break :blk .{ .names = names, .styles = styles };
        },
        .print => .{ .names = &.{ "exec", "value" }, .styles = &.{flow_socket} },
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
    switch (n.kind) {
        .add => |*add| if (s.socket.index >= add.arity) {
            add.arity = @min(s.socket.index + 1, letters.len);
        },
        else => {},
    }
}

fn addEdge(edge: ng.Edge) !void {
    ensureInput(edge.source);
    ensureInput(edge.target);
    // an input accepts a single edge
    removeEdgesAt(edge.target);
    if (!hasEdge(edge)) try edges.append(gpa, edge);
}

fn outputsOf(kind: Kind) Rows {
    return switch (kind) {
        .number, .add => .{ .names = &.{"value"} },
        .print => .{ .names = &.{"then"}, .styles = &.{flow_socket} },
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
    }

    try drawGraph();
    return .ok;
}

fn drawGraph() !void {
    var graph = ng.graph(@src(), .{}, .{ .margin = .all(8), .tag = "demo-graph" });
    defer graph.deinit();

    for (nodes.items) |*n| {
        var node = graph.node(@src(), n.id, &n.position, .{ .selected = n.selected }, .{});
        defer node.deinit();

        {
            var header = node.header(@src(), .{});
            defer header.deinit();
            dvui.label(@src(), "{s}", .{@tagName(n.kind)}, .{});
        }

        {
            var area = node.socketArea(@src(), .{});
            defer area.deinit();

            const ins = try inputsOf(n);
            for (ins.names, 0..) |name, i| {
                var row = ng.ManagedInput.initEx(@src(), area, i, .{ .socket = .{ .style = ins.style(i) } }, .{ .id_extra = i });
                defer row.deinit();
                dvui.label(@src(), "{s}", .{name}, .{});

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

            switch (n.kind) {
                .number => |*number| {
                    var row = ng.ManagedOutput.init(@src(), area, 0, .{});
                    defer row.deinit();
                    _ = dvui.textEntryNumber(@src(), f32, .{ .value = &number.value }, (dvui.Options{ .gravity_y = 0.5 }));
                },
                .add, .print => {
                    const outs = outputsOf(n.kind);
                    for (outs.names, 0..) |name, i| {
                        var row = ng.ManagedOutput.initEx(@src(), area, i, .{ .socket = .{ .style = outs.style(i) } }, .{ .id_extra = i });
                        defer row.deinit();
                        dvui.label(@src(), "{s}", .{name}, .{});
                    }
                },
            }
        }
        {
            var footer = node.footer(@src(), .{});
            defer footer.deinit();
            dvui.label(@src(), "FOOTER", .{}, .{});
        }
    }

    for (edges.items) |e| _ = graph.link(e.source.node, e.source.socket, e.target.node, e.target.socket);

    for (graph.events()) |e| {
        switch (e) {
            .link_created => |edge| try addEdge(edge),
            .socket_clicked => |s| ensureInput(s),
            .link_clicked => |edge| for (edges.items, 0..) |x, i| if (x.eql(edge)) {
                _ = edges.orderedRemove(i);
                break;
            },
            .link_dropped => |drop| {
                const id = try addNode(.{ .add = .{} }, drop.point);
                try addEdge(ng.Edge.normalized(drop.source, if (drop.source.side() == .output) .input(id, 0) else .output(id, 0)));
            },
            .select => |sel| for (nodes.items) |*n| switch (sel.mode) {
                .replace => n.selected = n.id == sel.node,
                .add => if (n.id == sel.node) {
                    n.selected = true;
                },
                .remove => if (n.id == sel.node) {
                    n.selected = false;
                },
            },
            .select_all => for (nodes.items) |*n| {
                n.selected = true;
            },
            .deselect_all => for (nodes.items) |*n| {
                n.selected = false;
            },
            .box_select => |b| for (nodes.items) |*n| {
                if (std.mem.indexOfScalar(ng.NodeId, b.nodes, n.id) != null) n.selected = b.mode == .include;
            },
            .delete_selection => {
                var i = nodes.items.len;
                while (i > 0) {
                    i -= 1;
                    if (nodes.items[i].selected) removeNode(nodes.items[i].id);
                }
            },
            .context_menu => |cm| if (cm.target == .canvas) {
                _ = try addNode(.{ .number = .{} }, cm.point);
            },
            else => {},
        }
    }
}

fn removeEdgesAt(s: ng.SocketId) void {
    var i: usize = 0;
    while (i < edges.items.len) {
        const e = edges.items[i];
        if (e.source.eql(s) or e.target.eql(s)) _ = edges.orderedRemove(i) else i += 1;
    }
}
