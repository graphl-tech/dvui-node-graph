//! A draggable, selectable node. Its sockets are whatever rows you declare with
//! `BaseInput`/`BaseOutput` (or `defaultSockets` for a `Sockets` description). Inputs stack in a
//! left column and outputs in a right column; declare all inputs before any outputs.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const GraphWidget = @import("GraphWidget.zig");
const draw = @import("draw.zig");
const Style = @import("Style.zig");
const socket_row = @import("socket_row.zig");

const NodeId = types.NodeId;
const Sockets = types.Sockets;

const BaseNode = @This();

pub const InitOptions = struct {
    title: ?[]const u8 = null,
    draggable: bool = true,
    selectable: bool = true,
    /// Overrides the graph's `style.node` for this node.
    style: ?Style.Node = null,
    /// Apply this frame's drag delta to the position. Turn off to apply moves yourself from
    /// `GraphWidget.node_drag_delta` (e.g. to route them through an undo system).
    apply_drag: bool = true,
};

graph: *GraphWidget,
id: NodeId,
init_opts: InitOptions,
position: *dvui.Point,
selected: bool,
/// Mouse was over this (topmost) node last frame.
hovered: bool,

front_to_back: dvui.RenderFrontToBack = undefined,
card: dvui.BoxWidget = undefined,
body: dvui.BoxWidget = undefined,
column: dvui.BoxWidget = undefined,
column_side: ?types.Side = null,

/// `position` is the node's top-left corner in graph space. It must outlive the frame: dragging
/// the node writes through it.
pub fn init(
    src: std.builtin.SourceLocation,
    graph: *GraphWidget,
    id: NodeId,
    position: *dvui.Point,
    init_opts: InitOptions,
    opts: dvui.Options,
) *BaseNode {
    const self = dvui.widgetAlloc(BaseNode);
    self.initInPlace(src, graph, id, position, init_opts, opts);
    return self;
}

/// It's expected to call this when `self` is `undefined`.
pub fn initInPlace(
    self: *BaseNode,
    src: std.builtin.SourceLocation,
    graph: *GraphWidget,
    id: NodeId,
    position: *dvui.Point,
    init_opts: InitOptions,
    opts: dvui.Options,
) void {
    graph.assertCanDeclare();
    self.* = .{
        .graph = graph,
        .id = id,
        .init_opts = init_opts,
        .position = position,
        .selected = graph.isSelected(id),
        .hovered = if (graph.hover_node) |h| h == id else false,
    };

    if (self.selected and init_opts.draggable and init_opts.apply_drag) {
        self.position.* = self.position.plus(graph.node_drag_delta);
    }

    // First node declared draws on top and gets events first.
    self.front_to_back.init();

    const ns = init_opts.style orelse graph.style().node;
    const theme = dvui.themeGet();
    const base_fill = ns.fill orelse theme.color(.window, .fill);
    const fill = if (self.selected)
        ns.fill_selected orelse base_fill.lerp(theme.color(.highlight, .fill), 0.12)
    else if (self.hovered)
        ns.fill_hover orelse base_fill.lerp(Style.text(), 0.06)
    else
        base_fill;
    const border = if (self.selected)
        ns.border_selected orelse theme.focus
    else if (self.hovered)
        ns.border_hover orelse Style.text().lerp(theme.border, 0.3)
    else
        ns.border orelse theme.border;

    var shadow = ns.shadow;
    if (shadow) |*sh| {
        if (sh.corners == null) sh.corners = .all(ns.corner_radius);
    }

    const defaults: dvui.Options = .{
        .name = "Node",
        .rect = .{ .x = @round(self.position.x), .y = @round(self.position.y) },
        .id_extra = @intCast(id),
        .margin = .all(ns.padding),
        .padding = .all(ns.padding),
        .corners = .all(ns.corner_radius),
        .background = true,
        .border = .all(ns.border_width),
        .color_fill = draw.paint(fill.opacity(ns.fill_opacity)),
        .color_border = draw.paint(border),
        .min_size_content = .{ .w = 60, .h = 10 },
        .box_shadow = shadow,
    };
    self.card.init(src, .{ .dir = .vertical }, defaults.override(opts));
    self.card.drawBackground();

    if (init_opts.title) |t| self.titleLabel("{s}", .{t});
}

/// Draw a title row. Anything drawn into the node before its first socket row stacks above the rows.
pub fn titleLabel(self: *BaseNode, comptime fmt: []const u8, args: anytype) void {
    std.debug.assert(self.column_side == null);
    dvui.labelEx(@src(), fmt, args, .{ .ellipsize = false }, .{
        .padding = .all(2),
        .expand = .horizontal,
    });
}

/// Make the column for `side` the current parent. Used by `BaseInput`/`BaseOutput`.
pub fn beginColumn(self: *BaseNode, side: types.Side) void {
    if (self.column_side) |s| {
        if (s == side) return;
        if (s == .output) {
            dvui.log.err("dvui_node_graph: node {d} declared an input after its outputs", .{self.id});
        }
        self.column.deinit();
    } else {
        self.body.init(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    }
    self.column.init(@src(), .{ .dir = .vertical }, .{
        .gravity_x = if (side == .output) 1 else 0,
        .id_extra = @intFromEnum(side),
    });
    self.column_side = side;
}

/// Render a row showing its name for every socket in `inputs` and `outputs`.
pub fn defaultSockets(self: *BaseNode, inputs: Sockets, outputs: Sockets) void {
    self.namedRows(.input, inputs);
    self.namedRows(.output, outputs);
}

fn namedRows(self: *BaseNode, comptime side: types.Side, ss: Sockets) void {
    std.debug.assert(ss.side == side);
    for (0..ss.len()) |i| {
        var w = socket_row.SocketRow(side).initEx(@src(), self, ss.socket(i).index, .{
            .socket = .{ .style = ss.style(i), .color = ss.color(i) },
        }, .{ .id_extra = i });
        defer w.deinit();
        dvui.label(@src(), "{s}", .{ss.names[i]}, .{});
    }
}

/// Row for input socket `index` showing `name`.
pub fn baseInput(self: *BaseNode, src: std.builtin.SourceLocation, index: usize, name: []const u8, opts: dvui.Options) void {
    var w = socket_row.BaseInput.init(src, self, index, opts);
    defer w.deinit();
    dvui.label(@src(), "{s}", .{name}, .{});
}

/// Row for output socket `index` showing `name`.
pub fn baseOutput(self: *BaseNode, src: std.builtin.SourceLocation, index: usize, name: []const u8, opts: dvui.Options) void {
    var w = socket_row.BaseOutput.init(src, self, index, opts);
    defer w.deinit();
    dvui.label(@src(), "{s}", .{name}, .{});
}

pub fn data(self: *BaseNode) *dvui.WidgetData {
    return self.card.data();
}

fn processEvents(self: *BaseNode) void {
    if (!self.graph.interactive()) return;
    const wd = self.card.data();
    const graph = self.graph;
    for (dvui.events()) |*e| {
        if (!self.card.matchEvent(e) or e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .focus => {
                e.handle(@src(), wd);
                dvui.focusWidget(graph.id(), null, e.num);
            },
            .press => {
                // Right clicks are left for the graph's context menu handling.
                if (!me.button.pointer()) continue;
                e.handle(@src(), wd);
                if (self.init_opts.selectable) {
                    if (me.mod.shift()) {
                        graph.select(self.id, .remove);
                    } else if (me.mod.matchBind("ctrl/cmd")) {
                        graph.select(self.id, .add);
                    } else if (!self.selected) {
                        graph.select(self.id, .replace);
                    }
                }
                if (self.init_opts.draggable) {
                    dvui.captureMouse(wd, e.num);
                    dvui.dragPreStart(me.button, me.p, .{ .name = GraphWidget.node_drag_name });
                    graph.beginNodeDrag(wd.id);
                }
            },
            .release => if (me.button.pointer() and dvui.captured(wd.id)) {
                e.handle(@src(), wd);
                dvui.captureMouse(null, e.num);
                dvui.dragEnd();
                const moved = graph.endNodeDrag();
                // A plain click on one node of a multi-selection narrows to that node.
                if (!moved and self.init_opts.selectable and !me.mod.shift() and !me.mod.matchBind("ctrl/cmd")) {
                    graph.select(self.id, .replace);
                }
            },
            .wheel_x, .wheel_y => {},
            else => e.handle(@src(), wd),
        }
    }
}

pub fn deinit(self: *BaseNode) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;

    if (self.column_side != null) {
        self.column.deinit();
        self.body.deinit();
    }
    self.processEvents();
    if (dvui.captured(self.card.data().id)) dvui.cursorSet(.hand);
    self.graph.registerNode(self.id, self.card.data().borderRectScale().r);
    self.card.deinit();
    self.front_to_back.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
