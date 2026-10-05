const std = @import("std");
const dvui = @import("dvui");

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

/// Visual style of a socket.
pub const SocketKind = enum {
    /// Donut pin, filled when connected (data/value flow).
    value,
    /// Arrow pin (control/execution flow).
    flow,
    /// "+" in a ring: a slot that creates a socket when used (e.g. inserting an array element).
    plus,
};

/// The inputs or the outputs of one node, as a struct of arrays. `names` sets the port count;
/// every other column is optional and may be left empty to use its default for all ports.
pub const Ports = struct {
    side: Side,
    names: []const []const u8 = &.{},
    /// Socket of each port. Empty means positional: port `i` is socket `(side, i)`.
    sockets: []const Socket = &.{},
    /// Formatted literal values (e.g. "5" for `.{ .x = 5 }`).
    values: []const ?[]const u8 = &.{},
    type_names: []const []const u8 = &.{},
    kinds: []const SocketKind = &.{},
    colors: []const ?dvui.Color = &.{},

    pub fn none(side: Side) Ports {
        return .{ .side = side };
    }

    pub fn len(self: Ports) usize {
        return self.names.len;
    }

    pub fn socket(self: Ports, i: usize) Socket {
        return if (i < self.sockets.len) self.sockets[i] else .{ .side = self.side, .index = @intCast(i) };
    }

    pub fn socketId(self: Ports, node: NodeId, i: usize) SocketId {
        return .{ .node = node, .socket = self.socket(i) };
    }

    pub fn value(self: Ports, i: usize) ?[]const u8 {
        return if (i < self.values.len) self.values[i] else null;
    }

    pub fn typeName(self: Ports, i: usize) ?[]const u8 {
        return if (i < self.type_names.len) self.type_names[i] else null;
    }

    pub fn kind(self: Ports, i: usize) SocketKind {
        return if (i < self.kinds.len) self.kinds[i] else .value;
    }

    pub fn color(self: Ports, i: usize) ?dvui.Color {
        return if (i < self.colors.len) self.colors[i] else null;
    }

    /// Index of the port using `s`, if any.
    pub fn indexOf(self: Ports, s: Socket) ?usize {
        for (0..self.len()) |i| if (self.socket(i).eql(s)) return i;
        return null;
    }
};

/// Build one side's ports from either a `Ports` or a struct value whose fields become ports in
/// declaration order. Allocates from `alloc` (normally the dvui arena).
pub fn ports(alloc: std.mem.Allocator, comptime side: Side, from: anytype) std.mem.Allocator.Error!Ports {
    const T = @TypeOf(from);
    if (T == Ports) return from;
    if (@typeInfo(T) != .@"struct") @compileError("expected a struct value or Ports, found " ++ @typeName(T));

    const fields = @typeInfo(T).@"struct".fields;
    const meta = comptime portsOfType(T, side);
    const values = try alloc.alloc(?[]const u8, fields.len);
    inline for (fields, 0..) |f, i| values[i] = try formatValue(alloc, @field(from, f.name));
    var out = meta;
    out.values = values;
    return out;
}

/// Ports for a struct *type* (names and type names, no values). Usable at comptime.
pub fn portsOfType(comptime T: type, comptime side: Side) Ports {
    const S = struct {
        const fields = @typeInfo(T).@"struct".fields;
        const names = blk: {
            var out: [fields.len][]const u8 = undefined;
            for (fields, 0..) |f, i| out[i] = f.name;
            const final = out;
            break :blk final;
        };
        const type_names = blk: {
            var out: [fields.len][]const u8 = undefined;
            for (fields, 0..) |f, i| out[i] = @typeName(f.type);
            const final = out;
            break :blk final;
        };
    };
    return .{ .side = side, .names = &S.names, .type_names = &S.type_names };
}

fn formatValue(alloc: std.mem.Allocator, v: anytype) std.mem.Allocator.Error!?[]const u8 {
    const V = @TypeOf(v);
    return switch (@typeInfo(V)) {
        .void, .null, .undefined => null,
        .int, .comptime_int, .float, .comptime_float => try std.fmt.allocPrint(alloc, "{d}", .{v}),
        .bool => if (v) "true" else "false",
        .@"enum", .enum_literal => @tagName(v),
        .optional => if (v) |inner| try formatValue(alloc, inner) else null,
        .pointer => |p| if (p.size == .slice and p.child == u8)
            try std.fmt.allocPrint(alloc, "\"{s}\"", .{v})
        else if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8)
            try std.fmt.allocPrint(alloc, "\"{s}\"", .{v})
        else
            null,
        else => null,
    };
}

test ports {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ps = try ports(arena_state.allocator(), .input, .{ .x = @as(i32, 5), .s = @as([]const u8, "hi"), .b = true });
    try std.testing.expectEqual(3, ps.len());
    try std.testing.expectEqualStrings("x", ps.names[0]);
    try std.testing.expectEqualStrings("5", ps.value(0).?);
    try std.testing.expectEqualStrings("\"hi\"", ps.value(1).?);
    try std.testing.expectEqualStrings("true", ps.value(2).?);
    try std.testing.expect(ps.socket(2).eql(.input(2)));
    try std.testing.expectEqual(SocketKind.value, ps.kind(2));
}

test portsOfType {
    const ps = comptime portsOfType(struct { a: f32, b: u8 }, .output);
    try std.testing.expectEqual(2, ps.len());
    try std.testing.expectEqualStrings("b", ps.names[1]);
    try std.testing.expectEqualStrings("u8", ps.typeName(1).?);
    try std.testing.expect(ps.socket(1).eql(.output(1)));
}

test "Ports with explicit sockets" {
    const ps: Ports = .{
        .side = .input,
        .names = &.{ "exec", "value" },
        .sockets = &.{ .input(0), .input(7) },
        .kinds = &.{.flow},
    };
    try std.testing.expect(ps.socket(1).eql(.input(7)));
    try std.testing.expectEqual(SocketKind.flow, ps.kind(0));
    try std.testing.expectEqual(SocketKind.value, ps.kind(1));
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
