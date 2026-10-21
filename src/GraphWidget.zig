//! Pannable, zoomable node-graph canvas.
//! See README.md for usage
//!
//! Each node's position is passed in by pointer, and whether it is selected by
//! `ManagedNode.InitOptions.selected`; selection changes arrive as events. The view transform
//! persists in dvui's data store keyed by this widget's id unless the caller owns it
//! (`InitOptions.view`).

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const types = @import("types.zig");
const draw = @import("draw.zig");
const ManagedNode = @import("ManagedNode.zig");
const ManagedSocket = @import("ManagedSocket.zig");
const Style = @import("Style.zig");

const NodeId = types.NodeId;
const Socket = types.Socket;
const SocketId = types.SocketId;
const Edge = types.Edge;
const Physical = dvui.Point.Physical;

const GraphWidget = @This();

pub const node_drag_name = "dvui_node_graph_node";
pub const wire_drag_name = "dvui_node_graph_wire";
const pan_drag_name = "dvui_node_graph_pan";

pub const View = struct {
    /// Graph-space point drawn at the top-left corner of the canvas.
    origin: dvui.Point = .{},
    /// Zoom factor (graph units -> natural pixels).
    scale: f32 = 1,
};

pub const InitOptions = struct {
    /// Caller-owned view transform. When null the view lives in dvui's data store.
    view: ?*View = null,
    /// False draws the graph without responding to input (e.g. a drag preview).
    interactive: bool = true,
    style: Style = .default,
    pan: bool = true,
    zoom: bool = true,
    /// Ctrl/cmd-drag on empty canvas selects the nodes it touches, shift-drag deselects them
    /// (see `Event.box_select`).
    box_select: bool = true,
    /// Let the user drag wires between two inputs or two outputs.
    allow_same_side_links: bool = false,
    /// Clicking a socket selects it; clicking a second socket links the two. Any other press on
    /// the canvas, Escape, or starting a wire drag drops the selection.
    click_to_link: bool = true,
    min_zoom: f32 = 0.2,
    max_zoom: f32 = 2.0,
};

pub const ContextTarget = union(enum) {
    canvas,
    node: NodeId,
    socket: SocketId,
};

/// Graph-level events, collected while the frame's nodes and edges are declared. Slices in
/// payloads point into the dvui frame arena.
pub const Event = union(enum) {
    /// A wire was dragged from `source` and released on a compatible socket `target`. Opposite
    /// side pairs are ordered output -> input.
    link_created: Edge,
    /// A wire was released over nothing it can connect to. `point` is in graph space.
    link_dropped: struct { source: SocketId, point: dvui.Point },
    /// An edge declared with `link` was clicked.
    link_clicked: Edge,
    /// A socket was pressed and released without dragging a wire.
    socket_clicked: SocketId,
    /// The selected nodes (and the node the drag started on) were dragged by `delta` (graph space).
    nodes_moved: struct { nodes: []const NodeId, delta: dvui.Point },
    /// A node was clicked; update the selection according to `mode` (from the modifier keys).
    select: struct { node: NodeId, mode: SelectMode },
    /// Ctrl/cmd+A.
    select_all,
    /// A click on empty canvas, or Escape, while a node is selected.
    deselect_all,
    /// A box select ended: select (`include`) or deselect (`exclude`) `nodes`.
    box_select: struct { nodes: []const NodeId, mode: BoxSelectMode },
    /// Delete or backspace while the canvas has focus.
    delete_selection,
    /// Right click. `point` is in graph space, `point_natural` is for placing a floating menu.
    context_menu: struct { target: ContextTarget, point: dvui.Point, point_natural: dvui.Point.Natural },
};

/// A socket drawn this (or last) frame.
const SocketRecord = struct {
    id: SocketId,
    center: Physical,
    radius: f32,
};

const NodeRecord = struct {
    id: NodeId,
    /// Border rect in graph space.
    rect: dvui.Rect,
    /// Declared with `selected`.
    selected: bool,
};

const SocketEvent = struct {
    socket: SocketId,
    event: ManagedSocket.Event,
};

const Press = struct {
    socket: SocketId,
    pt: Physical,
};

const Wire = struct {
    source: SocketId,
    /// Fallback start point when `source` is no longer declared as a socket.
    start: Physical,
};

const NodeDrag = struct {
    capture_id: dvui.Id,
    /// The node the drag started on. It moves with the selection even if it isn't selected.
    node: NodeId,
    total: dvui.Point = .{},
};

pub const BoxSelectMode = enum { include, exclude };

const BoxSelect = struct {
    start: Physical,
    current: Physical,
    mode: BoxSelectMode,
};

const State = struct {
    view: View = .{},
    press: ?Press = null,
    wire: ?Wire = null,
    wire_target: ?SocketId = null,
    node_drag: ?NodeDrag = null,
    box_select: ?BoxSelect = null,
    /// Socket selected for click-to-link.
    selected_socket: ?SocketId = null,
};

init_opts: InitOptions,
box: dvui.BoxWidget,
scaler: dvui.ScaleWidget = undefined,
state: *State,
view: *View,

/// Canvas content rect, physical.
canvas_rect: dvui.Rect.Physical,
/// Graph space -> physical.
data_rs: dvui.RectScale = undefined,
canvas_fill: dvui.Color,

prev_sockets: []const SocketRecord,
prev_nodes: []const NodeRecord,
prev_connected: []const SocketId,
sockets: std.ArrayList(SocketRecord) = .empty,
socket_index: std.AutoHashMapUnmanaged(SocketId, usize) = .empty,
nodes: std.ArrayList(NodeRecord) = .empty,
connected: std.ArrayList(SocketId) = .empty,
/// A node drag that ended this frame; reported as `nodes_moved` once every node is declared.
ended_drag: ?NodeDrag = null,
events_list: std.ArrayList(Event) = .empty,
/// Socket events for this frame, picked up by the matching `ManagedSocket`.
socket_events: std.ArrayList(SocketEvent) = .empty,
/// Socket events produced after sockets rendered; delivered next frame.
late_socket_events: std.ArrayList(SocketEvent) = .empty,
sockets_done: bool = false,

/// Socket nearest the mouse last frame; the only one that grows with proximity.
nearest_socket: ?SocketId = null,
/// Topmost node under the mouse last frame.
hover_node: ?NodeId = null,
/// Compatible socket under the mouse this frame while a wire is being dragged.
wire_target: ?SocketId = null,
/// How far selected nodes move this frame (graph space).
node_drag_delta: dvui.Point = .{},

canvas_events_done: bool = false,
/// Set by `events()`. Declaring nodes or links afterwards would miss their events this frame.
events_called: bool = false,
/// A socket was pressed this frame (so presses this frame don't drop the socket selection).
socket_pressed: bool = false,
prev_clip: dvui.Rect.Physical = undefined,
prev_rendering: bool = undefined,
prev_snap: bool = undefined,

pub var defaults: dvui.Options = .{
    .name = "NodeGraph",
    .expand = .both,
    .background = true,
    .min_size_content = .{ .w = 200, .h = 200 },
};

pub fn init(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) *GraphWidget {
    const self = dvui.widgetAlloc(GraphWidget);
    self.initInPlace(src, init_opts, opts);
    return self;
}

/// It's expected to call this when `self` is `undefined`.
pub fn initInPlace(self: *GraphWidget, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) void {
    const canvas = init_opts.style.canvas;
    const options = defaults.override(.{
        .color_fill = draw.paint(canvas.fill orelse dvui.themeGet().color(.content, .fill)),
        .corners = .all(canvas.corner_radius),
    }).override(opts);
    self.* = .{
        .init_opts = init_opts,
        .box = undefined,
        .state = undefined,
        .view = undefined,
        .canvas_rect = undefined,
        .canvas_fill = draw.flat(options.color(.fill)),
        .prev_sockets = &.{},
        .prev_nodes = &.{},
        .prev_connected = &.{},
    };
    self.box.init(src, .{}, options);
    self.box.drawBackground();

    const wd_id = self.box.data().id;
    self.state = dvui.dataGetPtrDefault(null, wd_id, "_state", State, .{});
    self.view = init_opts.view orelse &self.state.view;
    self.view.scale = std.math.clamp(self.view.scale, init_opts.min_zoom, init_opts.max_zoom);

    self.prev_sockets = dvui.dataGetSlice(null, wd_id, "_sockets", []SocketRecord) orelse &.{};
    self.prev_nodes = dvui.dataGetSlice(null, wd_id, "_nodes", []NodeRecord) orelse &.{};
    self.prev_connected = dvui.dataGetSlice(null, wd_id, "_connected", []SocketId) orelse &.{};
    // Reserve what last frame used, so declaring nodes, sockets and links rarely reallocates.
    self.sockets.ensureTotalCapacity(arena(), self.prev_sockets.len) catch {};
    self.socket_index.ensureTotalCapacity(arena(), @intCast(self.prev_sockets.len)) catch {};
    self.nodes.ensureTotalCapacity(arena(), self.prev_nodes.len) catch {};
    self.connected.ensureTotalCapacity(arena(), self.prev_connected.len) catch {};
    if (dvui.dataGetSlice(null, wd_id, "_late_socket_events", []SocketEvent)) |late| {
        self.socket_events.appendSlice(arena(), late) catch {};
        dvui.dataRemove(null, wd_id, "_late_socket_events");
    }

    const crs = self.box.data().contentRectScale();
    self.canvas_rect = crs.r;
    self.prev_clip = dvui.clip(self.canvas_rect);

    const cr = self.box.data().contentRect();
    dvui.ScaleWidget.init(&self.scaler, @src(), .{ .scale = &self.view.scale }, .{
        .rect = .{
            .x = -self.view.origin.x * self.view.scale,
            .y = -self.view.origin.y * self.view.scale,
            .w = cr.w / self.view.scale,
            .h = cr.h / self.view.scale,
        },
        .background = false,
        .margin = .{},
        .padding = .{},
        .border = .{},
    });
    self.data_rs = self.scaler.screenRectScale(.{});

    // Defer everything inside the canvas. Edges/grid land in the normal queue while nodes use
    // `RenderFrontToBack` (the "after" queue), so edges draw beneath nodes even though they are
    // declared after them.
    self.prev_rendering = dvui.renderingSet(false);
    self.prev_snap = dvui.snapToPixelsSet(false);

    if (init_opts.style.canvas.grid) |grid| draw.grid(self.canvas_rect, self.data_rs, grid, grid.color orelse Style.text());

    if (init_opts.interactive) {
        self.computeHover();
        self.processNodeDrag();
        self.processWire();
    }
}

fn arena() std.mem.Allocator {
    return dvui.currentWindow().arena();
}

pub fn data(self: *GraphWidget) *dvui.WidgetData {
    return self.box.data();
}

pub fn id(self: *GraphWidget) dvui.Id {
    return self.box.data().id;
}

pub fn style(self: *const GraphWidget) *const Style {
    return &self.init_opts.style;
}

pub fn interactive(self: *const GraphWidget) bool {
    return self.init_opts.interactive;
}

/// Whether physical point `p` is over the canvas and not covered by a floating window.
pub fn mouseOverCanvas(self: *GraphWidget, p: Physical) bool {
    if (!self.canvas_rect.contains(p)) return false;
    const cw = dvui.currentWindow();
    return cw.subwindows.windowFor(p) == dvui.subwindowCurrentId();
}

fn computeHover(self: *GraphWidget) void {
    const mouse = dvui.currentWindow().mouse_pt;
    if (!self.mouseOverCanvas(mouse)) return;

    var best_d2 = std.math.floatMax(f32);
    for (self.prev_sockets) |r| {
        const d = mouse.diff(r.center);
        const d2 = d.x * d.x + d.y * d.y;
        if (d2 < best_d2) {
            best_d2 = d2;
            self.nearest_socket = r.id;
        }
    }

    // The first node drawn renders on top (see `ManagedNode`), so the first hit wins.
    for (self.prev_nodes) |n| {
        if (self.data_rs.rectToPhysical(n.rect).contains(mouse)) {
            self.hover_node = n.id;
            break;
        }
    }
}

/// Node drag motion is applied here, before any node renders, so every selected node moves by the
/// same delta in the same frame regardless of declaration order.
fn processNodeDrag(self: *GraphWidget) void {
    const nd = &(self.state.node_drag orelse return);
    if (!dvui.captured(nd.capture_id)) {
        self.state.node_drag = null;
        return;
    }
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action != .motion) continue;
        if (e.target_widgetId != nd.capture_id) continue;
        e.handle(@src(), self.box.data());
        if (dvui.dragging(me.p, node_drag_name)) |dps| {
            const delta: dvui.Point = .{ .x = dps.x / self.data_rs.s, .y = dps.y / self.data_rs.s };
            self.node_drag_delta = self.node_drag_delta.plus(delta);
            nd.total = nd.total.plus(delta);
            dvui.cursorSet(.hand);
            dvui.refresh(null, @src(), self.id());
        }
    }
}

/// Advance a pending socket press / wire drag with the captured mouse events. Runs before nodes
/// (so sockets see this frame's click/wire events) and again at the end of the frame for events
/// that arrive after a press in the same frame.
fn processWire(self: *GraphWidget) void {
    if (self.state.press == null and self.state.wire == null) return;
    const wd = self.box.data();
    if (!dvui.captured(wd.id)) {
        self.state.press = null;
        self.state.wire = null;
        return;
    }
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .mouse) continue;
        if (e.target_widgetId != wd.id) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .motion => {
                e.handle(@src(), wd);
                if (self.state.press) |p| {
                    if (dvui.dragging(me.p, wire_drag_name) != null) {
                        self.state.wire = .{ .source = p.socket, .start = p.pt };
                        self.state.wire_target = null;
                        self.state.press = null;
                        self.queueSocketEvent(p.socket, .{ .wire = .start });
                        self.state.selected_socket = null;
                    }
                }
                dvui.refresh(null, @src(), wd.id);
            },
            .release => if (me.button.pointer()) {
                e.handle(@src(), wd);
                dvui.captureMouse(null, e.num);
                dvui.dragEnd();
                dvui.refresh(null, @src(), wd.id);
                if (self.state.wire) |w| {
                    self.state.wire = null;
                    if (self.resolveWireTarget(w.source, me.p)) |t| {
                        self.pushEvent(.{ .link_created = Edge.normalized(w.source, t) });
                        self.queueSocketEvent(w.source, .{ .wire = .{ .connect = t } });
                    } else {
                        const pt = self.data_rs.pointFromPhysical(me.p);
                        self.pushEvent(.{ .link_dropped = .{ .source = w.source, .point = pt } });
                        self.queueSocketEvent(w.source, .{ .wire = .{ .drop = pt } });
                    }
                } else if (self.state.press) |p| {
                    self.state.press = null;
                    self.queueSocketEvent(p.socket, .{ .mouse = .{ .click = .{ .button = me.button, .mod = me.mod, .p = me.p } } });
                    self.pushEvent(.{ .socket_clicked = p.socket });
                    if (self.init_opts.click_to_link) self.clickToLink(p.socket);
                }
            },
            else => {},
        }
    }
}

fn resolveWireTarget(self: *GraphWidget, source: SocketId, p: Physical) ?SocketId {
    if (self.wire_target) |t| return t;
    const records = if (self.sockets.items.len > 0) self.sockets.items else self.prev_sockets;
    var best: ?SocketId = null;
    var best_d = std.math.floatMax(f32);
    for (records) |r| {
        if (!self.canLink(source, r.id)) continue;
        const d = p.diff(r.center).length();
        if (d <= r.radius and d < best_d) {
            best = r.id;
            best_d = d;
        }
    }
    return best orelse self.state.wire_target;
}

fn queueSocketEvent(self: *GraphWidget, s: SocketId, e: ManagedSocket.Event) void {
    const list = if (self.sockets_done) &self.late_socket_events else &self.socket_events;
    list.append(arena(), .{ .socket = s, .event = e }) catch {};
}

// ---------------------------------------------------------------------------------------------
// Declaring nodes and edges
// ---------------------------------------------------------------------------------------------

/// Begin a node at `position` (graph space, written by drags). Draw its header, then its socket
/// rows in `socketArea`; the caller must `deinit` it.
pub fn node(self: *GraphWidget, src: std.builtin.SourceLocation, node_id: NodeId, position: *dvui.Point, init_opts: ManagedNode.InitOptions, opts: dvui.Options) *ManagedNode {
    return ManagedNode.init(src, self, node_id, position, init_opts, opts);
}

pub const ManagedNodeOptions = struct {
    title: ?[]const u8 = null,
    node: ManagedNode.InitOptions = .{},
};

/// Render a complete node with a named row for each field of the structs `Inputs` and `Outputs`.
pub fn managedNode(self: *GraphWidget, src: std.builtin.SourceLocation, node_id: NodeId, position: *dvui.Point, comptime Inputs: type, comptime Outputs: type) void {
    self.managedNodeEx(src, node_id, position, Inputs, Outputs, .{}, .{});
}

pub fn managedNodeEx(self: *GraphWidget, src: std.builtin.SourceLocation, node_id: NodeId, position: *dvui.Point, comptime Inputs: type, comptime Outputs: type, init_opts: ManagedNodeOptions, opts: dvui.Options) void {
    var n = ManagedNode.init(src, self, node_id, position, init_opts.node, opts);
    defer n.deinit();
    if (init_opts.title) |t| dvui.labelEx(@src(), "{s}", .{t}, .{ .ellipsize = false }, .{ .padding = .all(2), .expand = .horizontal });

    var area = n.socketArea(@src(), .{});
    defer area.deinit();
    for (comptime std.meta.fieldNames(Inputs), 0..) |name, i| area.managedInput(@src(), i, name, .{ .id_extra = i });
    for (comptime std.meta.fieldNames(Outputs), 0..) |name, i| area.managedOutput(@src(), i, name, .{ .id_extra = i });
}

pub const LinkOptions = struct {
    /// Overrides the graph's `style.edge` for this edge.
    style: ?Style.Edge = null,
    /// Respond to hover and clicks.
    interactive: bool = true,
    /// Skip drawing (still counts as a connection for socket fill).
    hidden: bool = false,
};

pub const LinkResult = struct {
    hovered: bool = false,
    clicked: bool = false,
    /// False when either socket was not declared this frame.
    drawn: bool = false,
};

/// Draw an edge from `source_socket` on `source_node` to `target_socket` on `target_node`.
/// Either socket may be an input or an output. Call after the nodes owning both sockets.
pub fn link(self: *GraphWidget, source_node: NodeId, source_socket: Socket, target_node: NodeId, target_socket: Socket) LinkResult {
    return self.linkEx(source_node, source_socket, target_node, target_socket, .{});
}

pub fn linkEx(self: *GraphWidget, source_node: NodeId, source_socket: Socket, target_node: NodeId, target_socket: Socket, opts: LinkOptions) LinkResult {
    return self.linkEdge(.{
        .source = .{ .node = source_node, .socket = source_socket },
        .target = .{ .node = target_node, .socket = target_socket },
    }, opts);
}

pub fn linkEdge(self: *GraphWidget, edge: Edge, opts: LinkOptions) LinkResult {
    self.assertCanDeclare();
    self.connected.append(arena(), edge.source) catch {};
    self.connected.append(arena(), edge.target) catch {};
    if (opts.hidden) return .{};

    const a = self.record(edge.source) orelse return .{};
    const b = self.record(edge.target) orelse return .{};
    var result: LinkResult = .{ .drawn = true };

    const es = opts.style orelse self.style().edge;
    const pts = self.edgePointsStyled(edge, es) orelse return result;
    const thickness = es.thickness * self.data_rs.s;
    const mouse = dvui.currentWindow().mouse_pt;

    if (opts.interactive and self.interactive() and self.idle() and self.mouseOverCanvas(mouse) and self.nodeAt(mouse) == null) {
        const socket_clearance = @max(a.radius, b.radius) * 1.5;
        const near_end = mouse.diff(a.center).length() < socket_clearance or mouse.diff(b.center).length() < socket_clearance;
        if (!near_end and draw.distanceToPolyline(mouse, pts) <= @max(5, thickness)) {
            result.hovered = true;
            dvui.cursorSet(.hand);
            for (dvui.events()) |*e| {
                if (e.handled or e.evt != .mouse) continue;
                const me = e.evt.mouse;
                if (me.action == .press and me.button.pointer()) {
                    e.handle(@src(), self.box.data());
                    result.clicked = true;
                    self.pushEvent(.{ .link_clicked = edge });
                    break;
                }
            }
        }
    }

    if (result.hovered) {
        const hover: dvui.Path.StrokeOptions = .{
            .thickness = thickness + es.hover_extra_thickness * self.data_rs.s,
            .color = draw.paint(es.hover_color orelse dvui.themeGet().color(.highlight, .fill)),
        };
        if (es.hover_dashed) draw.strokeDashed(pts, es.dash.on, es.dash.off, hover) else dvui.Path.stroke(.{ .points = pts }, hover);
        return result;
    }
    if (es.shadow) |sh| {
        const offset: dvui.Point.Physical = .{ .x = sh.offset.x * self.data_rs.s, .y = sh.offset.y * self.data_rs.s };
        const shadow = arena().alloc(Physical, pts.len) catch return result;
        for (pts, shadow) |p, *s| s.* = p.plus(offset);
        strokeEdge(shadow, es, thickness, sh.color);
    }
    strokeEdge(pts, es, thickness, es.color orelse Style.text());
    return result;
}

fn strokeEdge(pts: []const Physical, es: Style.Edge, thickness: f32, color: dvui.Color) void {
    const opts: dvui.Path.StrokeOptions = .{ .thickness = thickness, .color = draw.paint(color) };
    if (es.dashed) draw.strokeDashed(pts, es.dash.on, es.dash.off, opts) else dvui.Path.stroke(.{ .points = pts }, opts);
}

/// Bezier points (physical) of `edge` this frame, or null if either socket is undeclared.
pub fn edgePoints(self: *GraphWidget, edge: Edge) ?[]Physical {
    return self.edgePointsStyled(edge, self.style().edge);
}

fn edgePointsStyled(self: *GraphWidget, edge: Edge, es: Style.Edge) ?[]Physical {
    const a = self.socketCenter(edge.source) orelse return null;
    const b = self.socketCenter(edge.target) orelse return null;
    return draw.edgePointsCurved(arena(), a, sideDir(edge.source.side()), b, sideDir(edge.target.side()), es.curvature, es.min_tangent) catch null;
}

/// Horizontal direction an edge leaves a socket on `side`.
pub fn sideDir(side: types.Side) f32 {
    return switch (side) {
        .input => -1,
        .output => 1,
    };
}

/// Whether the user may wire `a` to `b` under this graph's options.
pub fn canLink(self: *const GraphWidget, a: SocketId, b: SocketId) bool {
    return a.canLink(b, self.init_opts.allow_same_side_links);
}

/// True when no drag interaction is in progress.
pub fn idle(self: *GraphWidget) bool {
    return self.state.press == null and self.state.wire == null and self.state.node_drag == null and
        self.state.box_select == null and dvui.currentWindow().dragging.state == .none;
}

/// Node under physical point `p` among nodes declared so far this frame.
pub fn nodeAt(self: *GraphWidget, p: Physical) ?NodeId {
    for (self.nodes.items) |n| {
        if (self.data_rs.rectToPhysical(n.rect).contains(p)) return n.id;
    }
    return null;
}

/// Socket under physical point `p` among sockets declared so far this frame.
pub fn socketAt(self: *GraphWidget, p: Physical) ?SocketId {
    for (self.sockets.items) |r| {
        if (p.diff(r.center).length() <= r.radius) return r.id;
    }
    return null;
}

fn record(self: *GraphWidget, s: SocketId) ?SocketRecord {
    const i = self.socket_index.get(s) orelse return null;
    return self.sockets.items[i];
}

fn recordAnyFrame(self: *GraphWidget, s: SocketId) ?SocketRecord {
    if (self.record(s)) |r| return r;
    for (self.prev_sockets) |r| if (r.id.eql(s)) return r;
    return null;
}

pub const SocketGeometry = struct { center: Physical, radius: f32 };

/// Where socket `s` was drawn last frame in the graph with widget id `graph_id`. Usable before
/// that graph's `init` this frame (e.g. from a menu rendered first).
pub fn lastFrameSocket(graph_id: dvui.Id, s: SocketId) ?SocketGeometry {
    const recs = dvui.dataGetSlice(null, graph_id, "_sockets", []SocketRecord) orelse return null;
    for (recs) |r| if (r.id.eql(s)) return .{ .center = r.center, .radius = r.radius };
    return null;
}

/// Physical center of a socket declared this frame, else last frame.
pub fn socketCenter(self: *GraphWidget, s: SocketId) ?Physical {
    const r = self.recordAnyFrame(s) orelse return null;
    return r.center;
}

/// Physical hit radius of a socket declared this frame, else last frame.
pub fn socketRadius(self: *GraphWidget, s: SocketId) ?f32 {
    const r = self.recordAnyFrame(s) orelse return null;
    return r.radius;
}

/// Graph-space border rect of a node declared this frame, else last frame.
pub fn nodeRect(self: *GraphWidget, n: NodeId) ?dvui.Rect {
    for (self.nodes.items) |r| if (r.id == n) return r.rect;
    for (self.prev_nodes) |r| if (r.id == n) return r.rect;
    return null;
}

/// Queue `e` for `events()`. Redraws next frame so the app's response shows.
pub fn pushEvent(self: *GraphWidget, e: Event) void {
    self.events_list.append(arena(), e) catch {};
    dvui.refresh(null, @src(), self.id());
}

/// Events produced so far this frame. Processes canvas-level input (panning, zoom, selection,
/// context menus), so call it after all nodes and edges are declared.
pub fn events(self: *GraphWidget) []const Event {
    self.events_called = true;
    self.processCanvasEvents();
    return self.events_list.items;
}

/// Debug builds panic when a node or link is declared after `events()` this frame.
pub fn assertCanDeclare(self: *const GraphWidget) void {
    if (builtin.mode == .Debug and self.events_called) {
        @panic("can't draw new nodes or links after graph.events() or some events may be missed");
    }
}

// ---------------------------------------------------------------------------------------------
// Interfaces used by ManagedNode / ManagedSocket
// ---------------------------------------------------------------------------------------------

pub fn registerNode(self: *GraphWidget, node_id: NodeId, border_rect: dvui.Rect.Physical, selected: bool) void {
    self.nodes.append(arena(), .{ .id = node_id, .rect = self.data_rs.rectFromPhysical(border_rect), .selected = selected }) catch {};
}

pub fn registerSocket(self: *GraphWidget, s: SocketId, center: Physical, radius: f32) void {
    self.socket_index.put(arena(), s, self.sockets.items.len) catch return;
    self.sockets.append(arena(), .{ .id = s, .center = center, .radius = radius }) catch {};
}

/// Events queued for socket `s` this frame.
pub fn takeSocketEvents(self: *GraphWidget, s: SocketId, out: *std.ArrayList(ManagedSocket.Event)) void {
    for (self.socket_events.items) |q| {
        if (q.socket.eql(s)) out.append(arena(), q.event) catch {};
    }
}

/// Whether `s` had an edge last frame (one-frame lag since sockets draw before `link`).
pub fn isConnected(self: *GraphWidget, s: SocketId) bool {
    for (self.prev_connected) |c| if (c.eql(s)) return true;
    for (self.connected.items) |c| if (c.eql(s)) return true;
    return false;
}

/// Proximity scale in [rest, 1] for a socket. Only the socket nearest the mouse last frame
/// grows, and while wiring only if the wire could connect to it.
pub fn socketScale(self: *GraphWidget, s: SocketId) f32 {
    const rest = self.style().socket.rest_scale;
    const nearest = self.nearest_socket orelse return rest;
    if (!nearest.eql(s)) return rest;
    if (self.wireSource()) |src| {
        if (!src.eql(s) and !self.canLink(src, s)) return rest;
    }
    const rec = for (self.prev_sockets) |r| {
        if (r.id.eql(s)) break r;
    } else return rest;
    const d = dvui.currentWindow().mouse_pt.diff(rec.center).length();
    if (d <= rec.radius) return 1.0;
    if (dvui.reduce_motion) return rest;
    const range = self.style().socket.proximity;
    const closeness = std.math.clamp((rec.radius + range - d) / range, 0.0, 1.0);
    return std.math.lerp(rest, 1.0, dvui.easing.inCubic(closeness));
}

/// Socket a wire is being dragged from, if any.
pub fn wireSource(self: *GraphWidget) ?SocketId {
    const w = self.state.wire orelse return null;
    return w.source;
}

/// Socket currently pressed (a wire drag may follow), if any.
pub fn pressedSocket(self: *GraphWidget) ?SocketId {
    const p = self.state.press orelse return null;
    return p.socket;
}

/// Begin a socket press: captures the mouse to the canvas so the press can become a wire drag.
pub fn pressSocket(self: *GraphWidget, socket: SocketId, me: dvui.Event.Mouse, event_num: u16) void {
    self.socket_pressed = true;
    self.state.press = .{ .socket = socket, .pt = me.p };
    self.state.wire = null;
    dvui.captureMouse(self.box.data(), event_num);
    dvui.dragPreStart(me.button, me.p, .{ .name = wire_drag_name });
}

/// Socket selected for click-to-link, if any.
pub fn selectedSocket(self: *const GraphWidget) ?SocketId {
    return self.state.selected_socket;
}

/// Select (or with null, deselect) a socket for click-to-link.
pub fn selectSocket(self: *GraphWidget, s: ?SocketId) void {
    self.state.selected_socket = s;
    dvui.refresh(null, @src(), self.id());
}

fn clickToLink(self: *GraphWidget, s: SocketId) void {
    const sel = self.state.selected_socket orelse return self.selectSocket(s);
    if (sel.eql(s)) return self.selectSocket(null);
    if (!self.canLink(sel, s)) return self.selectSocket(s);
    self.pushEvent(.{ .link_created = Edge.normalized(sel, s) });
    self.selectSocket(null);
}

/// Any press on the canvas that isn't on a socket drops the click-to-link selection.
fn dropSocketSelectionOnOtherPress(self: *GraphWidget) void {
    if (self.state.selected_socket == null or self.socket_pressed) return;
    for (dvui.events()) |*e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        if (me.action == .press and self.mouseOverCanvas(me.p)) {
            self.selectSocket(null);
            return;
        }
    }
}

/// Mark `s` as the compatible socket under the mouse during a wire drag.
pub fn setWireTarget(self: *GraphWidget, s: SocketId) void {
    self.wire_target = s;
}

pub fn beginNodeDrag(self: *GraphWidget, capture_id: dvui.Id, node_id: NodeId) void {
    self.state.node_drag = .{ .capture_id = capture_id, .node = node_id };
}

/// The node a drag started on, while a node drag is in progress.
pub fn draggedNode(self: *const GraphWidget) ?NodeId {
    const nd = self.state.node_drag orelse return null;
    return nd.node;
}

/// Ends the drag. Returns whether the nodes moved; if so `nodes_moved` follows.
pub fn endNodeDrag(self: *GraphWidget) bool {
    const nd = self.state.node_drag orelse return false;
    self.state.node_drag = null;
    if (nd.total.x == 0 and nd.total.y == 0) return false;
    self.ended_drag = nd;
    return true;
}

// ---------------------------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------------------------

pub const SelectMode = enum { replace, add, remove };

/// While a box select is in progress, whether it covers `node_id` and what it will do to it.
pub fn inBoxSelect(self: *const GraphWidget, node_id: NodeId) ?BoxSelectMode {
    const bs = self.state.box_select orelse return null;
    const r = for (self.prev_nodes) |n| {
        if (n.id == node_id) break n.rect;
    } else return null;
    if (self.data_rs.rectToPhysical(r).intersect(rectFromPoints(bs.start, bs.current)).empty()) return null;
    return bs.mode;
}

fn anySelected(self: *const GraphWidget) bool {
    for (self.nodes.items) |n| if (n.selected) return true;
    return false;
}

fn isSelected(self: *const GraphWidget, node_id: NodeId) bool {
    for (self.nodes.items) |n| if (n.id == node_id) return n.selected;
    return false;
}

fn pushNodesMoved(self: *GraphWidget) void {
    const nd = self.ended_drag orelse return;
    self.ended_drag = null;
    var moved: std.ArrayList(NodeId) = .empty;
    for (self.nodes.items) |n| {
        if (n.selected or n.id == nd.node) moved.append(arena(), n.id) catch {};
    }
    self.pushEvent(.{ .nodes_moved = .{ .nodes = moved.items, .delta = nd.total } });
}

fn endBoxSelect(self: *GraphWidget) void {
    const bs = self.state.box_select orelse return;
    self.state.box_select = null;
    const sel = rectFromPoints(bs.start, bs.current);
    var boxed: std.ArrayList(NodeId) = .empty;
    for (self.nodes.items) |n| {
        if (self.data_rs.rectToPhysical(n.rect).intersect(sel).empty()) continue;
        boxed.append(arena(), n.id) catch {};
    }
    if (boxed.items.len > 0) self.pushEvent(.{ .box_select = .{ .nodes = boxed.items, .mode = bs.mode } });
}

// ---------------------------------------------------------------------------------------------
// Canvas input
// ---------------------------------------------------------------------------------------------

fn processCanvasEvents(self: *GraphWidget) void {
    if (self.canvas_events_done) return;
    self.canvas_events_done = true;
    // Sockets have all rendered by now; anything they should see goes to next frame.
    self.sockets_done = true;
    if (!self.interactive()) return;

    self.processWire();
    self.dropSocketSelectionOnOtherPress();
    self.pushNodesMoved();

    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |me| {
                // Right clicks are resolved geometrically: widgets inside nodes may have marked
                // the press handled, but the menu still belongs to whatever is under the mouse.
                if (me.action == .press and me.button == .right and self.mouseOverCanvas(me.p) and
                    (!e.handled or self.nodeAt(me.p) != null))
                {
                    e.handle(@src(), self.box.data());
                    const target: ContextTarget = if (self.socketAt(me.p)) |s|
                        .{ .socket = s }
                    else if (self.nodeAt(me.p)) |n| blk: {
                        if (!self.isSelected(n)) self.pushEvent(.{ .select = .{ .node = n, .mode = .replace } });
                        break :blk .{ .node = n };
                    } else .canvas;
                    self.pushEvent(.{ .context_menu = .{
                        .target = target,
                        .point = self.data_rs.pointFromPhysical(me.p),
                        .point_natural = me.p.toNatural(),
                    } });
                    continue;
                }
                if (!self.box.matchEvent(e)) continue;
                self.processCanvasMouse(e, me);
            },
            .key => |ke| {
                if (!self.box.matchEvent(e)) continue;
                if (ke.action != .down) continue;
                if (ke.code == .delete or ke.code == .backspace) {
                    e.handle(@src(), self.box.data());
                    self.pushEvent(.delete_selection);
                } else if (ke.code == .escape) {
                    e.handle(@src(), self.box.data());
                    // first cancel a pending click-to-link, then the node selection
                    if (self.state.selected_socket != null) {
                        self.selectSocket(null);
                    } else if (self.anySelected()) {
                        self.pushEvent(.deselect_all);
                    }
                } else if (ke.code == .a and ke.mod.matchBind("ctrl/cmd")) {
                    e.handle(@src(), self.box.data());
                    self.pushEvent(.select_all);
                }
            },
            else => {},
        }
    }
}

fn processCanvasMouse(self: *GraphWidget, e: *dvui.Event, me: dvui.Event.Mouse) void {
    const wd = self.box.data();
    switch (me.action) {
        .focus => {
            e.handle(@src(), wd);
            dvui.focusWidget(wd.id, null, e.num);
        },
        .press => if (me.button.pointer()) {
            e.handle(@src(), wd);
            dvui.captureMouse(wd, e.num);
            dvui.dragPreStart(me.button, me.p, .{ .name = pan_drag_name });
            const mode: ?BoxSelectMode = if (me.mod.matchBind("ctrl/cmd")) .include else if (me.mod.shift()) .exclude else null;
            if (self.init_opts.box_select) {
                if (mode) |m| self.state.box_select = .{ .start = me.p, .current = me.p, .mode = m };
            }
        },
        .release => if (me.button.pointer() and dvui.captured(wd.id)) {
            e.handle(@src(), wd);
            if (self.state.box_select != null) {
                self.endBoxSelect();
            } else if (dvui.dragging(me.p, pan_drag_name) == null and self.anySelected()) {
                self.pushEvent(.deselect_all);
            }
            dvui.captureMouse(null, e.num);
            dvui.dragEnd();
            dvui.refresh(null, @src(), wd.id);
        },
        .motion => if (dvui.captured(wd.id)) {
            e.handle(@src(), wd);
            if (self.state.box_select) |*bs| {
                bs.current = me.p;
                dvui.refresh(null, @src(), wd.id);
            } else if (self.init_opts.pan) {
                if (dvui.dragging(me.p, pan_drag_name)) |dps| {
                    self.view.origin.x -= dps.x / self.data_rs.s;
                    self.view.origin.y -= dps.y / self.data_rs.s;
                    dvui.cursorSet(.hand);
                    dvui.refresh(null, @src(), wd.id);
                }
            }
        },
        .wheel_y => |ticks| if (self.init_opts.zoom) {
            e.handle(@src(), wd);
            self.zoomAround(me.p, @exp(@log(@as(f32, 1.005)) * ticks));
        },
        else => {},
    }
}

/// Multiply the zoom by `factor` keeping the graph point under physical `p` fixed.
// FIXME: `data_rs` is from the start of the frame, so a second zoom (or a pan) in the same frame
// anchors on a stale transform and the point under the cursor drifts.
pub fn zoomAround(self: *GraphWidget, p: Physical, factor: f32) void {
    const anchor = self.data_rs.pointFromPhysical(p);
    const new_scale = std.math.clamp(self.view.scale * factor, self.init_opts.min_zoom, self.init_opts.max_zoom);
    if (new_scale == self.view.scale) return;
    // physical scale per graph unit at the new zoom
    const s = self.data_rs.s / self.view.scale * new_scale;
    self.view.scale = new_scale;
    self.view.origin = .{
        .x = anchor.x - (p.x - self.canvas_rect.x) / s,
        .y = anchor.y - (p.y - self.canvas_rect.y) / s,
    };
    dvui.refresh(null, @src(), self.id());
}

fn rectFromPoints(a: Physical, b: Physical) dvui.Rect.Physical {
    return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .w = @abs(b.x - a.x), .h = @abs(b.y - a.y) };
}

/// Dashed wire from `start` (a socket on `start_side`) to `target`, or to the loose point `free`.
fn drawWirePreview(self: *GraphWidget, start: Physical, start_side: types.Side, target: ?SocketRecord, free: Physical) void {
    const end = if (target) |t| t.center else free;
    // a free end points back toward the source
    const end_dir = if (target) |t| sideDir(t.id.side()) else if (end.x >= start.x) @as(f32, -1) else 1;
    const ws = self.style().preview_edge;
    const es = self.style().edge;
    const pts = draw.edgePointsCurved(arena(), start, sideDir(start_side), end, end_dir, es.curvature, es.min_tangent) catch return;
    const alpha: f32 = if (target != null) 1.0 else ws.loose_opacity;
    const thickness = @max(2, ws.thickness * self.data_rs.s);
    draw.strokeDashed(pts, ws.dash.on, ws.dash.off, .{ .thickness = thickness, .color = draw.paint((ws.color orelse Style.text()).opacity(alpha)), .after = true });
}

fn drawOverlays(self: *GraphWidget) void {
    const theme = dvui.themeGet();
    const mouse = dvui.currentWindow().mouse_pt;

    if (self.state.wire) |w| {
        const target_rec = if (self.wire_target) |t| self.recordAnyFrame(t) else null;
        self.drawWirePreview(self.socketCenter(w.source) orelse w.start, w.source.side(), if (target_rec) |r| r else null, mouse);
        dvui.cursorSet(.crosshair);
    }

    // click-to-link: preview the edge a click on the hovered socket would create
    if (self.state.selected_socket) |sel| preview: {
        if (!self.init_opts.click_to_link or !self.mouseOverCanvas(mouse)) break :preview;
        const hovered = self.socketAt(mouse) orelse break :preview;
        if (!self.canLink(sel, hovered)) break :preview;
        const start = self.socketCenter(sel) orelse break :preview;
        self.drawWirePreview(start, sel.side(), self.record(hovered), mouse);
    }

    if (self.state.box_select) |bs| {
        const r = rectFromPoints(bs.start, bs.current).intersect(self.canvas_rect);
        if (!r.empty()) {
            const ss = self.style().selection;
            const fill = switch (bs.mode) {
                .include => ss.include_fill orelse theme.color(.highlight, .fill).opacity(0.15),
                .exclude => ss.exclude_fill orelse theme.color(.err, .fill).opacity(0.12),
            };
            var b = dvui.Path.Builder.init(arena());
            defer b.deinit();
            b.addRect(r, .all(ss.corner_radius));
            const path = b.build();
            const cw = dvui.currentWindow();
            if (path.dupe(cw.arena())) |p| {
                cw.addRenderCommand(.{ .pathFillConvex = .{ .path = p, .opts = .{ .color = draw.paint(fill) } } }, true);
            } else |_| {}
            dvui.Path.stroke(path, .{ .thickness = 1, .color = draw.paint(ss.outline orelse Style.text()), .closed = true, .after = true });
        }
    }

    if (self.style().canvas.vignette) |v| {
        const opacity = if (theme.dark) v.opacity else v.opacity * v.light_theme_factor;
        inline for (.{ .top, .bottom, .left, .right }) |side| draw.edgeShadow(self.canvas_rect, side, v.size, opacity);
    }
}

fn connectedChanged(self: *GraphWidget) bool {
    if (self.connected.items.len != self.prev_connected.len) return true;
    for (self.connected.items, self.prev_connected) |a, b| if (!a.eql(b)) return true;
    return false;
}

pub fn deinit(self: *GraphWidget) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;

    self.processCanvasEvents();
    self.drawOverlays();

    _ = dvui.snapToPixelsSet(self.prev_snap);
    _ = dvui.renderingSet(self.prev_rendering);
    self.scaler.deinit();

    const wd_id = self.id();
    if (self.connectedChanged()) dvui.refresh(null, @src(), wd_id);
    dvui.dataSetSlice(null, wd_id, "_sockets", self.sockets.items);
    dvui.dataSetSlice(null, wd_id, "_nodes", self.nodes.items);
    dvui.dataSetSlice(null, wd_id, "_connected", self.connected.items);
    if (self.late_socket_events.items.len > 0) {
        dvui.dataSetSlice(null, wd_id, "_late_socket_events", self.late_socket_events.items);
        dvui.refresh(null, @src(), wd_id);
    }
    if (self.state.wire != null) {
        self.state.wire_target = self.wire_target;
        dvui.refresh(null, @src(), wd_id);
    }
    // a selected socket that is no longer drawn is gone
    if (self.state.selected_socket) |sel| {
        if (self.interactive() and self.record(sel) == null) self.state.selected_socket = null;
    }

    dvui.clipSet(self.prev_clip);
    self.box.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
