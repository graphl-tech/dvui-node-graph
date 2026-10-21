//! A draggable, selectable node card. Everything is drawn by the caller, top to bottom: a
//! `header` (e.g. a title label), then the socket rows inside `socketArea`, then any `footer`
//! sections.
//!
//! For a node drawn for you from struct types, see `GraphWidget.managedNode`.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const GraphWidget = @import("GraphWidget.zig");
const draw = @import("draw.zig");
const Style = @import("Style.zig");
const SocketArea = @import("SocketArea.zig");

const NodeId = types.NodeId;

const Node = @This();

pub const InitOptions = struct {
    /// The app's selection state for this node. Changes arrive as `GraphWidget.Event`s
    /// (`select`, `select_all`, `deselect_all`, `box_select`).
    selected: bool = false,
    draggable: bool = true,
    selectable: bool = true,
    /// Overrides the graph's `style.node` for this node.
    style: ?Style.Node = null,
    /// Apply this frame's drag delta to the position if this node is selected or the drag started
    /// on it. Turn off to apply moves yourself from `GraphWidget.node_drag_delta` (e.g. to route
    /// them through an undo system).
    apply_drag: bool = true,
};

graph: *GraphWidget,
id: NodeId,
init_opts: InitOptions,
position: *dvui.Point,
/// `init_opts.selected`, or what an in-progress box select will make it.
selected: bool,
/// Mouse was over this (topmost) node last frame.
hovered: bool,

front_to_back: dvui.RenderFrontToBack = undefined,
card: dvui.BoxWidget = undefined,
/// A `socketArea` has begun and not been deinit yet.
area_open: bool = false,

pub fn init(
    src: std.builtin.SourceLocation,
    graph: *GraphWidget,
    id: NodeId,
    /// `position` is the node's top-left corner in graph space, provided by caller,
    /// and we might write through it
    position: *dvui.Point,
    init_opts: InitOptions,
    opts: dvui.Options,
) *Node {
    const self = dvui.widgetAlloc(Node);
    self.initInPlace(src, graph, id, position, init_opts, opts);
    return self;
}

/// It's expected to call this when `self` is `undefined`.
pub fn initInPlace(
    self: *Node,
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
        .selected = if (graph.inBoxSelect(id)) |m| m == .include else init_opts.selected,
        .hovered = if (graph.hover_node) |h| h == id else false,
    };

    const drag_origin = if (graph.draggedNode()) |d| d == id else false;
    if ((init_opts.selected or drag_origin) and init_opts.draggable and init_opts.apply_drag) {
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
}

/// Begin a section above the socket rows. The caller must `deinit` it.
pub fn header(self: *Node, src: std.builtin.SourceLocation, opts: dvui.Options) *dvui.BoxWidget {
    return self.section(src, "header", opts);
}

/// Begin the socket rows. The caller must `deinit` it.
pub fn socketArea(self: *Node, src: std.builtin.SourceLocation, opts: dvui.Options) *SocketArea {
    return SocketArea.init(src, self, opts);
}

/// Begin a section below the socket rows. The caller must `deinit` it.
pub fn footer(self: *Node, src: std.builtin.SourceLocation, opts: dvui.Options) *dvui.BoxWidget {
    return self.section(src, "footer", opts);
}

fn section(self: *Node, src: std.builtin.SourceLocation, name: []const u8, opts: dvui.Options) *dvui.BoxWidget {
    if (self.area_open) {
        dvui.log.err("dvui_node_graph: node {d} began a {s} inside its socket area; deinit the area first", .{ self.id, name });
    }
    const defaults: dvui.Options = .{ .expand = .horizontal };
    return dvui.box(src, .{ .dir = .vertical }, defaults.override(opts));
}

pub fn data(self: *Node) *dvui.WidgetData {
    return self.card.data();
}

fn processEvents(self: *Node) void {
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
                    const mode: ?GraphWidget.SelectMode = if (me.mod.shift())
                        .remove
                    else if (me.mod.matchBind("ctrl/cmd"))
                        .add
                    else if (!self.selected) .replace else null;
                    if (mode) |m| graph.pushEvent(.{ .select = .{ .node = self.id, .mode = m } });
                }
                if (self.init_opts.draggable) {
                    dvui.captureMouse(wd, e.num);
                    dvui.dragPreStart(me.button, me.p, .{ .name = GraphWidget.node_drag_name });
                    graph.beginNodeDrag(wd.id, self.id);
                }
            },
            .release => if (me.button.pointer() and dvui.captured(wd.id)) {
                e.handle(@src(), wd);
                dvui.captureMouse(null, e.num);
                dvui.dragEnd();
                const moved = graph.endNodeDrag();
                // A plain click on one node of a multi-selection narrows to that node.
                if (!moved and self.init_opts.selectable and self.selected and !me.mod.shift() and !me.mod.matchBind("ctrl/cmd")) {
                    graph.pushEvent(.{ .select = .{ .node = self.id, .mode = .replace } });
                }
            },
            .wheel_x, .wheel_y => {},
            else => e.handle(@src(), wd),
        }
    }
}

pub fn deinit(self: *Node) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;

    self.processEvents();
    if (dvui.captured(self.card.data().id)) dvui.cursorSet(.hand);
    self.graph.registerNode(self.id, self.card.data().borderRectScale().r, self.init_opts.selected);
    self.card.deinit();
    self.front_to_back.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
