//! Node graph widgets for dvui.
//!
//! Widgets: `GraphWidget` (canvas), `ManagedNode` (card), `SocketArea` (the node's socket
//! columns), `ManagedInput`/`ManagedOutput` (socket rows), `ManagedSocket` (the socket itself).
//! Higher-level widgets surface the events of the widgets they wrap through nested event unions,
//! e.g. `ManagedInput.Event.socket` carries `ManagedSocket.Event`.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
pub const NodeId = types.NodeId;
pub const Side = types.Side;
pub const Socket = types.Socket;
pub const SocketId = types.SocketId;
pub const Edge = types.Edge;

pub const Style = @import("Style.zig");
pub const GraphWidget = @import("GraphWidget.zig");
pub const ManagedNode = @import("ManagedNode.zig");
pub const SocketArea = @import("SocketArea.zig");
pub const ManagedSocket = @import("ManagedSocket.zig");
const socket_row = @import("socket_row.zig");
pub const SocketRow = socket_row.SocketRow;
pub const ManagedInput = socket_row.ManagedInput;
pub const ManagedOutput = socket_row.ManagedOutput;

pub const draw = @import("draw.zig");

/// Begin a graph canvas. See `GraphWidget`.
pub fn graph(src: std.builtin.SourceLocation, init_opts: GraphWidget.InitOptions, opts: dvui.Options) *GraphWidget {
    return GraphWidget.init(src, init_opts, opts);
}

test {
    std.testing.refAllDecls(@This());
    _ = types;
    _ = draw;
}
