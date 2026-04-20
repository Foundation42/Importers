//! Q3 shader → Forge shader graph converter.
//!
//! Converts Quake 3 shader definitions into Forge-compatible shader graph JSON
//! that can be loaded by `shader_serialization.load()`. Also produces render
//! state (blend mode, cull, alpha threshold) for the Material wrapper.
//!
//! Graph topologies produced:
//!   - Diffuse + lightmap: tex(diffuse) × tex(lightmap) → Base Color
//!   - Diffuse only: tex(diffuse) → Base Color
//!   - Additive: tex → Emission
//!   - Alpha-tested: any of the above + tex.A → Alpha
//!
//! Forge-side requirements:
//!   - Add `vertex_uv2` node kind to shader_graph.zig (lightmap UV channel)
//!   - Add `texcoord2` to Vertex struct in mesh.zig (second UV attribute)
//!   - Wire `vertex_uv2` → `fragTexCoord2` in shader_codegen.zig

const std = @import("std");
const q3shader = @import("q3shader.zig");

// ============================================================================
// Public types (mirror Forge's material.zig enums for independence)
// ============================================================================

pub const BlendMode = enum {
    opaque_mode,
    alpha_test,
    alpha_blend,
    additive,
};

pub const CullMode = enum {
    back,
    front,
    none,
};

pub const RenderState = struct {
    blend: BlendMode = .opaque_mode,
    cull: CullMode = .back,
    depth_write: bool = true,
    alpha_threshold: f32 = 0.5,
};

pub const ConvertResult = struct {
    render_state: RenderState,
    /// Diffuse texture path (slot 0). Points into Q3 shader memory — do not free.
    diffuse_path: ?[]const u8,
    /// If true, texture slot 1 should be bound to the lightmap atlas.
    has_lightmap: bool,
    /// Shader graph JSON (Forge GraphLibrary format). Caller owns.
    graph_json: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ConvertResult) void {
        self.allocator.free(self.graph_json);
    }
};

// ============================================================================
// Conversion entry points
// ============================================================================

/// Convert a parsed Q3 shader to a Forge shader graph + render state.
pub fn convert(allocator: std.mem.Allocator, shader: *const q3shader.Shader) !ConvertResult {
    const diffuse_path = shader.getDiffuseMap();
    const has_lightmap = shader.hasLightmap();
    const render_state = analyzeRenderState(shader);
    const is_additive = render_state.blend == .additive;
    const needs_alpha = render_state.blend == .alpha_test or render_state.blend == .alpha_blend;

    var b = GraphBuilder{};

    // Material output — always present
    const mat_out = b.addNode("material_output", 600, 200, .none);

    if (diffuse_path) |path| {
        if (has_lightmap) {
            // Diffuse × Lightmap → Base Color
            const tex_diff = b.addNode("texture_sample", 100, 100, .{ .texture_slot = .{ .slot = 0, .path = path } });
            const tex_lm = b.addNode("texture_sample", 100, 300, .{ .texture_slot = .{ .slot = 1, .path = "$lightmap" } });
            const mul = b.addNode("multiply", 350, 200, .none);
            const uv0 = b.addNode("vertex_uv", -100, 100, .none);
            const uv1 = b.addNode("vertex_uv2", -100, 300, .none);

            b.addLink(uv0.outPin(0), tex_diff.inPin(0)); // UV → diffuse
            b.addLink(uv1.outPin(0), tex_lm.inPin(0)); // UV2 → lightmap
            b.addLink(tex_diff.outPin(1), mul.inPin(0)); // diffuse.RGB → mul.A
            b.addLink(tex_lm.outPin(1), mul.inPin(1)); // lightmap.RGB → mul.B

            if (is_additive) {
                b.addLink(mul.outPin(0), mat_out.inPin(4)); // → Emission
            } else {
                b.addLink(mul.outPin(0), mat_out.inPin(0)); // → Base Color
            }

            if (needs_alpha) {
                b.addLink(tex_diff.outPin(3), mat_out.inPin(5)); // diffuse.A → Alpha
            }
        } else {
            // Diffuse only
            const tex = b.addNode("texture_sample", 200, 200, .{ .texture_slot = .{ .slot = 0, .path = path } });
            const uv0 = b.addNode("vertex_uv", 0, 200, .none);

            b.addLink(uv0.outPin(0), tex.inPin(0)); // UV → texture

            if (is_additive) {
                b.addLink(tex.outPin(1), mat_out.inPin(4)); // RGB → Emission
            } else {
                b.addLink(tex.outPin(1), mat_out.inPin(0)); // RGB → Base Color
            }

            if (needs_alpha) {
                b.addLink(tex.outPin(3), mat_out.inPin(5)); // A → Alpha
            }
        }
    }

    const json = try b.toJson(allocator, shader.name);

    return .{
        .render_state = render_state,
        .diffuse_path = diffuse_path,
        .has_lightmap = has_lightmap,
        .graph_json = json,
        .allocator = allocator,
    };
}

/// Convert an implicit shader (BSP texture path with no .shader definition)
/// to a basic diffuse + lightmap graph.
pub fn convertImplicit(allocator: std.mem.Allocator, texture_path: []const u8) !ConvertResult {
    var b = GraphBuilder{};

    const mat_out = b.addNode("material_output", 600, 200, .none);
    const tex_diff = b.addNode("texture_sample", 100, 100, .{ .texture_slot = .{ .slot = 0, .path = texture_path } });
    const tex_lm = b.addNode("texture_sample", 100, 300, .{ .texture_slot = .{ .slot = 1, .path = "$lightmap" } });
    const mul = b.addNode("multiply", 350, 200, .none);
    const uv0 = b.addNode("vertex_uv", -100, 100, .none);
    const uv1 = b.addNode("vertex_uv2", -100, 300, .none);

    b.addLink(uv0.outPin(0), tex_diff.inPin(0));
    b.addLink(uv1.outPin(0), tex_lm.inPin(0));
    b.addLink(tex_diff.outPin(1), mul.inPin(0));
    b.addLink(tex_lm.outPin(1), mul.inPin(1));
    b.addLink(mul.outPin(0), mat_out.inPin(0));

    const json = try b.toJson(allocator, texture_path);

    return .{
        .render_state = .{},
        .diffuse_path = texture_path,
        .has_lightmap = true,
        .graph_json = json,
        .allocator = allocator,
    };
}

// ============================================================================
// Render state analysis
// ============================================================================

fn analyzeRenderState(shader: *const q3shader.Shader) RenderState {
    var rs = RenderState{};

    // Cull mode: Q3 "front" = front-sided (show front) = Forge "back" (cull back)
    rs.cull = switch (shader.cull) {
        .front => .back,
        .back => .front,
        .none => .none,
    };

    // Find the primary (first non-lightmap) stage to determine blend mode
    var primary_stage: ?q3shader.Stage = null;
    for (shader.stages) |s| {
        if (!s.is_lightmap) {
            primary_stage = s;
            break;
        }
    }

    if (primary_stage) |stage| {
        // Alpha test
        if (stage.alpha_func != .none) {
            rs.blend = .alpha_test;
            rs.alpha_threshold = switch (stage.alpha_func) {
                .gt0 => 0.01,
                .ge128 => 0.5,
                .lt128 => 0.5, // approximate
                .none => 0.5,
            };
            return rs;
        }

        // Blend function analysis
        const src = stage.blend_src;
        const dst = stage.blend_dst;

        if (src == .gl_one and dst == .gl_one) {
            // blendFunc add
            rs.blend = .additive;
            rs.depth_write = false;
        } else if (src == .gl_src_alpha and dst == .gl_one_minus_src_alpha) {
            // blendFunc blend
            rs.blend = .alpha_blend;
            rs.depth_write = false;
        } else if (src == .gl_one and dst == .gl_zero) {
            // Default / opaque (or first pass of multi-pass)
            rs.blend = .opaque_mode;
        } else if (src == .gl_dst_color and dst == .gl_zero) {
            // blendFunc filter (modulate) — typically lightmap pass, opaque overall
            rs.blend = .opaque_mode;
        } else if (src == .gl_src_alpha and dst == .gl_one) {
            // Additive with alpha mask
            rs.blend = .additive;
            rs.depth_write = false;
        } else if (shader.is_transparent or shader.hasSurfaceParm("trans")) {
            rs.blend = .alpha_blend;
            rs.depth_write = false;
        }
    }

    // Override from sort key hints
    if (shader.sort_key) |sort| {
        if (sort >= 9.0) {
            rs.blend = .additive;
            rs.depth_write = false;
        }
    }

    return rs;
}

// ============================================================================
// Graph builder
// ============================================================================

const PIN_BASE: u32 = 100_000;

const NodeRef = struct {
    id: u32,
    first_in: u32, // raw pin ID of first input
    num_in: u32,
    first_out: u32, // raw pin ID of first output
    num_out: u32,

    /// Editor-space pin ID for input at index.
    fn inPin(self: NodeRef, idx: u32) u32 {
        return self.first_in + idx + PIN_BASE;
    }

    /// Editor-space pin ID for output at index.
    fn outPin(self: NodeRef, idx: u32) u32 {
        return self.first_out + idx + PIN_BASE;
    }
};

const NodeData = union(enum) {
    none: void,
    texture_slot: struct { slot: u8, path: []const u8 },
    constant_float: f32,
};

const PinDef = struct {
    name: []const u8,
    pin_type: []const u8,
    default: [4]f32 = .{ 0, 0, 0, 1 },
};

const KindInfo = struct { inputs: []const PinDef, outputs: []const PinDef };

fn kindInfo(kind: []const u8) KindInfo {
    const e = std.mem.eql;
    if (e(u8, kind, "material_output")) return .{
        .inputs = &.{
            .{ .name = "Base Color", .pin_type = "float3" },
            .{ .name = "Roughness", .pin_type = "float1", .default = .{ 0.8, 0, 0, 1 } },
            .{ .name = "Metalness", .pin_type = "float1" },
            .{ .name = "Normal", .pin_type = "float3" },
            .{ .name = "Emission", .pin_type = "float3" },
            .{ .name = "Alpha", .pin_type = "float1", .default = .{ 1, 0, 0, 1 } },
            .{ .name = "AO", .pin_type = "float1", .default = .{ 1, 0, 0, 1 } },
        },
        .outputs = &.{},
    };
    if (e(u8, kind, "texture_sample")) return .{
        .inputs = &.{.{ .name = "UV", .pin_type = "float2" }},
        .outputs = &.{
            .{ .name = "RGBA", .pin_type = "float4" },
            .{ .name = "RGB", .pin_type = "float3" },
            .{ .name = "R", .pin_type = "float1" },
            .{ .name = "A", .pin_type = "float1" },
        },
    };
    if (e(u8, kind, "multiply")) return .{
        .inputs = &.{
            .{ .name = "A", .pin_type = "float3" },
            .{ .name = "B", .pin_type = "float3" },
        },
        .outputs = &.{.{ .name = "Result", .pin_type = "float3" }},
    };
    if (e(u8, kind, "vertex_uv") or e(u8, kind, "vertex_uv2")) return .{
        .inputs = &.{},
        .outputs = &.{.{ .name = "UV", .pin_type = "float2" }},
    };
    if (e(u8, kind, "vertex_normal")) return .{
        .inputs = &.{},
        .outputs = &.{.{ .name = "Normal", .pin_type = "float3" }},
    };
    if (e(u8, kind, "constant_float")) return .{
        .inputs = &.{},
        .outputs = &.{.{ .name = "Value", .pin_type = "float1" }},
    };
    return .{ .inputs = &.{}, .outputs = &.{} };
}

const BuilderNode = struct {
    id: u32,
    kind: []const u8,
    x: f32,
    y: f32,
    data: NodeData,
    first_in: u32, // raw pin ID
    num_in: u8,
    first_out: u32,
    num_out: u8,
};

const BuilderLink = struct {
    id: u32,
    from_pin: u32, // editor-space
    to_pin: u32,
};

const GraphBuilder = struct {
    const MAX_NODES = 16;
    const MAX_LINKS = 16;

    nodes: [MAX_NODES]BuilderNode = undefined,
    node_count: u32 = 0,
    links: [MAX_LINKS]BuilderLink = undefined,
    link_count: u32 = 0,
    next_node_id: u32 = 1,
    next_pin_id: u32 = 1,
    next_link_id: u32 = 1,

    fn addNode(self: *GraphBuilder, kind: []const u8, x: f32, y: f32, data: NodeData) NodeRef {
        const node_id = self.next_node_id;
        self.next_node_id += 1;

        const info = kindInfo(kind);
        const first_in = self.next_pin_id;
        self.next_pin_id += @intCast(info.inputs.len);
        const first_out = self.next_pin_id;
        self.next_pin_id += @intCast(info.outputs.len);

        self.nodes[self.node_count] = .{
            .id = node_id,
            .kind = kind,
            .x = x,
            .y = y,
            .data = data,
            .first_in = first_in,
            .num_in = @intCast(info.inputs.len),
            .first_out = first_out,
            .num_out = @intCast(info.outputs.len),
        };
        self.node_count += 1;

        return .{
            .id = node_id,
            .first_in = first_in,
            .num_in = @intCast(info.inputs.len),
            .first_out = first_out,
            .num_out = @intCast(info.outputs.len),
        };
    }

    fn addLink(self: *GraphBuilder, from_editor_pin: u32, to_editor_pin: u32) void {
        self.links[self.link_count] = .{
            .id = self.next_link_id,
            .from_pin = from_editor_pin,
            .to_pin = to_editor_pin,
        };
        self.link_count += 1;
        self.next_link_id += 1;
    }

    // ── JSON serialization ──

    fn toJson(self: *const GraphBuilder, allocator: std.mem.Allocator, graph_name: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        const w = buf.writer();

        // GraphLibrary header
        try w.writeAll("{\n  \"graph_count\": 1,\n  \"graphs\": [\n    {\n");
        try w.writeAll("      \"name\": ");
        try writeStr(w, "Root");
        try w.writeAll(",\n      \"is_subgraph\": false,\n      \"graph_id\": 0,\n");
        try std.fmt.format(w, "      \"next_node_id\": {d},\n", .{self.next_node_id});
        try std.fmt.format(w, "      \"next_pin_id\": {d},\n", .{self.next_pin_id});
        try std.fmt.format(w, "      \"next_link_id\": {d},\n", .{self.next_link_id});

        // Nodes
        try w.writeAll("      \"nodes\": [");
        for (self.nodes[0..self.node_count], 0..) |node, ni| {
            if (ni > 0) try w.writeAll(",");
            try w.writeAll("\n        ");
            try self.writeNode(w, node);
        }
        if (self.node_count > 0) try w.writeAll("\n      ");
        try w.writeAll("],\n");

        // Pins (derived from nodes)
        try w.writeAll("      \"pins\": [");
        var first_pin = true;
        for (self.nodes[0..self.node_count]) |node| {
            const info = kindInfo(node.kind);
            // Input pins
            for (info.inputs, 0..) |def, pi| {
                if (!first_pin) try w.writeAll(",");
                first_pin = false;
                try w.writeAll("\n        ");
                try writePin(w, node.first_in + @as(u32, @intCast(pi)), node.id, def.name, "in", def.pin_type, def.default);
            }
            // Output pins
            for (info.outputs, 0..) |def, pi| {
                if (!first_pin) try w.writeAll(",");
                first_pin = false;
                try w.writeAll("\n        ");
                try writePin(w, node.first_out + @as(u32, @intCast(pi)), node.id, def.name, "out", def.pin_type, def.default);
            }
        }
        if (!first_pin) try w.writeAll("\n      ");
        try w.writeAll("],\n");

        // Links
        try w.writeAll("      \"links\": [");
        for (self.links[0..self.link_count], 0..) |lnk, li| {
            if (li > 0) try w.writeAll(",");
            try std.fmt.format(w, "\n        {{\"id\": {d}, \"from_pin\": {d}, \"to_pin\": {d}}}", .{ lnk.id, lnk.from_pin, lnk.to_pin });
        }
        if (self.link_count > 0) try w.writeAll("\n      ");
        try w.writeAll("]\n");

        // Close graph and library
        try w.writeAll("    }\n  ],\n");

        // Store shader name and render info as top-level metadata (ignored by Forge loader, useful for tooling)
        try w.writeAll("  \"q3_shader\": ");
        try writeStr(w, graph_name);
        try w.writeAll("\n}\n");

        return buf.toOwnedSlice();
    }

    fn writeNode(self: *const GraphBuilder, w: anytype, node: BuilderNode) !void {
        _ = self;
        try std.fmt.format(w, "{{\"id\": {d}, \"kind\": \"{s}\", \"pos\": [{d:.1}, {d:.1}]", .{
            node.id, node.kind, node.x, node.y,
        });

        // Input pin IDs (editor-space)
        try w.writeAll(", \"in\": [");
        for (0..node.num_in) |i| {
            if (i > 0) try w.writeAll(", ");
            try std.fmt.format(w, "{d}", .{node.first_in + @as(u32, @intCast(i)) + PIN_BASE});
        }
        try w.writeAll("], \"out\": [");
        for (0..node.num_out) |i| {
            if (i > 0) try w.writeAll(", ");
            try std.fmt.format(w, "{d}", .{node.first_out + @as(u32, @intCast(i)) + PIN_BASE});
        }
        try w.writeAll("]");

        // Node data
        try w.writeAll(", \"data\": ");
        switch (node.data) {
            .none => try w.writeAll("null"),
            .texture_slot => |ts| {
                try std.fmt.format(w, "{{\"t\": \"tex\", \"slot\": {d}, \"path\": ", .{ts.slot});
                try writeStr(w, ts.path);
                try w.writeAll("}");
            },
            .constant_float => |v| {
                try std.fmt.format(w, "{{\"t\": \"float\", \"v\": {d:.6}}}", .{v});
            },
        }

        try w.writeAll("}");
    }
};

fn writePin(w: anytype, id: u32, node_id: u32, name: []const u8, pin_kind: []const u8, pin_type: []const u8, default: [4]f32) !void {
    try std.fmt.format(w, "{{\"id\": {d}, \"node\": {d}, \"name\": ", .{ id, node_id });
    try writeStr(w, name);
    try std.fmt.format(w, ", \"kind\": \"{s}\", \"type\": \"{s}\"", .{ pin_kind, pin_type });
    try std.fmt.format(w, ", \"def\": [{d:.6}, {d:.6}, {d:.6}, {d:.6}]}}", .{ default[0], default[1], default[2], default[3] });
}

fn writeStr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            0 => break,
            else => try w.writeByte(ch),
        }
    }
    try w.writeByte('"');
}

// ============================================================================
// Tests
// ============================================================================

test "convert simple diffuse + lightmap shader" {
    const source =
        \\textures/gothic_block/blocks11b
        \\{
        \\    {
        \\        map textures/gothic_block/blocks11b.tga
        \\    }
        \\    {
        \\        map $lightmap
        \\        blendFunc filter
        \\        tcGen lightmap
        \\    }
        \\}
    ;

    var db = q3shader.ShaderDb.init(std.testing.allocator);
    defer db.deinit();
    try db.loadShaderScript(source);

    const shader = db.find("textures/gothic_block/blocks11b").?;
    var result = try convert(std.testing.allocator, shader);
    defer result.deinit();

    // Should have lightmap
    try std.testing.expect(result.has_lightmap);
    try std.testing.expectEqualStrings("textures/gothic_block/blocks11b.tga", result.diffuse_path.?);

    // Render state: opaque, cull back
    try std.testing.expectEqual(BlendMode.opaque_mode, result.render_state.blend);
    try std.testing.expectEqual(CullMode.back, result.render_state.cull);

    // JSON should contain expected node kinds
    try std.testing.expect(std.mem.indexOf(u8, result.graph_json, "\"material_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.graph_json, "\"texture_sample\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.graph_json, "\"multiply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.graph_json, "\"vertex_uv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.graph_json, "\"vertex_uv2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.graph_json, "blocks11b.tga") != null);
}

test "convert alpha-tested shader" {
    const source =
        \\textures/gothic_block/grate
        \\{
        \\    surfaceparm trans
        \\    {
        \\        map textures/gothic_block/grate.tga
        \\        alphaFunc GE128
        \\    }
        \\    {
        \\        map $lightmap
        \\        blendFunc filter
        \\        tcGen lightmap
        \\    }
        \\}
    ;

    var db = q3shader.ShaderDb.init(std.testing.allocator);
    defer db.deinit();
    try db.loadShaderScript(source);

    const shader = db.find("textures/gothic_block/grate").?;
    var result = try convert(std.testing.allocator, shader);
    defer result.deinit();

    try std.testing.expectEqual(BlendMode.alpha_test, result.render_state.blend);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), result.render_state.alpha_threshold, 0.01);
    try std.testing.expect(result.has_lightmap);
}

test "convert additive shader" {
    const source =
        \\textures/sfx/beam
        \\{
        \\    surfaceparm trans
        \\    {
        \\        map textures/sfx/beam.tga
        \\        blendFunc add
        \\    }
        \\}
    ;

    var db = q3shader.ShaderDb.init(std.testing.allocator);
    defer db.deinit();
    try db.loadShaderScript(source);

    const shader = db.find("textures/sfx/beam").?;
    var result = try convert(std.testing.allocator, shader);
    defer result.deinit();

    try std.testing.expectEqual(BlendMode.additive, result.render_state.blend);
    try std.testing.expect(!result.has_lightmap);
    try std.testing.expect(!result.render_state.depth_write);
}

test "convert cull none shader" {
    const source =
        \\textures/banners/flag
        \\{
        \\    cull none
        \\    {
        \\        map textures/banners/flag.tga
        \\    }
        \\}
    ;

    var db = q3shader.ShaderDb.init(std.testing.allocator);
    defer db.deinit();
    try db.loadShaderScript(source);

    const shader = db.find("textures/banners/flag").?;
    var result = try convert(std.testing.allocator, shader);
    defer result.deinit();

    try std.testing.expectEqual(CullMode.none, result.render_state.cull);
}

test "convert implicit texture" {
    var result = try convertImplicit(std.testing.allocator, "textures/base/floor1");
    defer result.deinit();

    try std.testing.expect(result.has_lightmap);
    try std.testing.expectEqualStrings("textures/base/floor1", result.diffuse_path.?);
    try std.testing.expectEqual(BlendMode.opaque_mode, result.render_state.blend);

    // Should have all expected nodes
    try std.testing.expect(std.mem.indexOf(u8, result.graph_json, "\"material_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.graph_json, "\"multiply\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.graph_json, "\"vertex_uv2\"") != null);
}

test "JSON is valid structure" {
    var result = try convertImplicit(std.testing.allocator, "textures/test");
    defer result.deinit();

    // Parse the JSON to verify it's valid
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.graph_json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("graph_count").?.integer);

    const graphs = root.get("graphs").?.array;
    try std.testing.expectEqual(@as(usize, 1), graphs.items.len);

    const graph = graphs.items[0].object;
    try std.testing.expect(graph.get("nodes") != null);
    try std.testing.expect(graph.get("pins") != null);
    try std.testing.expect(graph.get("links") != null);

    // Verify node count: material_output + 2 texture_sample + multiply + vertex_uv + vertex_uv2 = 6
    const nodes = graph.get("nodes").?.array;
    try std.testing.expectEqual(@as(usize, 6), nodes.items.len);

    // Verify link count: 5 connections
    const links = graph.get("links").?.array;
    try std.testing.expectEqual(@as(usize, 5), links.items.len);
}
