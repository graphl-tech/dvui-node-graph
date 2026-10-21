//! `Input` / `Output`: one row of a node's `SocketArea` holding a socket plus
//! caller-supplied content (labels, literal editors, ...). Anything created between `init` and
//! `deinit` lands in the row's content box, beside the socket.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const Node = @import("Node.zig");
const SocketArea = @import("SocketArea.zig");
const SocketWidget = @import("SocketWidget.zig");

pub const Input = SocketRow(.input);
pub const Output = SocketRow(.output);

pub fn SocketRow(comptime side: types.Side) type {
    return struct {
        const Self = @This();

        pub const Event = union(enum) {
            /// Events from the row's socket.
            socket: SocketWidget.Event,
        };

        pub const InitOptions = struct {
            socket: SocketWidget.InitOptions = .{},
            /// dvui options for the socket widget (e.g. `.tag`).
            socket_opts: dvui.Options = .{},
        };

        node: *Node,
        /// The socket's index on its side: the row is socket `(side, index)` of its node.
        index: u31,
        row: dvui.BoxWidget = undefined,
        content: dvui.BoxWidget = undefined,
        events_list: []const Event = &.{},
        socket_hovered: bool = false,
        /// Physical rect of the socket slot.
        socket_rect: dvui.Rect.Physical = .{},

        pub fn init(src: std.builtin.SourceLocation, area: *SocketArea, index: usize, opts: dvui.Options) *Self {
            return initEx(src, area, index, .{}, opts);
        }

        pub fn initEx(src: std.builtin.SourceLocation, area: *SocketArea, index: usize, init_opts: InitOptions, opts: dvui.Options) *Self {
            const self = dvui.widgetAlloc(Self);
            const node = area.node;
            self.* = .{ .node = node, .index = @intCast(index) };
            area.beginColumn(side);

            const gravity_x: f32 = if (side == .output) 1 else 0;
            const defaults: dvui.Options = .{ .expand = .horizontal, .gravity_x = gravity_x };
            self.row.init(src, .{ .dir = .horizontal }, defaults.override(opts));

            var socket = SocketWidget.init(@src(), node.graph, self.socketId(), init_opts.socket, init_opts.socket_opts);
            const socket_events = socket.events();
            self.socket_hovered = socket.hovered();
            self.socket_rect = socket.rect();
            socket.deinit();

            if (socket_events.len > 0) {
                if (dvui.currentWindow().arena().alloc(Event, socket_events.len)) |evs| {
                    for (evs, socket_events) |*dst, se| dst.* = .{ .socket = se };
                    self.events_list = evs;
                } else |_| {}
            }

            // gravity_x = 1 packs from the right, so output content sits left of its socket.
            self.content.init(@src(), .{ .dir = .horizontal }, .{ .gravity_x = gravity_x, .gravity_y = 0.5 });
            return self;
        }

        pub fn events(self: *const Self) []const Event {
            return self.events_list;
        }

        pub fn socketId(self: *const Self) types.SocketId {
            return .{ .node = self.node.id, .socket = .{ .side = side, .index = self.index } };
        }

        pub fn deinit(self: *Self) void {
            defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
            defer self.* = undefined;
            self.content.deinit();
            self.row.deinit();
        }
    };
}

test {
    std.testing.refAllDecls(Input);
    std.testing.refAllDecls(Output);
}
