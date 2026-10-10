//! A connection pin. Draws an icon, grows as the mouse approaches, and starts wire drags.
//!
//! Lay it out in a row (usually through `BaseInput`/`BaseOutput`) or place it anywhere with
//! `.rect` in its dvui options. A socket doesn't have to exist in your model: a "+" that adds an
//! input is just a socket with a plus icon whose id is the input you would add; handle
//! `link_created`/`socket_clicked` for it by creating that input.
//!
//! Events are known by the end of `init`, so `events()` is valid right after it.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const draw = @import("draw.zig");
const Style = @import("Style.zig");
const GraphWidget = @import("GraphWidget.zig");

const SocketId = types.SocketId;

const BaseSocket = @This();

pub const InitOptions = struct {
    /// Overrides the graph's `style.socket` icons for this socket.
    style: ?Style.Socket = null,
    /// Defaults to the theme's control text color.
    color: ?dvui.Color = null,
    /// Draw as connected. Defaults to whether an edge used this socket last frame.
    connected: ?bool = null,
    /// Pull the socket outward so it straddles the node border (by `style.node.padding`).
    edge_overlap: bool = true,
    /// Proximity scale override in [0, 1]; null uses the graph's proximity animation.
    scale: ?f32 = null,
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
    /// The wire from this socket was released on a socket it can connect to.
    connect: SocketId,
    /// The wire from this socket was released over nothing it can connect to. Graph-space point.
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

    const border = self.wd.borderRectScale().r;
    const center = draw.rectCenter(border);
    const radius = @min(border.w, border.h) * 0.5;
    if (graph.wireSource()) |w| {
        if (graph.canLink(w, socket) and dvui.currentWindow().mouse_pt.diff(center).length() <= radius) {
            self.wire_target = true;
            graph.setWireTarget(socket);
            dvui.cursorSet(.crosshair);
        }
    }
    graph.registerSocket(socket, center, radius);
    self.drawSocket(border);
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

/// Physical border rect of the socket (full size, independent of proximity scale).
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
                self.graph.pressSocket(self.socket, me, e.num);
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
    const ss = self.init_opts.style orelse self.graph.style().socket;
    const connected = self.init_opts.connected orelse self.graph.isConnected(self.socket);
    const scale = self.init_opts.scale orelse if (self.hovered()) 1.0 else self.graph.socketScale(self.socket);
    const s = std.math.clamp(scale, 0, 1);
    const r: dvui.Rect.Physical = .{
        .x = slot.x + slot.w * (1 - s) * 0.5,
        .y = slot.y + slot.h * (1 - s) * 0.5,
        .w = slot.w * s,
        .h = slot.h * s,
    };
    const theme = dvui.themeGet();
    var color = self.init_opts.color orelse theme.color(.control, .text);
    if (self.hovered()) color = color.lerp(theme.color(.highlight, .fill), self.graph.style().socket.hover_tint);
    if (!connected) color = color.opacity(ss.unconnected_opacity);
    const icon = if (connected) ss.icon_connected orelse ss.icon else ss.icon;
    draw.socketIcon(r, icon, color, if (ss.background) self.graph.canvas_fill else null);
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
