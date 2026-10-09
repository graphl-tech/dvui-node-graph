# dvui-node-graph

Node graph editor widgets for [dvui](https://github.com/david-vanderson/dvui)
Has both imperative and a declarative APIs.

Requires zig 0.16. The `dvui_node_graph` module brings no dvui of its own; give it yours:

```zig
const ng_mod = b.dependency("dvui_node_graph", .{}).module("dvui_node_graph");
ng_mod.addImport("dvui", dvui_module);
```

```sh
zig build demo          # interactive SDL3 demo
zig build test          # unit tests + headless interaction tests
zig build test-images   # same tests on SDL3, writes PNGs to snapshots/images
```

## Imperative API

```zig
const ng = @import("dvui_node_graph");

var positions = [_]dvui.Point{ .{ .x = 20, .y = 40 }, .{ .x = 260, .y = 140 } };

// start from the default style and override what you need
var style = ng.Style.default;
style.edge.shadow = null;
style.node.corner_radius = 4;

var graph = ng.graph(@src(), .{ .style = style }, .{});
defer graph.deinit();

// a default node
graph.baseNode(@src(), 1, &positions[0], struct { x: i32 }{ .x = 5 }, struct { s: []const u8 }{ .s = "" });

{
    var node = graph.node(@src(), 2, &positions[1], struct { s: []const u8 }{ .s = "" }, struct {}{}, .{ .title = "two" }, .{});
    defer node.deinit();

    for (0..node.inputs.len()) |i| {
        var row = ng.BaseInput.init(@src(), node, i, .{ .id_extra = i });
        defer row.deinit();
        // anything drawn here lands next to the socket
        dvui.label(@src(), "{s}", .{row.name()}, .{});

        for (row.events()) |e| switch (e) {
            .socket => |se| switch (se) {
                .mouse => |me| switch (me) {
                    .click => |click| std.log.info("clicked at {any}", .{click.p}),
                    .press => {},
                },
                .wire => |we| switch (we) {
                    .start => {},
                    .connect => |other| std.log.info("wired to {any}", .{other}),
                    .drop => |graph_point| std.log.info("dropped at {any}", .{graph_point}),
                },
            },
        };
    }
    for (0..node.outputs.len()) |i| node.baseOutput(@src(), i, .{ .id_extra = i });
}

// edges go after the nodes that own their sockets
_ = graph.link(1, .output(0), 2, .input(0)); // node 1's first output -> node 2's first input

for (graph.events()) |e| switch (e) {
    .link_created => {}, // wire released on a compatible socket (opposite sides: output -> input)
    .link_dropped => {}, // wire released on empty canvas, `.point` is graph space
    .link_clicked => {},
    .nodes_moved => {}, // `.nodes` moved by `.delta`
    .delete_selection => {},
    .context_menu => {}, // right click on canvas/node/socket
    else => {},
};
```

Higher level widgets expose the events of the widget it wraps through a variant of
its own event union. e.g. `BaseInput.Event.socket` carries a `BaseSocket.Event`, which splits into
`.mouse` and `.wire`. `BaseSocket` can also be used directly.

## Declarative API

```zig
const Add = ng.declarative.NodeType(struct { a: i32, b: i32 }, struct { sum: i32 });

const events = ng.declarative.graph(@src(), &app, .{
    .nodes = &.{ Add.nodeAt(1, "add", .{ .x = 20, .y = 20 }), Add.node(2, "add") },
    .edges = &.{.{ .source = .output(1, 0), .target = .input(2, 0) }},
    .draw_input_label = App.drawInputLabel, // fn (*App, *ng.BaseInput, ng.declarative.Node) void
    .on_click_socket = App.onClickSocket, // fn (*App, ng.SocketId, ng.BaseSocket.Click) void
    .on_event = App.onEvent, // fn (*App, ng.GraphWidget.Event) void
}, .{});
```

The first argument after `@src()` is a context passed to every callback, and it can be any type.
