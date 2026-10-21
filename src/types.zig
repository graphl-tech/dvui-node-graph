const std = @import("std");

/// Caller-chosen stable identifier for a node. Must be unique within a graph.
pub const NodeId = u64;

pub const Side = enum(u1) {
    input,
    output,

    pub fn opposite(self: Side) Side {
        return switch (self) {
            .input => .output,
            .output => .input,
        };
    }
};

/// A socket within a node: which side it is on and its index on that side.
pub const Socket = packed struct(u32) {
    side: Side,
    index: u31,

    pub fn input(index: u31) Socket {
        return .{ .side = .input, .index = index };
    }

    pub fn output(index: u31) Socket {
        return .{ .side = .output, .index = index };
    }

    pub fn eql(a: Socket, b: Socket) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

/// Identifies one socket on one node.
pub const SocketId = struct {
    node: NodeId,
    socket: Socket,

    pub fn input(node: NodeId, index: u31) SocketId {
        return .{ .node = node, .socket = .input(index) };
    }

    pub fn output(node: NodeId, index: u31) SocketId {
        return .{ .node = node, .socket = .output(index) };
    }

    pub fn side(self: SocketId) Side {
        return self.socket.side;
    }

    pub fn eql(a: SocketId, b: SocketId) bool {
        return a.node == b.node and a.socket.eql(b.socket);
    }

    /// Whether an edge may join `a` and `b`: different nodes, and opposite sides unless
    /// `allow_same_side` (e.g. a graph where outputs can feed outputs).
    pub fn canLink(a: SocketId, b: SocketId, allow_same_side: bool) bool {
        return a.node != b.node and (allow_same_side or a.side() != b.side());
    }
};

/// A directed edge from `source` to `target`. Sides are not constrained, so an edge may join
/// two outputs or two inputs.
pub const Edge = struct {
    source: SocketId,
    target: SocketId,

    /// Order an output/input pair so `source` is the output. Same-side pairs keep their order.
    pub fn normalized(a: SocketId, b: SocketId) Edge {
        return if (a.side() == .input and b.side() == .output) .{ .source = b, .target = a } else .{ .source = a, .target = b };
    }

    pub fn eql(a: Edge, b: Edge) bool {
        return a.source.eql(b.source) and a.target.eql(b.target);
    }
};

test "Edge.normalized" {
    const e = Edge.normalized(SocketId.input(2, 0), SocketId.output(1, 3));
    try std.testing.expect(e.source.eql(SocketId.output(1, 3)));
    try std.testing.expect(e.target.eql(SocketId.input(2, 0)));

    const same = Edge.normalized(SocketId.output(2, 0), SocketId.output(1, 3));
    try std.testing.expect(same.source.eql(SocketId.output(2, 0)));
}

test Socket {
    try std.testing.expectEqual(32, @bitSizeOf(Socket));
    const s: Socket = .output(5);
    try std.testing.expectEqual(@as(u32, (5 << 1) | 1), @as(u32, @bitCast(s)));
    try std.testing.expect(!SocketId.output(1, 0).canLink(.output(2, 0), false));
    try std.testing.expect(SocketId.output(1, 0).canLink(.output(2, 0), true));
    try std.testing.expect(!SocketId.output(1, 0).canLink(.input(1, 0), true));
}
