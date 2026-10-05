# dvui-node-graph

Node graph editor widgets for [dvui](https://github.com/david-vanderson/dvui), extracted from the
[graphl](https://graphl.tech) IDE. Pan/zoom canvas with an adaptive grid, draggable and
box-selectable node cards, proximity-scaled sockets, bezier edges, and drag-to-connect wires.

Requires zig 0.16 and the dvui fork pinned in `build.zig.zon`.

```sh
zig build demo          # interactive SDL3 demo
zig build test          # headless interaction tests
zig build test-images   # same tests on SDL3, writes PNGs to snapshots/images
```

## Imperative API

```zig
const ng = @import("dvui_node_graph");

var graph = ng.graph(@src(), .{}, .{});
defer graph.deinit();

// a node with default port rows
graph.baseNode(@src(), 1, struct { x: i32 }{ .x = 5 }, struct { s: []const u8 }{ .s = "" });

{
    var node = graph.node(@src(), 2, struct { s: []const u8 }{ .s = "" }, struct {}{}, .{ .title = "two" }, .{});
    defer node.deinit();

    for (0..node.inputs.len()) |i| {
        var row = ng.BaseInput.init(@src(), node, i, .{ .id_extra = i });
        defer row.deinit();
        // anything drawn here lands beside the socket
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
    .link_created => {}, // wire released on a compatible socket
    .link_dropped => {}, // wire released on empty canvas, `.point` is graph space
    .link_clicked => {},
    .nodes_moved => {}, // `.nodes` moved by `.delta`
    .delete_selection => {},
    .context_menu => {}, // right click on canvas/node/socket
    else => {},
};
```

A socket within a node is an `ng.Socket`, a `packed struct(u32)` holding a 1-bit side
(`input`/`output`) and a 31-bit index; `ng.SocketId` pairs one with a `NodeId`. Edges may join
any two sides. Users can only drag wires between opposite sides unless the graph is created with
`.allow_same_side_links = true`.

Widgets compose, and each wrapper exposes the events of the widget it wraps through a variant of
its own event union: `BaseInput.Event.socket` carries a `BaseSocket.Event`, which splits into
`.mouse` and `.wire`. `BaseSocket` can also be used directly.

The library never owns your graph. It reports what the user did (`link_created`,
`nodes_moved`, ...) and you decide what to change and redeclare next frame. Node positions,
the view and the selection persist in dvui's data store under the graph's id. To keep a node
position yourself, pass `.position = &my_point` in `BaseNode.InitOptions`; to keep the view,
pass `.view = &my_view` in `GraphWidget.InitOptions`.

A node's inputs and outputs are each an `ng.Ports`, stored as a struct of arrays: `names`,
plus optional `sockets`, `values`, `type_names`, `kinds` and `colors` columns. Leave a column
empty to use its default for every port. Ports can come from a struct value (field names, type
names and formatted literals) or be built by hand for runtime-defined nodes. Port widgets take
an index into these columns. `sockets` maps a port to a `Socket` when sockets are not simply
numbered by position, and `kinds` picks `.value`, `.flow` (arrow) or `.plus` (create-on-use
slot).

Any `BaseSocket` can also be placed freely with `.rect` in its options, e.g. a `.plus` socket
hovering between two rows. Set its `wire_source` to the socket the wire should come from: on
press, create that socket (say, by inserting an array element), and the wire continues from it.
Wire drags are owned by the graph, not the pressed widget, so the "+" can disappear meanwhile.

## Declarative API

Built entirely on the imperative API:

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

## Customization points

These exist for apps like the graphl IDE that keep their own graph model:

- `GraphWidget.InitOptions.view`: own the pan/zoom (`origin` is the graph point at the canvas
  top-left, `scale` the zoom), e.g. to animate fit-to-view.
- `GraphWidget.InitOptions.selection`: back the selection with your own storage through a small
  vtable (`isSelected`, `setSelected`, `clear`, `list`).
- `BaseNode.InitOptions.position`: own each node's position. Drags write through the pointer and
  report `nodes_moved` (with the delta) once released, ready for an undo stack.
- `BaseSocket.InitOptions.{filled, color, kind, scale}`: draw state from your model.
- `BaseSocket.InitOptions.wire_source` with `.rect` placement: "+" slots that create a socket
  on press and continue the wire from it.
- `GraphWidget.InitOptions.interactive = false`: draw a graph that ignores input (drag
  previews). `grid` / `edge_shadows` / `pan` / `zoom` / `box_select` toggle the rest.
- `LinkOptions.{color, hover_color, dashed, hidden}`; `GraphWidget.edgePoints`,
  `socketCenter`, `nodeRect` and `lastFrameSocket` expose geometry for your own overlays and hit
  tests (e.g. dropping a node onto an edge to splice it in).

Ctrl/cmd-drag on empty canvas adds nodes to the selection; shift-drag removes them.

## Event lifetimes

Event payloads that contain slices (`nodes_moved.nodes`) point into the dvui frame arena. Copy
them if you need them after the frame.

## Using another dvui backend

The exported `dvui_node_graph` module imports an SDL3 dvui. A program may contain only one dvui,
so with any other backend, create a module from `src/dvui_node_graph.zig` and give it your own
`dvui` import (see `addNodeGraphModule` in `build.zig`).
