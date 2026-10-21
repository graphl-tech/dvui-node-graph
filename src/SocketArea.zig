//! The part of a node that holds its socket rows: inputs stack in a left column and outputs in a
//! right column. Declare all inputs before any outputs. Get one from `Node.socketArea`.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const Node = @import("Node.zig");
const socket_row = @import("socket_row.zig");

const SocketArea = @This();

node: *Node,
body: dvui.BoxWidget = undefined,
column: dvui.BoxWidget = undefined,
column_side: ?types.Side = null,

pub fn init(src: std.builtin.SourceLocation, node: *Node, opts: dvui.Options) *SocketArea {
    const self = dvui.widgetAlloc(SocketArea);
    self.* = .{ .node = node };
    node.area_open = true;
    const defaults: dvui.Options = .{ .expand = .horizontal };
    self.body.init(src, .{ .dir = .horizontal }, defaults.override(opts));
    return self;
}

/// Make the column for `side` the current parent. Used by `Input`/`Output`.
pub fn beginColumn(self: *SocketArea, side: types.Side) void {
    if (self.column_side) |s| {
        if (s == side) return;
        if (s == .output) {
            dvui.log.err("dvui_node_graph: node {d} declared an input after its outputs", .{self.node.id});
        }
        self.column.deinit();
    }
    self.column.init(@src(), .{ .dir = .vertical }, .{
        .gravity_x = if (side == .output) 1 else 0,
        .id_extra = @backingInt(side),
    });
    self.column_side = side;
}

/// Row for input socket `index` showing `name`.
pub fn managedInput(self: *SocketArea, src: std.builtin.SourceLocation, index: usize, name: []const u8, opts: dvui.Options) void {
    var w = socket_row.Input.init(src, self, index, opts);
    defer w.deinit();
    dvui.label(@src(), "{s}", .{name}, .{});
}

/// Row for output socket `index` showing `name`.
pub fn managedOutput(self: *SocketArea, src: std.builtin.SourceLocation, index: usize, name: []const u8, opts: dvui.Options) void {
    var w = socket_row.Output.init(src, self, index, opts);
    defer w.deinit();
    dvui.label(@src(), "{s}", .{name}, .{});
}

pub fn deinit(self: *SocketArea) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;
    if (self.column_side != null) self.column.deinit();
    self.body.deinit();
    self.node.area_open = false;
}

test {
    std.testing.refAllDecls(@This());
}
