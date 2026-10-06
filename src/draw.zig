//! Stateless drawing helpers shared by the graph widgets. All coordinates are physical pixels.

const std = @import("std");
const dvui = @import("dvui");

const Point = dvui.Point.Physical;
const Rect = dvui.Rect.Physical;

/// dvui's color argument type: `Color`, or `ColorOrGradient` in newer dvui.
pub const Paint = @FieldType(dvui.Path.StrokeOptions, "color");

pub fn paint(c: dvui.Color) Paint {
    return if (Paint == dvui.Color) c else Paint.fromColor(c);
}

/// A flat color from a `Paint` (a gradient's first stop).
pub fn flat(p: Paint) dvui.Color {
    return if (Paint == dvui.Color) p else p.toColor();
}

pub fn rectCenter(r: Rect) Point {
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}

pub fn cubicBezierPoint(p0: Point, p1: Point, p2: Point, p3: Point, t: f32) Point {
    const u = 1.0 - t;
    const uu = u * u;
    const tt = t * t;
    return .{
        .x = uu * u * p0.x + 3.0 * uu * t * p1.x + 3.0 * u * tt * p2.x + tt * t * p3.x,
        .y = uu * u * p0.y + 3.0 * uu * t * p1.y + 3.0 * u * tt * p2.y + tt * t * p3.y,
    };
}

/// Points along a bezier from `start` to `end`. Each end's tangent leaves horizontally in the
/// direction of its `dir` (+1 right, -1 left): +1 for outputs and -1 for inputs gives the usual
/// "S" curve, and equal directions give the loop used for output -> output edges.
pub fn edgePoints(alloc: std.mem.Allocator, start: Point, start_dir: f32, end: Point, end_dir: f32) std.mem.Allocator.Error![]Point {
    const distance = start.diff(end).length();
    const segments: u32 = std.math.clamp(@as(u32, @intFromFloat(distance / 16)), 1, 32);
    const offset = @max(30, 0.3 * distance);
    const cp1: Point = .{ .x = start.x + start_dir * offset, .y = start.y };
    const cp2: Point = .{ .x = end.x + end_dir * offset, .y = end.y };

    const pts = try alloc.alloc(Point, segments + 1);
    for (pts, 0..) |*p, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        p.* = cubicBezierPoint(start, cp1, cp2, end, t);
    }
    return pts;
}

pub fn distanceToSegment(pt: Point, a: Point, b: Point) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len_sq = dx * dx + dy * dy;
    if (len_sq == 0) return pt.diff(a).length();
    const t = std.math.clamp(((pt.x - a.x) * dx + (pt.y - a.y) * dy) / len_sq, 0.0, 1.0);
    return pt.diff(.{ .x = a.x + t * dx, .y = a.y + t * dy }).length();
}

pub fn distanceToPolyline(pt: Point, pts: []const Point) f32 {
    var best = std.math.floatMax(f32);
    if (pts.len == 1) return pt.diff(pts[0]).length();
    for (0..pts.len -| 1) |i| best = @min(best, distanceToSegment(pt, pts[i], pts[i + 1]));
    return best;
}

/// Stroke `points` as a dashed polyline, measuring dashes along arc length.
pub fn strokeDashed(points: []const Point, dash_len: f32, gap_len: f32, opts: dvui.Path.StrokeOptions) void {
    const n = points.len;
    if (n < 2 or dash_len <= 0) return;
    const arena = dvui.currentWindow().arena();
    const cum = arena.alloc(f32, n) catch return;
    cum[0] = 0;
    for (1..n) |i| cum[i] = cum[i - 1] + points[i].diff(points[i - 1]).length();
    const total = cum[n - 1];
    if (total < 1e-4) return;

    var buf: std.ArrayList(Point) = .empty;
    defer buf.deinit(arena);

    var s: f32 = 0;
    var seg: usize = 0;
    while (s < total) {
        const dash_end = @min(s + dash_len, total);
        buf.clearRetainingCapacity();
        while (seg + 1 < n and cum[seg + 1] <= s) seg += 1;
        buf.append(arena, pointAtArc(points, cum, seg, s)) catch return;
        var k = seg + 1;
        while (k < n and cum[k] < dash_end) : (k += 1) buf.append(arena, points[k]) catch return;
        const end_seg = if (k > 0) k - 1 else 0;
        buf.append(arena, pointAtArc(points, cum, end_seg, dash_end)) catch return;
        dvui.Path.stroke(.{ .points = buf.items }, opts);
        s = dash_end + @max(0, gap_len);
    }
}

fn pointAtArc(points: []const Point, cum: []const f32, seg: usize, s: f32) Point {
    if (seg + 1 >= points.len) return points[points.len - 1];
    const seg_len = cum[seg + 1] - cum[seg];
    if (seg_len < 1e-5) return points[seg + 1];
    const t = std.math.clamp((s - cum[seg]) / seg_len, 0, 1);
    return .{
        .x = points[seg].x + (points[seg + 1].x - points[seg].x) * t,
        .y = points[seg].y + (points[seg + 1].y - points[seg].y) * t,
    };
}

fn circle(center: Point, r: f32) dvui.Path.Builder {
    var b = dvui.Path.Builder.init(dvui.currentWindow().arena());
    b.addArc(center, r, 2 * std.math.pi, 0, false);
    return b;
}

pub fn fillCircle(center: Point, r: f32, color: dvui.Color) void {
    if (r < 0.5) return;
    var b = circle(center, r);
    defer b.deinit();
    dvui.Path.fillConvex(b.build(), .{ .color = paint(color), .center = center });
}

pub fn strokeCircle(center: Point, r: f32, thickness: f32, color: dvui.Color) void {
    if (r < 0.5) return;
    var b = circle(center, r);
    defer b.deinit();
    dvui.Path.stroke(b.build(), .{ .thickness = thickness, .color = paint(color), .closed = true });
}

/// Value pin: a ring in `color` over a disk of `background` (so the hole reads as canvas, not
/// node body), with a filled center when `filled`.
pub fn valueSocket(r: Rect, filled: bool, color: dvui.Color, background: dvui.Color) void {
    const center = rectCenter(r);
    const outer = @min(r.w, r.h) * 0.5;
    if (outer < 0.5) return;
    const inner = outer * 0.6;
    fillCircle(center, outer, background);
    if (filled) fillCircle(center, inner, color);
    strokeCircle(center, (outer + inner) * 0.5, outer - inner, color);
}

/// Flow pin: a right-pointing triangle, solid when `filled`, outlined otherwise.
pub fn flowSocket(r: Rect, filled: bool, color: dvui.Color, background: dvui.Color) void {
    const center = rectCenter(r);
    const half = @min(r.w, r.h) * 0.5;
    if (half < 0.5) return;
    fillCircle(center, half, background);
    const s = half * 0.75;
    var b = dvui.Path.Builder.init(dvui.currentWindow().arena());
    defer b.deinit();
    b.addPoint(.{ .x = center.x - s * 0.6, .y = center.y - s });
    b.addPoint(.{ .x = center.x + s, .y = center.y });
    b.addPoint(.{ .x = center.x - s * 0.6, .y = center.y + s });
    const path = b.build();
    if (filled) dvui.Path.fillConvex(path, .{ .color = paint(color), .center = center });
    dvui.Path.stroke(path, .{ .thickness = @max(1, half * 0.2), .color = paint(color), .closed = true });
}

/// Flow pin drawn as a ring around an icon, both faded when not `filled`.
pub fn iconSocket(r: Rect, filled: bool, color: dvui.Color, background: dvui.Color, name: []const u8, tvg: []const u8) void {
    const center = rectCenter(r);
    const outer = @min(r.w, r.h) * 0.5;
    if (outer < 0.5) return;
    const c = color.opacity(if (filled) 1.0 else 0.33);
    fillCircle(center, outer, background);

    const icon_h = outer * 2 * 0.55;
    const icon_w = dvui.iconWidth(name, tvg, icon_h) catch icon_h;
    const icon_rect: Rect = .{ .x = center.x - icon_w / 2, .y = center.y - icon_h / 2, .w = icon_w, .h = icon_h };
    dvui.renderIcon(name, tvg, .{ .r = icon_rect, .s = 1 }, .{}, .{ .fill_color = paint(c), .stroke_color = paint(c) }) catch {};

    const t = @max(0.5, outer * 0.3);
    strokeCircle(center, outer - t / 2, t, c);
}

/// "+" slot: an empty ring with a plus sign inside.
pub fn plusSocket(r: Rect, color: dvui.Color, background: dvui.Color) void {
    valueSocket(r, false, color, background);
    const center = rectCenter(r);
    const arm = @min(r.w, r.h) * 0.22;
    if (arm < 0.5) return;
    const t = @max(1, arm * 0.45);
    dvui.Path.stroke(.{ .points = &.{ .{ .x = center.x - arm, .y = center.y }, .{ .x = center.x + arm, .y = center.y } } }, .{ .thickness = t, .color = paint(color) });
    dvui.Path.stroke(.{ .points = &.{ .{ .x = center.x, .y = center.y - arm }, .{ .x = center.x, .y = center.y + arm } } }, .{ .thickness = t, .color = paint(color) });
}

fn smoothstep(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}

/// Multi-level grid aligned to graph space that crossfades between decades while zooming so
/// line spacing on screen stays roughly constant.
pub fn grid(viewport: Rect, data_rs: dvui.RectScale, color: dvui.Color) void {
    const base: f32 = 100.0;
    const target_px: f32 = 75.0;
    const zoom_factor = @log10(target_px / (base * data_rs.s));
    const level = @floor(zoom_factor);
    const spacing = base * std.math.pow(f32, 10.0, level);
    const t = std.math.clamp(zoom_factor - level, 0.0, 1.0);
    const fade_out = 1.0 - smoothstep(t);
    const fade_in = smoothstep(t);

    gridLevel(viewport, data_rs, spacing, color.opacity(0.06 * fade_out), 1.0);
    gridLevel(viewport, data_rs, spacing * 10, color.opacity(0.19 * fade_out), 1.5);
    if (t > 0) {
        gridLevel(viewport, data_rs, spacing * 10, color.opacity(0.06 * fade_in), 1.0);
        gridLevel(viewport, data_rs, spacing * 100, color.opacity(0.19 * fade_in), 1.5);
    }
}

fn gridLevel(viewport: Rect, data_rs: dvui.RectScale, spacing: f32, color: dvui.Color, thickness: f32) void {
    if (color.a < 2) return;
    const visible = data_rs.rectFromPhysical(viewport);
    const step = spacing * data_rs.s;
    if (step < 2) return;
    const first = data_rs.pointToPhysical(.{
        .x = @floor(visible.x / spacing) * spacing,
        .y = @floor(visible.y / spacing) * spacing,
    });
    const max_x = viewport.x + viewport.w;
    const max_y = viewport.y + viewport.h;
    var x = first.x;
    while (x < max_x) : (x += step) {
        dvui.Path.stroke(.{ .points = &.{ .{ .x = x, .y = viewport.y }, .{ .x = x, .y = max_y } } }, .{ .thickness = thickness, .color = paint(color) });
    }
    var y = first.y;
    while (y < max_y) : (y += step) {
        dvui.Path.stroke(.{ .points = &.{ .{ .x = viewport.x, .y = y }, .{ .x = max_x, .y = y } } }, .{ .thickness = thickness, .color = paint(color) });
    }
}

pub const ShadowSide = enum { top, bottom, left, right };

/// Inner gradient shadow along one edge of `r`, fading toward the center. Queued after normal
/// drawing so it sits above deferred node bodies.
pub fn edgeShadow(r: Rect, side: ShadowSide, thickness: f32, opacity: f32) void {
    var band = r;
    switch (side) {
        .top => band.h = thickness,
        .bottom => {
            band.y += r.h - thickness;
            band.h = thickness;
        },
        .left => band.w = thickness,
        .right => {
            band.x += r.w - thickness;
            band.w = thickness;
        },
    }
    const arena = dvui.currentWindow().arena();
    var b: dvui.Path.Builder = .init(arena);
    defer b.deinit();
    b.addRect(band, .{});
    const tris = b.build().fillConvexTriangles(arena, .{ .center = band.center(), .color = .white }) catch return;

    const total = if (dvui.themeGet().dark) opacity else opacity * 0.5;
    for (tris.vertexes) |*v| {
        const along = switch (side) {
            .top => (v.pos.y - band.y) / band.h,
            .bottom => 1 - (v.pos.y - band.y) / band.h,
            .left => (v.pos.x - band.x) / band.w,
            .right => 1 - (v.pos.x - band.x) / band.w,
        };
        const a = total * (1 - std.math.clamp(along, 0, 1));
        v.col = v.col.multiply(.fromColor(dvui.Color.black.opacity(a)));
    }
    if (dvui.clipGet().empty()) return;
    dvui.currentWindow().addRenderCommand(.{ .triangles = .{ .tri = tris, .tex = null } }, true);
}

test distanceToSegment {
    const d = distanceToSegment(.{ .x = 5, .y = 3 }, .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 });
    try std.testing.expectApproxEqAbs(3.0, d, 1e-5);
    const end = distanceToSegment(.{ .x = 13, .y = 4 }, .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 });
    try std.testing.expectApproxEqAbs(5.0, end, 1e-5);
}

test edgePoints {
    const pts = try edgePoints(std.testing.allocator, .{ .x = 0, .y = 0 }, 1, .{ .x = 160, .y = 40 }, -1);
    defer std.testing.allocator.free(pts);
    try std.testing.expectEqual(11, pts.len);
    try std.testing.expectApproxEqAbs(0.0, pts[0].x, 1e-4);
    try std.testing.expectApproxEqAbs(40.0, pts[pts.len - 1].y, 1e-4);
}
