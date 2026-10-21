//! Pointer drag helpers that work with dvui's single-drag API and its newer per-pointer one.

const dvui = @import("dvui");

const per_pointer = @hasField(dvui.Dragging, "fingers");

/// See `dvui.dragging`.
pub fn dragging(me: dvui.Event.Mouse, name: ?[]const u8) ?dvui.Point.Physical {
    return dvui.dragging(if (per_pointer) me else me.p, name);
}

/// Stop the drag started by `button`.
pub fn end(button: dvui.enums.Button) void {
    if (per_pointer) dvui.dragEnd(button) else dvui.dragEnd();
}

/// True when no pointer is dragging or about to.
pub fn none() bool {
    const d = &dvui.currentWindow().dragging;
    if (!per_pointer) return d.state == .none;
    for (d.fingers) |f| if (f.state != .none) return false;
    return true;
}
