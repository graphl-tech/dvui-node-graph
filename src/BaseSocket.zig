//! A connection pin. Draws itself, grows as the mouse approaches, and starts wire drags.
//!
//! Place it in a layout (default), or anywhere with `.rect` in its dvui options: e.g. a `.plus`
//! socket hovering between two rows that inserts a new row when used.
//!
//! Events are known by the end of `init`, so `events()` is valid right after it.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const draw = @import("draw.zig");
const GraphWidget = @import("GraphWidget.zig");

const SocketId = types.SocketId;

const BaseSocket = @This();

pub const InitOptions = struct {
    kind: types.SocketKind = .value,
    /// Defaults to the theme's control text color.
    color: ?dvui.Color = null,
    /// Draw as connected. Defaults to whether an edge used this socket last frame.
    filled: ?bool = null,
    /// Pull the socket outward so it straddles the node border (by `style.node.padding`).
    edge_overlap: bool = true,
    /// Socket a wire dragged out of this one starts from. Lets a `.plus` slot create a socket on
    /// press and have the wire continue from the created socket.
    wire_source: ?SocketId = null,
    /// Proximity scale override in [0, 1]; null uses the graph's proximity animation.
    scale: ?f32 = null,
    /// Look of a `.flow` socket; null uses the graph's `style.socket.flow_style`.
    flow_style: ?types.FlowStyle = null,
};

pub const Click = struct {
    button: dvui.enums.Button,
    mod: dvui.enums.Mod,
    p: dvui.Point.Physical,
};

pub const MouseEvent = union(enum) {
    /// Pointer pressed on the socket (a wire drag may follow).
    press: Click,
    /// Pressed and released without dragging a wire.
    click: Click,
};

pub const WireEvent = union(enum) {
    /// The user started dragging a wire out of this socket.
    start,
    /// The wire from this socket was released on a compatible socket.
    connect: SocketId,
    /// The wire from this socket was released over nothing. Graph-space point.
    drop: dvui.Point,
};

pub const Event = union(enum) {
    mouse: MouseEvent,
    wire: WireEvent,
};

wd: dvui.WidgetData,
graph: *GraphWidget,
socket: SocketId,
init_opts: InitOptions,
events_list: std.ArrayList(Event) = .empty,
hover: bool = false,
/// True while a wire being dragged from elsewhere would connect here.
wire_target: bool = false,

pub fn init(src: std.builtin.SourceLocation, graph: *GraphWidget, socket: SocketId, init_opts: InitOptions, opts: dvui.Options) *BaseSocket {
    const self = dvui.widgetAlloc(BaseSocket);
    self.initInPlace(src, graph, socket, init_opts, opts);
    return self;
}

/// It's expected to call this when `self` is `undefined`.
pub fn initInPlace(self: *BaseSocket, src: std.builtin.SourceLocation, graph: *GraphWidget, socket: SocketId, init_opts: InitOptions, opts: dvui.Options) void {
    const r = graph.style().socket.radius;
    const pull = r + graph.style().node.padding;
    const defaults: dvui.Options = .{
        .name = "Socket",
        .min_size_content = .{ .w = 2 * r, .h = 2 * r },
        .max_size_content = .size(.{ .w = 2 * r, .h = 2 * r }),
        .gravity_y = 0.5,
        .gravity_x = if (socket.side() == .output) 1 else 0,
        .margin = if (!init_opts.edge_overlap) .{} else switch (socket.side()) {
            .input => .{ .x = -pull },
            .output => .{ .w = -pull },
        },
        .id_extra = socket.socket.index,
    };
    self.* = .{
        .wd = .init(src, .{}, defaults.override(opts)),
        .graph = graph,
        .socket = socket,
        .init_opts = init_opts,
    };
    self.wd.register();
    if (graph.interactive()) {
        self.processEvents();
        graph.takeSocketEvents(socket, &self.events_list);
    }

    const slot = self.wd.borderRectScale().r;
    const center = draw.rectCenter(slot);
    const radius = @min(slot.w, slot.h) * 0.5;

    if (graph.wireSource()) |src_socket| {
        if (graph.canLink(src_socket, socket) and dvui.currentWindow().mouse_pt.diff(center).length() <= radius) {
            self.wire_target = true;
            graph.setWireTarget(socket);
            dvui.cursorSet(.crosshair);
        }
    }

    graph.registerSocket(socket, center, radius);
    self.drawSocket(slot);
}

pub fn data(self: *BaseSocket) *dvui.WidgetData {
    return self.wd.validate();
}

pub fn events(self: *const BaseSocket) []const Event {
    return self.events_list.items;
}

pub fn hovered(self: *const BaseSocket) bool {
    return self.hover or self.wire_target;
}

/// Physical border rect of the socket slot (full size, independent of proximity scale).
pub fn rect(self: *BaseSocket) dvui.Rect.Physical {
    return self.data().borderRectScale().r;
}

pub fn matchEvent(self: *BaseSocket, e: *dvui.Event) bool {
    return dvui.eventMatchSimple(e, self.data());
}

fn processEvents(self: *BaseSocket) void {
    const wd = self.data();
    for (dvui.events()) |*e| {
        if (!self.matchEvent(e) or e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            // Sockets never take keyboard focus; the canvas keeps it so graph hotkeys work.
            .focus => {
                e.handle(@src(), wd);
                dvui.focusWidget(self.graph.id(), null, e.num);
            },
            .press => if (me.button.pointer()) {
                e.handle(@src(), wd);
                self.graph.pressSocket(self.socket, self.init_opts.wire_source orelse self.socket, me, e.num);
                self.events_list.append(dvui.currentWindow().arena(), .{
                    .mouse = .{ .press = .{ .button = me.button, .mod = me.mod, .p = me.p } },
                }) catch {};
            },
            .position => {
                self.hover = true;
                dvui.cursorSet(.crosshair);
            },
            else => {},
        }
    }
}

fn drawSocket(self: *BaseSocket, slot: dvui.Rect.Physical) void {
    const scale = self.init_opts.scale orelse if (self.hovered()) 1.0 else self.graph.socketScale(self.socket);
    const s = std.math.clamp(scale, 0, 1);
    const r: dvui.Rect.Physical = .{
        .x = slot.x + slot.w * (1 - s) * 0.5,
        .y = slot.y + slot.h * (1 - s) * 0.5,
        .w = slot.w * s,
        .h = slot.h * s,
    };
    const theme = dvui.themeGet();
    const ss = self.graph.style().socket;
    var color = self.init_opts.color orelse theme.color(.control, .text);
    if (self.hovered()) color = color.lerp(theme.color(.highlight, .fill), ss.hover_tint);
    const filled = self.init_opts.filled orelse self.graph.isConnected(self.socket);
    switch (self.init_opts.kind) {
        .value => draw.valueSocket(r, filled, color, self.graph.canvas_fill, ss.ring_ratio),
        .flow => switch (self.init_opts.flow_style orelse ss.flow_style) {
            .triangle => draw.flowSocket(r, filled, color, self.graph.canvas_fill),
            .icon => |icon| draw.iconSocket(r, filled, color, self.graph.canvas_fill, icon.name, icon.tvg, ss.unconnected_icon_opacity),
        },
        .plus => draw.plusSocket(r, color, self.graph.canvas_fill, ss.ring_ratio),
    }
}

pub fn deinit(self: *BaseSocket) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;
    self.data().minSizeSetAndRefresh();
    // A socket placed with `.rect` floats over its parent and must not grow it.
    if (self.data().options.rect == null) self.data().minSizeReportToParent();
}

test {
    std.testing.refAllDecls(@This());
}
