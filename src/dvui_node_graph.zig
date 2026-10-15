//! Node graph widgets for dvui.
//!
//! Imperative API: `GraphWidget` (canvas), `BaseNode` (card), `BaseInput`/`BaseOutput` (socket
//! rows), `BaseSocket` (pin). Higher-level widgets surface the events of the widgets they wrap
//! through nested event unions, e.g. `BaseInput.Event.socket` carries `BaseSocket.Event`.
//!
//! Declarative API: `declarative.graph`, built entirely on the imperative one.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
pub const NodeId = types.NodeId;
pub const Side = types.Side;
pub const Socket = types.Socket;
pub const SocketId = types.SocketId;
pub const Edge = types.Edge;
pub const Sockets = types.Sockets;
pub const socketsOfType = types.socketsOfType;

pub const Style = @import("Style.zig");
pub const GraphWidget = @import("GraphWidget.zig");
pub const BaseNode = @import("BaseNode.zig");
pub const BaseSocket = @import("BaseSocket.zig");
const socket_row = @import("socket_row.zig");
pub const SocketRow = socket_row.SocketRow;
pub const BaseInput = socket_row.BaseInput;
pub const BaseOutput = socket_row.BaseOutput;

pub const declarative = @import("declarative.zig");
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
