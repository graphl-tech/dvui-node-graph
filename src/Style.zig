//! Visual style of a graph. Every field defaults to the stock look, so start from
//! `Style.default` and change what you need:
//!
//!     var style = ng.Style.default;
//!     style.edge.shadow = null;
//!     var graph = ng.graph(@src(), .{ .style = style }, .{});
//!
//! Colors left null are derived from the dvui theme each frame. Shadows and decorations are
//! optional; null turns them off.

const dvui = @import("dvui");

const Style = @This();

pub const default: Style = .{};

node: Node = .{},
edge: Edge = .{},
wire: Wire = .{},
socket: Socket = .{},
canvas: Canvas = .{},
selection: Selection = .{},
label: Label = .{},

pub const Node = struct {
    corner_radius: f32 = 12,
    border_width: f32 = 1,
    /// Space between the card border and its content. Sockets with `edge_overlap` are pulled out
    /// by this much so they straddle the border.
    padding: f32 = 5,
    /// Theme window fill.
    fill: ?dvui.Color = null,
    /// `fill` blended 6% toward the theme text color.
    fill_hover: ?dvui.Color = null,
    /// `fill` blended 12% toward the theme highlight.
    fill_selected: ?dvui.Color = null,
    fill_opacity: f32 = 0.92,
    /// Theme border.
    border: ?dvui.Color = null,
    /// Theme text blended 30% toward the theme border.
    border_hover: ?dvui.Color = null,
    /// Theme focus color.
    border_selected: ?dvui.Color = null,
    /// `corners` defaults to `corner_radius`.
    shadow: ?dvui.Options.BoxShadow = .{ .alpha = 0.25, .fade = 10 },
};

pub const Dash = struct {
    on: f32 = 14,
    off: f32 = 8.75,
};

pub const EdgeShadow = struct {
    /// Natural pixels at zoom 1.
    offset: dvui.Point = .{ .y = 3 },
    color: dvui.Color = dvui.Color.black.opacity(0.3),
};

pub const Edge = struct {
    /// Natural pixels at zoom 1.
    thickness: f32 = 2,
    /// Theme text color.
    color: ?dvui.Color = null,
    dashed: bool = false,
    dash: Dash = .{},
    shadow: ?EdgeShadow = .{},
    /// How far the curve leaves each socket horizontally, as a fraction of the edge length.
    curvature: f32 = 0.3,
    /// Lower bound on that distance (physical pixels), so short edges still bend.
    min_tangent: f32 = 30,
    /// Theme highlight.
    hover_color: ?dvui.Color = null,
    hover_extra_thickness: f32 = 2,
    hover_dashed: bool = true,
};

/// The wire that follows the mouse while connecting sockets.
pub const Wire = struct {
    /// Theme text color.
    color: ?dvui.Color = null,
    /// Natural pixels at zoom 1 (never thinner than 2 physical pixels).
    thickness: f32 = 1.5,
    /// Opacity while the wire is not over a socket it could connect to.
    loose_opacity: f32 = 0.6,
    dash: Dash = .{},
};

/// A TinyVG icon. dvui caches renders by `name`, so use a distinct name per icon.
pub const Icon = struct {
    name: []const u8,
    tvg: []const u8,
};

/// Look and sizing of sockets. Override per port with `Ports.styles` or per socket with
/// `BaseSocket.InitOptions.style`. Size and proximity fields are read from the graph's style.
pub const Socket = struct {
    /// Graph units at full proximity scale.
    radius: f32 = 10,
    /// Physical pixels from the mouse at which the nearest socket starts growing.
    proximity: f32 = 40,
    /// Scale when the mouse is far away.
    rest_scale: f32 = 0.5,
    /// Drawn while unconnected.
    icon: Icon = .{ .name = "dvui_node_graph_socket", .tvg = dvui.entypo.circle },
    /// Drawn while connected; null keeps `icon`.
    icon_connected: ?Icon = .{ .name = "dvui_node_graph_socket_connected", .tvg = dvui.entypo.controller_record },
    /// Opacity of the icon while unconnected.
    unconnected_opacity: f32 = 1,
    /// Fill a disk of the canvas color behind the icon, so edges end at its outline.
    background: bool = true,
    /// How far a hovered socket's color blends toward the theme highlight.
    hover_tint: f32 = 0.35,
};

pub const Grid = struct {
    /// Graph units between minor lines at zoom 1.
    spacing: f32 = 100,
    /// Preferred on-screen spacing (physical pixels); the grid steps by factors of 10 around it.
    target_spacing: f32 = 75,
    /// Theme text color.
    color: ?dvui.Color = null,
    minor_opacity: f32 = 0.06,
    major_opacity: f32 = 0.19,
    minor_thickness: f32 = 1,
    major_thickness: f32 = 1.5,
};

/// Darkening along the inside of the canvas edges.
pub const Vignette = struct {
    size: f32 = 30,
    opacity: f32 = 0.25,
    /// Light themes use `opacity * light_theme_factor`.
    light_theme_factor: f32 = 0.5,
};

pub const Canvas = struct {
    corner_radius: f32 = 10,
    /// Theme content fill.
    fill: ?dvui.Color = null,
    grid: ?Grid = .{},
    vignette: ?Vignette = .{},
};

/// The box drawn while box-selecting.
pub const Selection = struct {
    /// Theme highlight at 15%.
    include_fill: ?dvui.Color = null,
    /// Theme error color at 12%.
    exclude_fill: ?dvui.Color = null,
    /// Theme text color.
    outline: ?dvui.Color = null,
    corner_radius: f32 = 6,
};

/// Default port labels (`BaseInput.defaultLabel` / `BaseOutput.defaultLabel`).
pub const Label = struct {
    /// Theme monospace font, one size smaller.
    font: ?dvui.Font = null,
    /// Opacity of an input's literal value shown beside its name.
    value_opacity: f32 = 0.6,
};

/// The theme text color, used as the default for most strokes.
pub fn text() dvui.Color {
    return dvui.themeGet().color(.control, .text);
}
