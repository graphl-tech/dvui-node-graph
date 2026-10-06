//! A draggable, selectable node card. Lay out its ports with `BaseInput`/`BaseOutput` (or call
//! `defaultPorts`). Inputs stack in a left column and outputs in a right column; declare all
//! inputs before any outputs.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const GraphWidget = @import("GraphWidget.zig");
const ports = @import("ports.zig");

const NodeId = types.NodeId;
const Ports = types.Ports;

const BaseNode = @This();

/// Card padding; sockets with `edge_overlap` are pulled out by this much to sit on the border.
pub const body_inset: f32 = 5;

pub const InitOptions = struct {
    title: ?[]const u8 = null,
    /// Caller-owned position in graph space. When null the graph stores it.
    position: ?*dvui.Point = null,
    /// Initial position when the graph stores it.
    default_position: dvui.Point = .{},
    draggable: bool = true,
    selectable: bool = true,
    /// Apply this frame's drag delta to the position. Turn off to apply moves yourself from
    /// `GraphWidget.node_drag_delta` (e.g. to route them through an undo system).
    apply_drag: bool = true,
};

graph: *GraphWidget,
id: NodeId,
inputs: Ports,
outputs: Ports,
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

pub fn init(
    src: std.builtin.SourceLocation,
    graph: *GraphWidget,
    id: NodeId,
    inputs: anytype,
    outputs: anytype,
    init_opts: InitOptions,
    opts: dvui.Options,
) *BaseNode {
    const self = dvui.widgetAlloc(BaseNode);
    const arena = dvui.currentWindow().arena();
    self.initInPlace(
        src,
        graph,
        id,
        types.ports(arena, .input, inputs) catch .none(.input),
        types.ports(arena, .output, outputs) catch .none(.output),
        init_opts,
        opts,
    );
    return self;
}

/// It's expected to call this when `self` is `undefined`.
pub fn initInPlace(
    self: *BaseNode,
    src: std.builtin.SourceLocation,
    graph: *GraphWidget,
    id: NodeId,
    inputs: Ports,
    outputs: Ports,
    init_opts: InitOptions,
    opts: dvui.Options,
) void {
    graph.assertCanDeclare();
    self.* = .{
        .graph = graph,
        .id = id,
        .inputs = inputs,
        .outputs = outputs,
        .init_opts = init_opts,
        .position = init_opts.position orelse graph.nodePositionPtr(id, init_opts.default_position),
        .selected = graph.isSelected(id),
        .hovered = if (graph.hover_node) |h| h == id else false,
    };

    if (self.selected and init_opts.draggable and init_opts.apply_drag) {
        self.position.* = self.position.plus(graph.node_drag_delta);
    }

    // First node declared draws on top and gets events first.
    self.front_to_back.init();

    const theme = dvui.themeGet();
    const base_fill = theme.color(.window, .fill);
    const highlight = theme.color(.highlight, .fill);
    const fill = if (self.selected)
        base_fill.lerp(highlight, 0.12)
    else if (self.hovered)
        base_fill.lerp(theme.color(.control, .text), 0.06)
    else
        base_fill;
    const border = if (self.selected)
        theme.focus
    else if (self.hovered)
        theme.color(.control, .text).lerp(theme.border, 0.3)
    else
        theme.border;

    const defaults: dvui.Options = .{
        .name = "Node",
        .rect = .{ .x = @round(self.position.x), .y = @round(self.position.y) },
        .id_extra = @truncate(id),
        .margin = .all(body_inset),
        .padding = .all(body_inset),
        .corners = .all(12),
        .background = true,
        .border = .all(1),
        .color_fill = fill.opacity(0.92),
        .color_border = border,
        .min_size_content = .{ .w = 60, .h = 10 },
        .box_shadow = .{ .alpha = 0.25, .fade = 10, .corners = .all(12) },
    };
    self.card.init(src, .{ .dir = .vertical }, defaults.override(opts));
    self.card.drawBackground();

    if (init_opts.title) |t| self.titleLabel("{s}", .{t});
}

/// Draw a title row. Anything drawn into the node before its first port stacks above the ports.
pub fn titleLabel(self: *BaseNode, comptime fmt: []const u8, args: anytype) void {
    std.debug.assert(self.column_side == null);
    dvui.labelEx(@src(), fmt, args, .{ .ellipsize = false }, .{
        .font = dvui.themeGet().font_mono.withWeight(.bold),
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

/// Render every input and output with default labels.
pub fn defaultPorts(self: *BaseNode) void {
    for (0..self.inputs.len()) |i| self.baseInput(@src(), i, .{ .id_extra = i });
    for (0..self.outputs.len()) |i| self.baseOutput(@src(), i, .{ .id_extra = i });
}

/// Default row for input port `index`.
pub fn baseInput(self: *BaseNode, src: std.builtin.SourceLocation, index: usize, opts: dvui.Options) void {
    var w = ports.BaseInput.init(src, self, index, opts);
    defer w.deinit();
    w.defaultLabel();
}

/// Default row for output port `index`.
pub fn baseOutput(self: *BaseNode, src: std.builtin.SourceLocation, index: usize, opts: dvui.Options) void {
    var w = ports.BaseOutput.init(src, self, index, opts);
    defer w.deinit();
    w.defaultLabel();
}

pub fn sidePorts(self: *const BaseNode, side: types.Side) Ports {
    return switch (side) {
        .input => self.inputs,
        .output => self.outputs,
    };
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
