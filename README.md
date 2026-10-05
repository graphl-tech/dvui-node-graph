# dvui-node-graph

Node graph editor widgets for [dvui](https://github.com/david-vanderson/dvui), extracted from the
[graphl](https://graphl.tech) IDE. Pan/zoom canvas with an adaptive grid, draggable and
box-selectable node cards, proximity-scaled sockets, bezier edges, and drag-to-connect wires.

Requires zig 0.16 and the dvui fork pinned in `build.zig.zon`.

```sh
zig build demo          # interactive SDL3 demo
zig build test          # unit tests + headless interaction tests
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
    .link_created => {}, // wire released on a compatible socket (opposite sides: output -> input)
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
`nodes_moved`, ...) and you decide what to change and redeclare next frame. Unless you pass your
own (see below), node positions, the view and the selection persist in dvui's data store under
the graph's id. dvui frees entries that go a frame without use, so a library-owned node position
is forgotten if that node isn't declared for a frame; pass `.position` if nodes come and go.

Node positions are graph-space top-left corners. While nodes are dragged, every selected node
moves by the same `GraphWidget.node_drag_delta` each frame, written through its position; the
drag ends with one `nodes_moved` event carrying the total delta. Set `apply_drag = false` on a
node to apply the delta yourself.

A node's inputs and outputs are each an `ng.Ports`, stored as a struct of arrays: `names`,
plus optional `sockets`, `values`, `type_names`, `kinds` and `colors` columns. Leave a column
empty to use its default for every port. The library has no notion of value types: map your
types to `colors` (sockets default to the theme's control text color, and
`BaseSocket.InitOptions.color` overrides per socket). `type_names` is informational only;
nothing in the library draws it. Ports can come from a struct value (field names, type
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

## Input

- drag empty canvas: pan; mouse wheel: zoom around the cursor
- ctrl/cmd-drag on empty canvas: add nodes to the selection; shift-drag: remove them
- click a node: select it (ctrl/cmd adds, shift removes); drag it: move the selection
- drag from a socket: wire; click a socket: `socket_clicked`; click an edge: `link_clicked`
- right click: `context_menu` for the canvas, node or socket under the mouse
- with the canvas focused: delete/backspace emits `delete_selection`, escape clears the
  selection, ctrl/cmd+A selects all

## Event lifetimes

Event payloads that contain slices (`nodes_moved.nodes`) point into the dvui frame arena. Copy
them if you need them after the frame.

## Using another dvui backend

The exported `dvui_node_graph` module imports an SDL3 dvui. A program may contain only one dvui,
so with any other backend, create a module from `src/dvui_node_graph.zig` and give it your own
`dvui` import (see `addNodeGraphModule` in `build.zig`).
