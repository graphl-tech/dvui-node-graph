//! Node graph widgets for dvui.
//!
//! Widgets: `GraphWidget` (canvas), `Node` (card), `SocketArea` (the node's socket
//! columns), `Input`/`Output` (socket rows), `SocketWidget` (the socket itself).
//! Higher-level widgets surface the events of the widgets they wrap through nested event unions,
//! e.g. `Input.Event.socket` carries `SocketWidget.Event`.

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
pub const Node = @import("Node.zig");
pub const SocketArea = @import("SocketArea.zig");
pub const SocketWidget = @import("SocketWidget.zig");
const socket_row = @import("socket_row.zig");
pub const SocketRow = socket_row.SocketRow;
pub const Input = socket_row.Input;
pub const Output = socket_row.Output;

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
