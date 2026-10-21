const std = @import("std");
const dvui = @import("dvui");

const Style = @import("Style.zig");

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

    /// Whether a wire may join `a` and `b`: different nodes, and opposite sides unless
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

/// The input or the output sockets of one node.
/// Socket count is derived from `names`, other slices
/// can have less entries to use a default.
pub const Sockets = struct {
    side: Side,
    names: []const []const u8 = &.{},
    /// Id of each socket. Empty means positional: socket `i` is `(side, i)`.
    ids: []const Socket = &.{},
    colors: []const ?dvui.Color = &.{},
    /// Per-socket look (icons, ...); null uses the graph's `style.socket`.
    styles: []const ?Style.Socket = &.{},

    // TODO: rename to empty, maybe empty_input and empty_output instead of .empty(.input)
    pub fn none(side: Side) Sockets {
        return .{ .side = side };
    }

    pub fn len(self: Sockets) usize {
        return self.names.len;
    }

    pub fn socket(self: Sockets, i: usize) Socket {
        return if (i < self.ids.len) self.ids[i] else .{ .side = self.side, .index = @intCast(i) };
    }

    pub fn socketId(self: Sockets, node: NodeId, i: usize) SocketId {
        return .{ .node = node, .socket = self.socket(i) };
    }

    pub fn style(self: Sockets, i: usize) ?Style.Socket {
        return if (i < self.styles.len) self.styles[i] else null;
    }

    pub fn color(self: Sockets, i: usize) ?dvui.Color {
        return if (i < self.colors.len) self.colors[i] else null;
    }

    /// Index of the socket `s`, if any.
    pub fn indexOf(self: Sockets, s: Socket) ?usize {
        for (0..self.len()) |i| if (self.socket(i).eql(s)) return i;
        return null;
    }
};

/// Sockets named after the fields of a struct type. Usable at comptime.
pub fn socketsOfType(comptime T: type, comptime side: Side) Sockets {
    const S = struct {
        const fields = @typeInfo(T).@"struct".fields;
        const names = blk: {
            var out: [fields.len][]const u8 = undefined;
            for (fields, 0..) |f, i| out[i] = f.name;
            const final = out;
            break :blk final;
        };
    };
    return .{ .side = side, .names = &S.names };
}

test socketsOfType {
    const ps = comptime socketsOfType(struct { a: f32, b: u8 }, .output);
    try std.testing.expectEqual(2, ps.len());
    try std.testing.expectEqualStrings("b", ps.names[1]);
    try std.testing.expect(ps.socket(1).eql(.output(1)));
}

test "Sockets with explicit ids" {
    const ps: Sockets = .{
        .side = .input,
        .names = &.{ "exec", "value" },
        .ids = &.{ .input(0), .input(7) },
        .colors = &.{dvui.Color.black},
    };
    try std.testing.expect(ps.socket(1).eql(.input(7)));
    try std.testing.expect(ps.color(0) != null);
    try std.testing.expect(ps.color(1) == null);
    try std.testing.expectEqual(1, ps.indexOf(.input(7)).?);
}

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
