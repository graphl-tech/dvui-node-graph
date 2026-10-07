//! `BaseInput` / `BaseOutput`: one row of a node holding a socket plus caller-supplied content
//! (labels, literal editors, ...). Anything created between `init` and `deinit` lands in the
//! row's content box, beside the socket.

const std = @import("std");
const dvui = @import("dvui");

const types = @import("types.zig");
const BaseNode = @import("BaseNode.zig");
const BaseSocket = @import("BaseSocket.zig");
const draw = @import("draw.zig");

pub const BaseInput = PortWidget(.input);
pub const BaseOutput = PortWidget(.output);

pub fn PortWidget(comptime side: types.Side) type {
    return struct {
        const Self = @This();

        pub const Event = union(enum) {
            /// Events from the row's socket.
            socket: BaseSocket.Event,
        };

        pub const InitOptions = struct {
            /// Overrides the port's kind/color columns and the socket defaults.
            socket: ?BaseSocket.InitOptions = null,
            /// dvui options for the socket widget (e.g. `.tag`).
            socket_opts: dvui.Options = .{},
        };

        node: *BaseNode,
        /// Index into the node's `inputs`/`outputs`.
        index: usize,
        row: dvui.BoxWidget = undefined,
        content: dvui.BoxWidget = undefined,
        events_list: []const Event = &.{},
        socket_hovered: bool = false,
        /// Physical rect of the socket slot.
        socket_rect: dvui.Rect.Physical = .{},

        pub fn init(src: std.builtin.SourceLocation, node: *BaseNode, index: usize, opts: dvui.Options) *Self {
            return initEx(src, node, index, .{}, opts);
        }

        pub fn initEx(src: std.builtin.SourceLocation, node: *BaseNode, index: usize, init_opts: InitOptions, opts: dvui.Options) *Self {
            const self = dvui.widgetAlloc(Self);
            self.* = .{ .node = node, .index = index };
            const ps = self.ports();
            node.beginColumn(side);

            const gravity_x: f32 = if (side == .output) 1 else 0;
            const defaults: dvui.Options = .{ .expand = .horizontal, .gravity_x = gravity_x };
            self.row.init(src, .{ .dir = .horizontal }, defaults.override(opts));

            const socket_opts = init_opts.socket orelse BaseSocket.InitOptions{ .kind = ps.kind(index), .color = ps.color(index) };
            var socket = BaseSocket.init(@src(), node.graph, self.socketId(), socket_opts, init_opts.socket_opts);
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

        pub fn ports(self: *const Self) types.Ports {
            return self.node.sidePorts(side);
        }

        pub fn events(self: *const Self) []const Event {
            return self.events_list;
        }

        pub fn socketId(self: *const Self) types.SocketId {
            return self.ports().socketId(self.node.id, self.index);
        }

        pub fn name(self: *const Self) []const u8 {
            return self.ports().names[self.index];
        }

        /// The port name, plus its literal value for inputs that are not connected.
        pub fn defaultLabel(self: *Self) void {
            const ls = self.node.graph.style().label;
            const font = ls.font orelse dvui.themeGet().font_mono.larger(-2);
            dvui.labelEx(@src(), "{s}", .{self.name()}, .{ .ellipsize = false }, .{ .font = font, .gravity_y = 0.5, .padding = .all(2) });
            if (side == .input) {
                if (self.ports().value(self.index)) |v| {
                    if (!self.node.graph.isConnected(self.socketId())) {
                        dvui.labelEx(@src(), "{s}", .{v}, .{ .ellipsize = false }, .{
                            .font = font,
                            .gravity_y = 0.5,
                            .padding = .all(2),
                            .color_text = draw.paint(dvui.themeGet().color(.control, .text).opacity(ls.value_opacity)),
                        });
                    }
                }
            }
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
    std.testing.refAllDecls(BaseInput);
    std.testing.refAllDecls(BaseOutput);
}
