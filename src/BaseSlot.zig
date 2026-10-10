//! A place where a socket could be created, e.g. a "+" between two rows of a list. It is not a
//! socket: nothing links to it. Instead:
//! - a wire dropped on it emits `GraphWidget.Event.slot_linked`; create the socket and link it.
//! - pressing it emits `.mouse.press` and starts a wire from `becomes`; create that socket on
//!   press and the wire continues from it, even if the slot itself disappears.
//!
//! It grows with mouse proximity like a socket. Place it in a row, or anywhere with `.rect`.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const Style = @import("Style.zig");
const GraphWidget = @import("GraphWidget.zig");
const pin_mod = @import("pin.zig");

const SlotId = types.SlotId;
const SocketId = types.SocketId;

const BaseSlot = @This();

pub const Click = pin_mod.Click;
pub const MouseEvent = pin_mod.MouseEvent;
pub const WireEvent = pin_mod.WireEvent;
pub const Event = pin_mod.Event;

pub const InitOptions = struct {
    /// The socket this slot would become. Wires dragged out of the slot start from it, and only
    /// wires that could connect to it can be dropped here.
    becomes: SocketId,
    /// Overrides the graph's `style.slot`.
    style: ?Style.Slot = null,
    /// Defaults to the theme's control text color.
    color: ?dvui.Color = null,
    /// Pull the slot outward so it straddles the node border, like a socket.
    edge_overlap: bool = false,
    /// Proximity scale override in [0, 1]; null uses the graph's proximity animation.
    scale: ?f32 = null,
};

pin: pin_mod.Pin,
slot: SlotId,

pub fn init(src: std.builtin.SourceLocation, graph: *GraphWidget, slot: SlotId, init_opts: InitOptions, opts: dvui.Options) *BaseSlot {
    const self = dvui.widgetAlloc(BaseSlot);
    self.initInPlace(src, graph, slot, init_opts, opts);
    return self;
}

/// It's expected to call this when `self` is `undefined`.
pub fn initInPlace(self: *BaseSlot, src: std.builtin.SourceLocation, graph: *GraphWidget, slot: SlotId, init_opts: InitOptions, opts: dvui.Options) void {
    self.* = .{ .pin = undefined, .slot = slot };
    const defaults: dvui.Options = .{ .name = "Slot", .id_extra = slot.index };
    self.pin.init(src, graph, .{ .slot = slot }, init_opts.becomes, init_opts.becomes, init_opts.edge_overlap, defaults.override(opts));

    const ss = init_opts.style orelse graph.style().slot;
    self.pin.drawLook(.{
        .icon = ss.icon,
        .color = init_opts.color orelse dvui.themeGet().color(.control, .text),
        .background = ss.background,
        .scale = init_opts.scale,
    });
}

pub fn data(self: *BaseSlot) *dvui.WidgetData {
    return self.pin.wd.validate();
}

pub fn events(self: *const BaseSlot) []const Event {
    return self.pin.events_list.items;
}

pub fn hovered(self: *const BaseSlot) bool {
    return self.pin.hovered();
}

/// Physical border rect of the slot (full size, independent of proximity scale).
pub fn rect(self: *BaseSlot) dvui.Rect.Physical {
    return self.pin.rect();
}

pub fn deinit(self: *BaseSlot) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;
    self.pin.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
