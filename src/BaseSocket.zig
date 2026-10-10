//! A connection pin. Draws an icon, grows as the mouse approaches, and starts wire drags.
//!
//! Lay it out in a row (usually through `BaseInput`/`BaseOutput`) or place it anywhere with
//! `.rect` in its dvui options. Events are known by the end of `init`, so `events()` is valid
//! right after it.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const Style = @import("Style.zig");
const GraphWidget = @import("GraphWidget.zig");
const pin_mod = @import("pin.zig");

const SocketId = types.SocketId;

const BaseSocket = @This();

pub const Click = pin_mod.Click;
pub const MouseEvent = pin_mod.MouseEvent;
pub const WireEvent = pin_mod.WireEvent;
pub const Event = pin_mod.Event;

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

pin: pin_mod.Pin,
socket: SocketId,
init_opts: InitOptions,

pub fn init(src: std.builtin.SourceLocation, graph: *GraphWidget, socket: SocketId, init_opts: InitOptions, opts: dvui.Options) *BaseSocket {
    const self = dvui.widgetAlloc(BaseSocket);
    self.initInPlace(src, graph, socket, init_opts, opts);
    return self;
}

/// It's expected to call this when `self` is `undefined`.
pub fn initInPlace(self: *BaseSocket, src: std.builtin.SourceLocation, graph: *GraphWidget, socket: SocketId, init_opts: InitOptions, opts: dvui.Options) void {
    self.* = .{ .pin = undefined, .socket = socket, .init_opts = init_opts };
    const defaults: dvui.Options = .{ .id_extra = socket.socket.index };
    self.pin.init(src, graph, .{ .socket = socket }, socket, socket, init_opts.edge_overlap, defaults.override(opts));

    const ss = init_opts.style orelse graph.style().socket;
    const connected = init_opts.connected orelse graph.isConnected(socket);
    self.pin.drawLook(.{
        .icon = if (connected) ss.icon_connected orelse ss.icon else ss.icon,
        .color = init_opts.color orelse dvui.themeGet().color(.control, .text),
        .opacity = if (connected) 1 else ss.unconnected_opacity,
        .background = ss.background,
        .scale = init_opts.scale,
    });
}

pub fn data(self: *BaseSocket) *dvui.WidgetData {
    return self.pin.wd.validate();
}

pub fn events(self: *const BaseSocket) []const Event {
    return self.pin.events_list.items;
}

pub fn hovered(self: *const BaseSocket) bool {
    return self.pin.hovered();
}

/// Physical border rect of the socket (full size, independent of proximity scale).
pub fn rect(self: *BaseSocket) dvui.Rect.Physical {
    return self.pin.rect();
}

pub fn deinit(self: *BaseSocket) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;
    self.pin.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
