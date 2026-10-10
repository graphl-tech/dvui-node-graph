//! Shared core of `BaseSocket` and `BaseSlot`: a round, pressable target that grows as the mouse
//! approaches, starts wire drags, and accepts dropped wires. Internal; use those two widgets.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const draw = @import("draw.zig");
const Style = @import("Style.zig");
const GraphWidget = @import("GraphWidget.zig");

const SocketId = types.SocketId;
const Target = types.Target;

pub const Click = struct {
    button: dvui.enums.Button,
    mod: dvui.enums.Mod,
    p: dvui.Point.Physical,
};

pub const MouseEvent = union(enum) {
    /// Pointer pressed (a wire drag may follow).
    press: Click,
    /// Pressed and released without dragging a wire.
    click: Click,
};

pub const WireEvent = union(enum) {
    /// The user started dragging a wire out of this socket or slot.
    start,
    /// The wire was released on a socket or slot it can connect to.
    connect: Target,
    /// The wire was released over nothing it can connect to. Graph-space point.
    drop: dvui.Point,
};

pub const Event = union(enum) {
    mouse: MouseEvent,
    wire: WireEvent,
};

pub const Look = struct {
    icon: Style.Icon,
    color: dvui.Color,
    opacity: f32 = 1,
    background: bool,
    /// Proximity scale override in [0, 1].
    scale: ?f32 = null,
};

pub const Pin = struct {
    wd: dvui.WidgetData,
    graph: *GraphWidget,
    target: Target,
    /// The socket this is, or would become; decides what it can link to.
    socket: SocketId,
    events_list: std.ArrayList(Event) = .empty,
    hover: bool = false,
    /// True while a wire being dragged from elsewhere would connect here.
    wire_target: bool = false,

    /// `wire_source` is where a wire dragged out of this pin starts.
    pub fn init(
        self: *Pin,
        src: std.builtin.SourceLocation,
        graph: *GraphWidget,
        target: Target,
        socket: SocketId,
        wire_source: SocketId,
        edge_overlap: bool,
        opts: dvui.Options,
    ) void {
        const r = graph.style().socket.radius;
        const pull = r + graph.style().node.padding;
        const defaults: dvui.Options = .{
            .name = "Socket",
            .min_size_content = .{ .w = 2 * r, .h = 2 * r },
            .max_size_content = .size(.{ .w = 2 * r, .h = 2 * r }),
            .gravity_y = 0.5,
            .gravity_x = if (socket.side() == .output) 1 else 0,
            .margin = if (!edge_overlap) .{} else switch (socket.side()) {
                .input => .{ .x = -pull },
                .output => .{ .w = -pull },
            },
        };
        self.* = .{
            .wd = .init(src, .{}, defaults.override(opts)),
            .graph = graph,
            .target = target,
            .socket = socket,
        };
        self.wd.register();
        if (graph.interactive()) {
            self.processEvents(wire_source);
            graph.takeTargetEvents(target, &self.events_list);
        }

        const border = self.wd.borderRectScale().r;
        const center = draw.rectCenter(border);
        const radius = @min(border.w, border.h) * 0.5;
        if (graph.wireSource()) |w| {
            if (graph.canLink(w, socket) and dvui.currentWindow().mouse_pt.diff(center).length() <= radius) {
                self.wire_target = true;
                graph.setWireTarget(target);
                dvui.cursorSet(.crosshair);
            }
        }
        graph.registerTarget(target, socket, center, radius);
    }

    pub fn hovered(self: *const Pin) bool {
        return self.hover or self.wire_target;
    }

    pub fn rect(self: *Pin) dvui.Rect.Physical {
        return self.wd.validate().borderRectScale().r;
    }

    fn processEvents(self: *Pin, wire_source: SocketId) void {
        const wd = self.wd.validate();
        for (dvui.events()) |*e| {
            if (!dvui.eventMatchSimple(e, wd) or e.evt != .mouse) continue;
            const me = e.evt.mouse;
            switch (me.action) {
                // Pins never take keyboard focus; the canvas keeps it so graph hotkeys work.
                .focus => {
                    e.handle(@src(), wd);
                    dvui.focusWidget(self.graph.id(), null, e.num);
                },
                .press => if (me.button.pointer()) {
                    e.handle(@src(), wd);
                    self.graph.pressTarget(self.target, wire_source, me, e.num);
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

    pub fn drawLook(self: *Pin, look: Look) void {
        const slot = self.rect();
        const scale = look.scale orelse if (self.hovered()) 1.0 else self.graph.targetScale(self.target);
        const s = std.math.clamp(scale, 0, 1);
        const r: dvui.Rect.Physical = .{
            .x = slot.x + slot.w * (1 - s) * 0.5,
            .y = slot.y + slot.h * (1 - s) * 0.5,
            .w = slot.w * s,
            .h = slot.h * s,
        };
        var color = look.color;
        if (self.hovered()) color = color.lerp(dvui.themeGet().color(.highlight, .fill), self.graph.style().socket.hover_tint);
        draw.socketIcon(r, look.icon, color.opacity(look.opacity), if (look.background) self.graph.canvas_fill else null);
    }

    pub fn deinit(self: *Pin) void {
        const wd = self.wd.validate();
        wd.minSizeSetAndRefresh();
        // A pin placed with `.rect` floats over its parent and must not grow it.
        if (wd.options.rect == null) wd.minSizeReportToParent();
    }
};
