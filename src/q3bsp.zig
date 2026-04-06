//! Quake 3 BSP (IBSP v46) parser.
//!
//! Parses id Software's Quake III Arena BSP format used by Q3, Quake Live,
//! and countless community maps. The format uses a fixed header with 17 lumps
//! containing geometry, textures, lightmaps, visibility data, and entities.

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

/// "IBSP" as a little-endian u32.
pub const ibsp_magic: u32 = 0x50534249; // 'I','B','S','P'

/// Quake 3 BSP version.
pub const ibsp_version: u32 = 46;

/// Lightmap dimensions (always 128x128 in Q3).
pub const lightmap_width: u32 = 128;
pub const lightmap_height: u32 = 128;
pub const lightmap_bytes: u32 = lightmap_width * lightmap_height * 3;

// ============================================================================
// Lump indices
// ============================================================================

pub const Lump = enum(u5) {
    entities = 0,
    shaders = 1,
    planes = 2,
    nodes = 3,
    leafs = 4,
    leaf_faces = 5,
    leaf_brushes = 6,
    models = 7,
    brushes = 8,
    brush_sides = 9,
    vertices = 10,
    mesh_verts = 11,
    effects = 12,
    faces = 13,
    lightmaps = 14,
    light_vols = 15,
    vis_data = 16,

    pub const count = 17;
};

// ============================================================================
// Lump entry (offset + length in the directory)
// ============================================================================

pub const LumpEntry = struct {
    offset: u32,
    length: u32,
};

// ============================================================================
// Surface types
// ============================================================================

pub const SurfaceType = enum(i32) {
    polygon = 1,
    patch = 2,
    mesh = 3,
    billboard = 4,
    _,
};

// ============================================================================
// Lump structures
// ============================================================================

/// Lump 1: Shader/texture reference (72 bytes).
pub const Shader = extern struct {
    name: [64]u8,
    surface_flags: u32,
    content_flags: u32,

    pub fn getName(self: *const Shader) []const u8 {
        const slice = &self.name;
        // Find first null byte
        for (slice, 0..) |c, i| {
            if (c == 0) return slice[0..i];
        }
        return slice;
    }
};

/// Lump 2: Plane (16 bytes).
pub const Plane = extern struct {
    normal: [3]f32,
    dist: f32,
};

/// Lump 3: BSP node (36 bytes).
pub const Node = extern struct {
    plane_index: i32,
    children: [2]i32, // negative = -(leaf_index + 1)
    mins: [3]i32,
    maxs: [3]i32,
};

/// Lump 4: BSP leaf (48 bytes).
pub const Leaf = extern struct {
    cluster: i32,
    area: i32,
    mins: [3]i32,
    maxs: [3]i32,
    first_leaf_face: i32,
    num_leaf_faces: i32,
    first_leaf_brush: i32,
    num_leaf_brushes: i32,
};

/// Lump 7: Model / submodel (40 bytes).
pub const Model = extern struct {
    mins: [3]f32,
    maxs: [3]f32,
    first_face: i32,
    num_faces: i32,
    first_brush: i32,
    num_brushes: i32,
};

/// Lump 8: Brush (12 bytes).
pub const Brush = extern struct {
    first_side: i32,
    num_sides: i32,
    shader_index: i32,
};

/// Lump 9: Brush side (8 bytes).
pub const BrushSide = extern struct {
    plane_index: i32,
    shader_index: i32,
};

/// Lump 10: Vertex (44 bytes).
pub const Vertex = extern struct {
    position: [3]f32,
    tex_coord: [2]f32,
    lightmap_coord: [2]f32,
    normal: [3]f32,
    color: [4]u8,
};

/// Lump 12: Effect (76 bytes).
pub const Effect = extern struct {
    name: [64]u8,
    brush_index: i32,
    unknown: i32,

    pub fn getName(self: *const Effect) []const u8 {
        const slice = &self.name;
        for (slice, 0..) |c, i| {
            if (c == 0) return slice[0..i];
        }
        return slice;
    }
};

/// Lump 13: Face/surface (104 bytes).
pub const Face = extern struct {
    shader_index: i32,
    effect_index: i32,
    surface_type: i32,
    first_vertex: i32,
    num_vertices: i32,
    first_mesh_vert: i32,
    num_mesh_verts: i32,
    lightmap_index: i32,
    lightmap_x: i32,
    lightmap_y: i32,
    lightmap_width: i32,
    lightmap_height: i32,
    lightmap_origin: [3]f32,
    lightmap_vecs_s: [3]f32,
    lightmap_vecs_t: [3]f32,
    normal: [3]f32,
    patch_width: i32,
    patch_height: i32,

    pub fn getSurfaceType(self: *const Face) SurfaceType {
        return @enumFromInt(self.surface_type);
    }
};

/// Lump 15: Light volume (8 bytes).
pub const LightVol = extern struct {
    ambient: [3]u8,
    directional: [3]u8,
    dir: [2]u8, // phi, theta (0-255 -> 0-360 degrees)
};

/// Lump 16: Visibility data.
pub const VisData = struct {
    num_clusters: i32,
    bytes_per_cluster: i32,
    data: []const u8,

    /// Test whether cluster `from` can see cluster `to`.
    pub fn isVisible(self: *const VisData, from: i32, to: i32) bool {
        if (from < 0 or to < 0) return true; // outside map = see everything
        if (self.data.len == 0) return true; // no vis data = see everything
        const byte_idx: usize = @intCast(@as(i64, from) * @as(i64, self.bytes_per_cluster) + @as(i64, @divFloor(to, 8)));
        if (byte_idx >= self.data.len) return true;
        const bit: u3 = @intCast(@mod(@as(u32, @intCast(to)), 8));
        return (self.data[byte_idx] & (@as(u8, 1) << bit)) != 0;
    }
};

// ============================================================================
// Entity parser
// ============================================================================

pub const Entity = struct {
    properties: std.StringArrayHashMap([]const u8),

    pub fn get(self: *const Entity, key: []const u8) ?[]const u8 {
        return self.properties.get(key);
    }

    pub fn getClassname(self: *const Entity) ?[]const u8 {
        return self.get("classname");
    }

    pub fn getOrigin(self: *const Entity) ?[3]f32 {
        const val = self.get("origin") orelse return null;
        return parseVec3(val);
    }

    pub fn getAngle(self: *const Entity) ?f32 {
        const val = self.get("angle") orelse return null;
        return std.fmt.parseFloat(f32, val) catch null;
    }

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        // Free all duped keys and values
        for (self.properties.keys(), self.properties.values()) |k, v| {
            allocator.free(k);
            allocator.free(v);
        }
        self.properties.deinit();
    }
};

fn parseVec3(s: []const u8) ?[3]f32 {
    var it = std.mem.splitScalar(u8, s, ' ');
    var result: [3]f32 = undefined;
    for (0..3) |i| {
        const tok = it.next() orelse return null;
        result[i] = std.fmt.parseFloat(f32, tok) catch return null;
    }
    return result;
}

/// Parse the entity lump string into a list of entities.
pub fn parseEntities(allocator: std.mem.Allocator, raw: []const u8) ![]Entity {
    var entities = std.ArrayList(Entity).init(allocator);
    errdefer {
        for (entities.items) |*e| e.deinit(allocator);
        entities.deinit();
    }

    var i: usize = 0;
    while (i < raw.len) {
        // Skip to opening brace
        if (raw[i] != '{') {
            i += 1;
            continue;
        }
        i += 1; // skip '{'

        var props = std.StringArrayHashMap([]const u8).init(allocator);
        errdefer {
            for (props.keys(), props.values()) |k, v| {
                allocator.free(k);
                allocator.free(v);
            }
            props.deinit();
        }

        // Parse key-value pairs until closing brace
        while (i < raw.len) {
            // Skip whitespace
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\n' or raw[i] == '\r' or raw[i] == '\t')) : (i += 1) {}

            if (i >= raw.len) break;
            if (raw[i] == '}') {
                i += 1;
                break;
            }

            // Parse quoted string: key
            if (raw[i] != '"') {
                i += 1;
                continue;
            }
            const key = try parseQuotedString(allocator, raw, &i);
            errdefer allocator.free(key);

            // Skip whitespace between key and value
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}

            // Parse quoted string: value
            if (i >= raw.len or raw[i] != '"') {
                allocator.free(key);
                continue;
            }
            const value = try parseQuotedString(allocator, raw, &i);

            try props.put(key, value);
        }

        try entities.append(.{ .properties = props });
    }

    return entities.toOwnedSlice();
}

fn parseQuotedString(allocator: std.mem.Allocator, raw: []const u8, pos: *usize) ![]const u8 {
    var i = pos.*;
    if (i >= raw.len or raw[i] != '"') return error.ExpectedQuote;
    i += 1; // skip opening quote
    const start = i;
    while (i < raw.len and raw[i] != '"') : (i += 1) {}
    const str = try allocator.dupe(u8, raw[start..i]);
    if (i < raw.len) i += 1; // skip closing quote
    pos.* = i;
    return str;
}

// ============================================================================
// BSP file
// ============================================================================

pub const Q3Bsp = struct {
    allocator: std.mem.Allocator,
    data: []const u8,

    // Lump directory
    lumps: [Lump.count]LumpEntry,

    // Parsed lump data (slices into `data` via @ptrCast or allocated)
    shaders: []const Shader,
    planes: []const Plane,
    nodes: []const Node,
    leafs: []const Leaf,
    leaf_faces: []const i32,
    leaf_brushes: []const i32,
    models: []const Model,
    brushes: []const Brush,
    brush_sides: []const BrushSide,
    vertices: []const Vertex,
    mesh_verts: []const i32,
    effects: []const Effect,
    faces: []const Face,
    light_vols: []const LightVol,
    vis_data: VisData,

    // Parsed entities
    entities: []Entity,

    // Raw entity string (slice into data)
    entity_string: []const u8,

    // Raw lightmap data (slice into data)
    lightmap_data: []const u8,

    pub fn deinit(self: *Q3Bsp) void {
        for (self.entities) |*e| {
            // Must cast away const for deinit
            var entity = Entity{ .properties = e.properties };
            entity.deinit(self.allocator);
        }
        self.allocator.free(self.entities);
    }

    /// Parse a Quake 3 BSP from raw file data.
    pub fn read(allocator: std.mem.Allocator, data: []const u8) !Q3Bsp {
        if (data.len < 144) return error.FileTooShort;

        // Read header
        const magic = std.mem.readInt(u32, data[0..4], .little);
        if (magic != ibsp_magic) return error.InvalidMagic;

        const version = std.mem.readInt(u32, data[4..8], .little);
        if (version != ibsp_version) return error.UnsupportedVersion;

        // Read lump directory (17 entries, 8 bytes each)
        var lumps: [Lump.count]LumpEntry = undefined;
        for (0..Lump.count) |i| {
            const base = 8 + i * 8;
            lumps[i] = .{
                .offset = std.mem.readInt(u32, data[base..][0..4], .little),
                .length = std.mem.readInt(u32, data[base + 4 ..][0..4], .little),
            };
        }

        // Validate all lumps fit within file
        for (lumps) |l| {
            if (@as(u64, l.offset) + @as(u64, l.length) > data.len)
                return error.LumpOutOfBounds;
        }

        // Parse typed lumps by reinterpreting slices
        const shaders = castLump(Shader, data, lumps[@intFromEnum(Lump.shaders)]);
        const planes = castLump(Plane, data, lumps[@intFromEnum(Lump.planes)]);
        const nodes = castLump(Node, data, lumps[@intFromEnum(Lump.nodes)]);
        const leafs = castLump(Leaf, data, lumps[@intFromEnum(Lump.leafs)]);
        const leaf_faces = castLump(i32, data, lumps[@intFromEnum(Lump.leaf_faces)]);
        const leaf_brushes = castLump(i32, data, lumps[@intFromEnum(Lump.leaf_brushes)]);
        const models = castLump(Model, data, lumps[@intFromEnum(Lump.models)]);
        const brushes = castLump(Brush, data, lumps[@intFromEnum(Lump.brushes)]);
        const brush_sides = castLump(BrushSide, data, lumps[@intFromEnum(Lump.brush_sides)]);
        const vertices = castLump(Vertex, data, lumps[@intFromEnum(Lump.vertices)]);
        const mesh_verts = castLump(i32, data, lumps[@intFromEnum(Lump.mesh_verts)]);
        const effects = castLump(Effect, data, lumps[@intFromEnum(Lump.effects)]);
        const faces = castLump(Face, data, lumps[@intFromEnum(Lump.faces)]);
        const light_vols = castLump(LightVol, data, lumps[@intFromEnum(Lump.light_vols)]);

        // Entity string (lump 0)
        const ent_lump = lumps[@intFromEnum(Lump.entities)];
        const entity_string = if (ent_lump.length > 0)
            data[ent_lump.offset..][0..ent_lump.length]
        else
            &[_]u8{};

        // Lightmap data (lump 14) — raw bytes, 128*128*3 per lightmap
        const lm_lump = lumps[@intFromEnum(Lump.lightmaps)];
        const lightmap_data = if (lm_lump.length > 0)
            data[lm_lump.offset..][0..lm_lump.length]
        else
            &[_]u8{};

        // Visibility data (lump 16)
        const vis_lump = lumps[@intFromEnum(Lump.vis_data)];
        const vis_data = if (vis_lump.length >= 8) blk: {
            const num_clusters = std.mem.readInt(i32, data[vis_lump.offset..][0..4], .little);
            const bytes_per_cluster = std.mem.readInt(i32, data[vis_lump.offset + 4 ..][0..4], .little);
            const vec_data = data[vis_lump.offset + 8 ..][0 .. vis_lump.length - 8];
            break :blk VisData{
                .num_clusters = num_clusters,
                .bytes_per_cluster = bytes_per_cluster,
                .data = vec_data,
            };
        } else VisData{
            .num_clusters = 0,
            .bytes_per_cluster = 0,
            .data = &[_]u8{},
        };

        // Parse entities
        const entities = try parseEntities(allocator, entity_string);

        return Q3Bsp{
            .allocator = allocator,
            .data = data,
            .lumps = lumps,
            .shaders = shaders,
            .planes = planes,
            .nodes = nodes,
            .leafs = leafs,
            .leaf_faces = leaf_faces,
            .leaf_brushes = leaf_brushes,
            .models = models,
            .brushes = brushes,
            .brush_sides = brush_sides,
            .vertices = vertices,
            .mesh_verts = mesh_verts,
            .effects = effects,
            .faces = faces,
            .light_vols = light_vols,
            .vis_data = vis_data,
            .entities = entities,
            .entity_string = entity_string,
            .lightmap_data = lightmap_data,
        };
    }

    // --- Accessors ---

    /// Number of lightmaps in the BSP.
    pub fn numLightmaps(self: *const Q3Bsp) u32 {
        const lm_lump = self.lumps[@intFromEnum(Lump.lightmaps)];
        return lm_lump.length / lightmap_bytes;
    }

    /// Get raw RGB data for a lightmap by index (128x128x3 bytes).
    pub fn getLightmap(self: *const Q3Bsp, index: u32) ?[]const u8 {
        const offset = index * lightmap_bytes;
        if (offset + lightmap_bytes > self.lightmap_data.len) return null;
        return self.lightmap_data[offset..][0..lightmap_bytes];
    }

    /// Find the leaf containing a world-space point by traversing the BSP tree.
    pub fn findLeaf(self: *const Q3Bsp, point: [3]f32) *const Leaf {
        var index: i32 = 0;
        while (index >= 0) {
            const node = &self.nodes[@intCast(index)];
            const plane = &self.planes[@intCast(node.plane_index)];
            const dist = plane.normal[0] * point[0] +
                plane.normal[1] * point[1] +
                plane.normal[2] * point[2] - plane.dist;
            if (dist >= 0) {
                index = node.children[0];
            } else {
                index = node.children[1];
            }
        }
        // Negative index: leaf = -(index + 1)
        const leaf_index: usize = @intCast(-(index + 1));
        return &self.leafs[leaf_index];
    }

    /// Get faces for a given model (model 0 = world geometry).
    pub fn getModelFaces(self: *const Q3Bsp, model_index: usize) []const Face {
        const m = &self.models[model_index];
        const start: usize = @intCast(m.first_face);
        const count: usize = @intCast(m.num_faces);
        return self.faces[start..][0..count];
    }

    /// Collect all visible face indices given a camera position and view-projection matrix.
    /// Combines PVS (cluster visibility) with frustum culling for efficient rendering.
    /// Returns a VisibleSet with face indices. Uses a bitset to avoid duplicates.
    pub fn collectVisibleFaces(
        self: *const Q3Bsp,
        allocator: std.mem.Allocator,
        camera_pos: [3]f32,
        frustum: *const Frustum,
    ) !VisibleSet {
        const camera_leaf = self.findLeaf(camera_pos);
        const camera_cluster = camera_leaf.cluster;

        // Bitset to track which faces we've already added
        const face_count = self.faces.len;
        const bitset_len = (face_count + 63) / 64;
        const face_seen = try allocator.alloc(u64, bitset_len);
        defer allocator.free(face_seen);
        @memset(face_seen, 0);

        var result = std.ArrayList(u32).init(allocator);
        errdefer result.deinit();

        // Walk all leaves and check visibility
        for (self.leafs) |leaf| {
            // PVS check: is this leaf's cluster visible from camera?
            if (!self.vis_data.isVisible(camera_cluster, leaf.cluster))
                continue;

            // Frustum check: is this leaf's bounding box in view?
            if (!frustum.testAabbI(leaf.mins, leaf.maxs))
                continue;

            // Add all faces from this leaf
            const first: usize = @intCast(leaf.first_leaf_face);
            const count: usize = @intCast(leaf.num_leaf_faces);
            for (self.leaf_faces[first..][0..count]) |face_idx| {
                const fi: usize = @intCast(face_idx);
                if (fi >= face_count) continue;

                // Check bitset
                const word = fi / 64;
                const bit: u6 = @intCast(fi % 64);
                if (face_seen[word] & (@as(u64, 1) << bit) != 0) continue;
                face_seen[word] |= @as(u64, 1) << bit;

                try result.append(@intCast(fi));
            }
        }

        const face_indices = try result.toOwnedSlice();
        return VisibleSet{
            .face_indices = face_indices,
            .count = @intCast(face_indices.len),
            .allocator = allocator,
        };
    }

    /// Walk the BSP tree front-to-back from a given camera position.
    /// Calls `callback` with each leaf index in front-to-back order.
    /// Useful for transparency sorting or occlusion-based rendering.
    pub fn walkFrontToBack(
        self: *const Q3Bsp,
        camera_pos: [3]f32,
        comptime Ctx: type,
        ctx: Ctx,
        comptime callback: fn (ctx: Ctx, leaf_index: usize, leaf: *const Leaf) void,
    ) void {
        self.walkNode(0, camera_pos, Ctx, ctx, callback);
    }

    fn walkNode(
        self: *const Q3Bsp,
        node_index: i32,
        camera_pos: [3]f32,
        comptime Ctx: type,
        ctx: Ctx,
        comptime callback: fn (ctx: Ctx, leaf_index: usize, leaf: *const Leaf) void,
    ) void {
        if (node_index < 0) {
            // Leaf node
            const leaf_index: usize = @intCast(-(node_index + 1));
            if (leaf_index < self.leafs.len) {
                callback(ctx, leaf_index, &self.leafs[leaf_index]);
            }
            return;
        }

        const ni: usize = @intCast(node_index);
        if (ni >= self.nodes.len) return;
        const node = &self.nodes[ni];
        const plane = &self.planes[@intCast(node.plane_index)];

        // Determine which side of the splitting plane the camera is on
        const dist = plane.normal[0] * camera_pos[0] +
            plane.normal[1] * camera_pos[1] +
            plane.normal[2] * camera_pos[2] - plane.dist;

        if (dist >= 0) {
            // Camera is in front — visit front (child[0]) first
            self.walkNode(node.children[0], camera_pos, Ctx, ctx, callback);
            self.walkNode(node.children[1], camera_pos, Ctx, ctx, callback);
        } else {
            // Camera is behind — visit back (child[1]) first
            self.walkNode(node.children[1], camera_pos, Ctx, ctx, callback);
            self.walkNode(node.children[0], camera_pos, Ctx, ctx, callback);
        }
    }

    /// Extract all renderable geometry into a single indexed triangle mesh.
    /// This handles polygon faces, mesh faces, and Bezier patch tessellation.
    pub fn extractGeometry(self: *const Q3Bsp, allocator: std.mem.Allocator, opts: ExtractOptions) !ExtractedMesh {
        // First pass: count vertices and indices needed
        var total_verts: usize = 0;
        var total_indices: usize = 0;

        for (self.faces) |face| {
            if (!self.shouldIncludeFace(&face, opts)) continue;

            switch (face.getSurfaceType()) {
                .polygon, .mesh => {
                    total_verts += @intCast(face.num_vertices);
                    total_indices += @intCast(face.num_mesh_verts);
                },
                .patch => {
                    if (!opts.include_patches) continue;
                    if (face.patch_width < 3 or face.patch_height < 3) continue;
                    const pw: u32 = @intCast(face.patch_width);
                    const ph: u32 = @intCast(face.patch_height);
                    const patches_x = (pw - 1) / 2;
                    const patches_y = (ph - 1) / 2;
                    const verts_per_patch = (opts.patch_lod + 1) * (opts.patch_lod + 1);
                    const indices_per_patch = opts.patch_lod * opts.patch_lod * 6;
                    total_verts += patches_x * patches_y * verts_per_patch;
                    total_indices += patches_x * patches_y * indices_per_patch;
                },
                .billboard => {
                    if (!opts.include_billboards) continue;
                    // Billboards: single point, skip for mesh extraction
                },
                _ => {},
            }
        }

        // Allocate
        var vertices = try allocator.alloc(Vertex, total_verts);
        errdefer allocator.free(vertices);
        var indices = try allocator.alloc(u32, total_indices);
        errdefer allocator.free(indices);
        var shader_indices = try allocator.alloc(i32, total_indices / 3);
        errdefer allocator.free(shader_indices);
        var lightmap_indices = try allocator.alloc(i32, total_indices / 3);
        errdefer allocator.free(lightmap_indices);

        // Second pass: fill buffers
        var vi: u32 = 0; // vertex write cursor
        var ii: u32 = 0; // index write cursor

        for (self.faces) |face| {
            if (!self.shouldIncludeFace(&face, opts)) continue;

            switch (face.getSurfaceType()) {
                .polygon, .mesh => {
                    const base_vertex = vi;
                    const nv: u32 = @intCast(face.num_vertices);
                    const ni: u32 = @intCast(face.num_mesh_verts);
                    const fv: u32 = @intCast(face.first_vertex);
                    const fi: u32 = @intCast(face.first_mesh_vert);

                    // Copy vertices
                    for (0..nv) |j| {
                        vertices[vi] = self.vertices[fv + j];
                        vi += 1;
                    }

                    // Copy indices (mesh_verts are offsets from first_vertex)
                    const tri_start = ii / 3;
                    for (0..ni) |j| {
                        const mv: i32 = self.mesh_verts[fi + j];
                        indices[ii] = base_vertex + @as(u32, @intCast(mv));
                        ii += 1;
                    }
                    const tri_end = ii / 3;

                    // Fill per-triangle material info
                    for (tri_start..tri_end) |t| {
                        shader_indices[t] = face.shader_index;
                        lightmap_indices[t] = face.lightmap_index;
                    }
                },
                .patch => {
                    if (!opts.include_patches) continue;
                    if (face.patch_width < 3 or face.patch_height < 3) continue;
                    self.tessellatePatch(&face, opts.patch_lod, vertices, indices, shader_indices, lightmap_indices, &vi, &ii);
                },
                .billboard => {},
                _ => {},
            }
        }

        return ExtractedMesh{
            .vertices = vertices,
            .indices = indices,
            .shader_indices = shader_indices,
            .lightmap_indices = lightmap_indices,
            .allocator = allocator,
        };
    }

    fn shouldIncludeFace(self: *const Q3Bsp, face: *const Face, opts: ExtractOptions) bool {
        // Skip faces with filtered surface flags
        if (face.shader_index >= 0) {
            const si: usize = @intCast(face.shader_index);
            if (si < self.shaders.len) {
                if (self.shaders[si].surface_flags & opts.skip_surface_flags != 0) return false;
            }
        }
        return true;
    }

    fn tessellatePatch(
        self: *const Q3Bsp,
        face: *const Face,
        lod: u32,
        vertices: []Vertex,
        indices: []u32,
        shader_indices: []i32,
        lightmap_indices: []i32,
        vi: *u32,
        ii: *u32,
    ) void {
        const pw: u32 = @intCast(face.patch_width);
        const ph: u32 = @intCast(face.patch_height);
        const patches_x = (pw - 1) / 2;
        const patches_y = (ph - 1) / 2;
        const fv: u32 = @intCast(face.first_vertex);
        const verts_per_edge = lod + 1;

        for (0..patches_y) |py| {
            for (0..patches_x) |px| {
                // Extract 3x3 control points for this sub-patch
                var cp: [9]Vertex = undefined;
                for (0..3) |row| {
                    for (0..3) |col| {
                        const src_idx = fv +
                            @as(u32, @intCast(py * 2 + row)) * pw +
                            @as(u32, @intCast(px * 2 + col));
                        cp[row * 3 + col] = self.vertices[src_idx];
                    }
                }

                // Generate tessellated vertices
                const base_vertex = vi.*;
                for (0..verts_per_edge) |row| {
                    for (0..verts_per_edge) |col| {
                        const u = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(lod));
                        const v = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(lod));
                        vertices[vi.*] = bezierVertex(cp, u, v);
                        vi.* += 1;
                    }
                }

                // Generate triangle indices (two triangles per quad)
                const tri_start = ii.* / 3;
                for (0..lod) |row| {
                    for (0..lod) |col| {
                        const v0 = base_vertex + @as(u32, @intCast(row)) * verts_per_edge + @as(u32, @intCast(col));
                        const v1 = v0 + verts_per_edge;
                        const v2 = v1 + 1;
                        const v3 = v0 + 1;

                        indices[ii.*] = v0;
                        ii.* += 1;
                        indices[ii.*] = v1;
                        ii.* += 1;
                        indices[ii.*] = v2;
                        ii.* += 1;

                        indices[ii.*] = v0;
                        ii.* += 1;
                        indices[ii.*] = v2;
                        ii.* += 1;
                        indices[ii.*] = v3;
                        ii.* += 1;
                    }
                }
                const tri_end = ii.* / 3;

                for (tri_start..tri_end) |t| {
                    shader_indices[t] = face.shader_index;
                    lightmap_indices[t] = face.lightmap_index;
                }
            }
        }
    }
};

// ============================================================================
// Frustum culling
// ============================================================================

/// A view frustum defined by 6 planes (left, right, bottom, top, near, far).
/// Each plane is stored as [A, B, C, D] where Ax + By + Cz + D = 0.
pub const Frustum = struct {
    planes: [6][4]f32,

    /// Extract frustum planes from a combined view-projection matrix.
    /// The matrix should be column-major (OpenGL/raylib convention):
    ///   m[col][row], so m[0] = first column, m[0][0] = row0 col0.
    pub fn fromViewProjection(m: [4][4]f32) Frustum {
        var f: Frustum = undefined;

        // Left:   row3 + row0
        f.planes[0] = normalizePlane(.{
            m[0][3] + m[0][0],
            m[1][3] + m[1][0],
            m[2][3] + m[2][0],
            m[3][3] + m[3][0],
        });
        // Right:  row3 - row0
        f.planes[1] = normalizePlane(.{
            m[0][3] - m[0][0],
            m[1][3] - m[1][0],
            m[2][3] - m[2][0],
            m[3][3] - m[3][0],
        });
        // Bottom: row3 + row1
        f.planes[2] = normalizePlane(.{
            m[0][3] + m[0][1],
            m[1][3] + m[1][1],
            m[2][3] + m[2][1],
            m[3][3] + m[3][1],
        });
        // Top:    row3 - row1
        f.planes[3] = normalizePlane(.{
            m[0][3] - m[0][1],
            m[1][3] - m[1][1],
            m[2][3] - m[2][1],
            m[3][3] - m[3][1],
        });
        // Near:   row3 + row2
        f.planes[4] = normalizePlane(.{
            m[0][3] + m[0][2],
            m[1][3] + m[1][2],
            m[2][3] + m[2][2],
            m[3][3] + m[3][2],
        });
        // Far:    row3 - row2
        f.planes[5] = normalizePlane(.{
            m[0][3] - m[0][2],
            m[1][3] - m[1][2],
            m[2][3] - m[2][2],
            m[3][3] - m[3][2],
        });

        return f;
    }

    /// Test if an axis-aligned bounding box is inside or intersects the frustum.
    /// Uses mins/maxs as i32 (matching BSP node/leaf bounds).
    pub fn testAabbI(self: *const Frustum, mins: [3]i32, maxs: [3]i32) bool {
        return self.testAabb(
            .{ @floatFromInt(mins[0]), @floatFromInt(mins[1]), @floatFromInt(mins[2]) },
            .{ @floatFromInt(maxs[0]), @floatFromInt(maxs[1]), @floatFromInt(maxs[2]) },
        );
    }

    /// Test if an axis-aligned bounding box is inside or intersects the frustum.
    pub fn testAabb(self: *const Frustum, mins: [3]f32, maxs: [3]f32) bool {
        for (self.planes) |plane| {
            // Find the corner most aligned with the plane normal (positive vertex)
            const px: f32 = if (plane[0] >= 0) maxs[0] else mins[0];
            const py: f32 = if (plane[1] >= 0) maxs[1] else mins[1];
            const pz: f32 = if (plane[2] >= 0) maxs[2] else mins[2];

            // If the positive vertex is behind the plane, the box is fully outside
            if (plane[0] * px + plane[1] * py + plane[2] * pz + plane[3] < 0)
                return false;
        }
        return true;
    }

    /// Test if a point is inside the frustum.
    pub fn testPoint(self: *const Frustum, point: [3]f32) bool {
        for (self.planes) |plane| {
            if (plane[0] * point[0] + plane[1] * point[1] + plane[2] * point[2] + plane[3] < 0)
                return false;
        }
        return true;
    }
};

fn normalizePlane(p: [4]f32) [4]f32 {
    const len = @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
    if (len < 0.00001) return p;
    return .{ p[0] / len, p[1] / len, p[2] / len, p[3] / len };
}

// ============================================================================
// Visibility query result
// ============================================================================

/// Result of a visibility query — a list of face indices to render.
pub const VisibleSet = struct {
    /// Indices into the BSP face array.
    face_indices: []u32,
    /// Number of visible faces.
    count: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VisibleSet) void {
        self.allocator.free(self.face_indices);
    }
};

// ============================================================================
// Geometry extraction
// ============================================================================

/// A renderable triangle mesh extracted from BSP faces.
pub const ExtractedMesh = struct {
    vertices: []Vertex,
    indices: []u32,
    /// Per-triangle shader index (one per 3 indices).
    shader_indices: []i32,
    /// Per-triangle lightmap index (one per 3 indices).
    lightmap_indices: []i32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExtractedMesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
        self.allocator.free(self.shader_indices);
        self.allocator.free(self.lightmap_indices);
    }

    pub fn triangleCount(self: *const ExtractedMesh) u32 {
        return @intCast(self.indices.len / 3);
    }
};

/// Options for geometry extraction.
pub const ExtractOptions = struct {
    /// Bezier patch tessellation level (vertices per edge = lod + 1).
    /// Higher = smoother curves. 6 is a good default.
    patch_lod: u32 = 6,
    /// Skip faces with these surface flags set (default: skip sky + tool textures).
    skip_surface_flags: u32 = 0xC14, // SKY | NODRAW | HINT | SKIP
    /// Whether to include patch (Bezier) faces.
    include_patches: bool = true,
    /// Whether to include billboard faces.
    include_billboards: bool = false,
};

// ============================================================================
// Bezier patch helpers
// ============================================================================

/// Interpolate a vertex attribute using biquadratic Bezier basis functions.
fn bezierInterp(comptime n: comptime_int, cp: [9][n]f32, u: f32, v: f32) [n]f32 {
    // Quadratic Bernstein basis
    const iu = 1.0 - u;
    const iv = 1.0 - v;
    const bu = [3]f32{ iu * iu, 2.0 * iu * u, u * u };
    const bv = [3]f32{ iv * iv, 2.0 * iv * v, v * v };

    var result: [n]f32 = [_]f32{0} ** n;
    for (0..3) |row| {
        for (0..3) |col| {
            const w = bv[row] * bu[col];
            const idx = row * 3 + col;
            for (0..n) |k| {
                result[k] += cp[idx][k] * w;
            }
        }
    }
    return result;
}

/// Interpolate a full vertex from 9 control points.
fn bezierVertex(control: [9]Vertex, u: f32, v: f32) Vertex {
    // Extract attribute arrays from control points
    var cp_pos: [9][3]f32 = undefined;
    var cp_tc: [9][2]f32 = undefined;
    var cp_lc: [9][2]f32 = undefined;
    var cp_nrm: [9][3]f32 = undefined;
    var cp_col: [9][4]f32 = undefined;

    for (0..9) |i| {
        cp_pos[i] = control[i].position;
        cp_tc[i] = control[i].tex_coord;
        cp_lc[i] = control[i].lightmap_coord;
        cp_nrm[i] = control[i].normal;
        cp_col[i] = .{
            @as(f32, @floatFromInt(control[i].color[0])),
            @as(f32, @floatFromInt(control[i].color[1])),
            @as(f32, @floatFromInt(control[i].color[2])),
            @as(f32, @floatFromInt(control[i].color[3])),
        };
    }

    const pos = bezierInterp(3, cp_pos, u, v);
    const tc = bezierInterp(2, cp_tc, u, v);
    const lc = bezierInterp(2, cp_lc, u, v);
    const nrm_raw = bezierInterp(3, cp_nrm, u, v);
    const col = bezierInterp(4, cp_col, u, v);

    // Normalize the normal
    const len = @sqrt(nrm_raw[0] * nrm_raw[0] + nrm_raw[1] * nrm_raw[1] + nrm_raw[2] * nrm_raw[2]);
    const nrm = if (len > 0.0001) [3]f32{
        nrm_raw[0] / len,
        nrm_raw[1] / len,
        nrm_raw[2] / len,
    } else nrm_raw;

    return Vertex{
        .position = pos,
        .tex_coord = tc,
        .lightmap_coord = lc,
        .normal = nrm,
        .color = .{
            @intFromFloat(std.math.clamp(col[0], 0, 255)),
            @intFromFloat(std.math.clamp(col[1], 0, 255)),
            @intFromFloat(std.math.clamp(col[2], 0, 255)),
            @intFromFloat(std.math.clamp(col[3], 0, 255)),
        },
    };
}

// ============================================================================
// Extraction methods on Q3Bsp
// ============================================================================

// ============================================================================
// Lightmap atlas
// ============================================================================

/// A packed lightmap atlas — all BSP lightmaps in a single RGBA texture.
pub const LightmapAtlas = struct {
    /// RGBA pixel data (4 bytes per pixel).
    pixels: []u8,
    /// Atlas dimensions in pixels.
    width: u32,
    height: u32,
    /// Number of lightmaps packed along each axis.
    cols: u32,
    rows: u32,
    /// Number of source lightmaps.
    count: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LightmapAtlas) void {
        self.allocator.free(self.pixels);
    }

    /// Get the atlas UV offset for a given lightmap index.
    /// Returns the top-left corner in normalized [0,1] atlas coordinates.
    pub fn getLightmapOffset(self: *const LightmapAtlas, index: i32) [2]f32 {
        if (index < 0 or @as(u32, @intCast(index)) >= self.count) return .{ 0, 0 };
        const idx: u32 = @intCast(index);
        const col = idx % self.cols;
        const row = idx / self.cols;
        return .{
            @as(f32, @floatFromInt(col * lightmap_width)) / @as(f32, @floatFromInt(self.width)),
            @as(f32, @floatFromInt(row * lightmap_height)) / @as(f32, @floatFromInt(self.height)),
        };
    }

    /// Get the UV scale factor for mapping a single lightmap into the atlas.
    pub fn getLightmapScale(self: *const LightmapAtlas) [2]f32 {
        return .{
            @as(f32, @floatFromInt(lightmap_width)) / @as(f32, @floatFromInt(self.width)),
            @as(f32, @floatFromInt(lightmap_height)) / @as(f32, @floatFromInt(self.height)),
        };
    }
};

/// Build a lightmap atlas from BSP data and remap UVs on an extracted mesh.
pub fn buildLightmapAtlas(bsp: *const Q3Bsp, allocator: std.mem.Allocator) !LightmapAtlas {
    const count = bsp.numLightmaps();
    if (count == 0) {
        // Return a 1x1 white pixel atlas
        const pixels = try allocator.alloc(u8, 4);
        pixels[0] = 255;
        pixels[1] = 255;
        pixels[2] = 255;
        pixels[3] = 255;
        return LightmapAtlas{
            .pixels = pixels,
            .width = 1,
            .height = 1,
            .cols = 1,
            .rows = 1,
            .count = 0,
            .allocator = allocator,
        };
    }

    // Calculate grid layout — pack lightmaps in a roughly square grid
    const cols = ceilSqrt(count);
    const rows = (count + cols - 1) / cols;

    // Atlas dimensions (not necessarily power-of-two — Forge can handle NPOT)
    const atlas_w = cols * lightmap_width;
    const atlas_h = rows * lightmap_height;
    const total_pixels = atlas_w * atlas_h;

    const pixels = try allocator.alloc(u8, total_pixels * 4);
    @memset(pixels, 0);

    // Copy each lightmap into the atlas
    for (0..count) |i| {
        const src = bsp.getLightmap(@intCast(i)) orelse continue;
        const col = @as(u32, @intCast(i)) % cols;
        const row = @as(u32, @intCast(i)) / cols;
        const dst_x = col * lightmap_width;
        const dst_y = row * lightmap_height;

        for (0..lightmap_height) |py| {
            for (0..lightmap_width) |px| {
                const src_idx = (py * lightmap_width + px) * 3;
                const dst_idx = ((dst_y + @as(u32, @intCast(py))) * atlas_w + (dst_x + @as(u32, @intCast(px)))) * 4;
                // RGB -> RGBA
                pixels[dst_idx + 0] = src[src_idx + 0];
                pixels[dst_idx + 1] = src[src_idx + 1];
                pixels[dst_idx + 2] = src[src_idx + 2];
                pixels[dst_idx + 3] = 255;
            }
        }
    }

    return LightmapAtlas{
        .pixels = pixels,
        .width = atlas_w,
        .height = atlas_h,
        .cols = cols,
        .rows = rows,
        .count = count,
        .allocator = allocator,
    };
}

/// Remap lightmap UVs on an extracted mesh to point into a lightmap atlas.
/// After this call, `lightmap_coord` on each vertex is in atlas space [0,1].
pub fn remapLightmapUVs(mesh: *ExtractedMesh, atlas: *const LightmapAtlas) void {
    if (atlas.count == 0) return;

    const scale = atlas.getLightmapScale();

    // Build a per-vertex lightmap index by finding which triangle each vertex belongs to.
    // Since vertices may be shared across triangles with different lightmap indices,
    // we use the first triangle that references each vertex.
    // However, in Q3 BSP extracted meshes, vertices are typically not shared across
    // faces (each face copies its own vertices), so this is straightforward.

    // For each triangle, remap its vertices' lightmap UVs
    const tri_count = mesh.indices.len / 3;
    for (0..tri_count) |tri| {
        const lm_idx = mesh.lightmap_indices[tri];
        if (lm_idx < 0) continue; // no lightmap for this face

        const offset = atlas.getLightmapOffset(lm_idx);

        for (0..3) |k| {
            const vi = mesh.indices[tri * 3 + k];
            // Remap: atlas_uv = offset + original_uv * scale
            mesh.vertices[vi].lightmap_coord = .{
                offset[0] + mesh.vertices[vi].lightmap_coord[0] * scale[0],
                offset[1] + mesh.vertices[vi].lightmap_coord[1] * scale[1],
            };
        }
    }
}

fn ceilSqrt(n: u32) u32 {
    if (n <= 1) return 1;
    var s: u32 = 1;
    while (s * s < n) : (s += 1) {}
    return s;
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Reinterpret a lump's raw bytes as a typed slice.
/// Works for any packed, fixed-size struct without padding issues.
fn castLump(comptime T: type, data: []const u8, lump: LumpEntry) []const T {
    const byte_slice = data[lump.offset..][0..lump.length];
    const count = lump.length / @sizeOf(T);
    if (count == 0) return &[_]T{};
    const ptr: [*]const T = @ptrCast(@alignCast(byte_slice.ptr));
    return ptr[0..count];
}

// ============================================================================
// Tests
// ============================================================================

test "entity parser" {
    const raw =
        \\{
        \\"classname" "worldspawn"
        \\"message" "Hello World"
        \\}
        \\{
        \\"classname" "info_player_deathmatch"
        \\"origin" "128 -256 64"
        \\}
    ;

    const entities = try parseEntities(std.testing.allocator, raw);
    defer {
        for (entities) |*e| {
            var entity = Entity{ .properties = e.properties };
            entity.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(entities);
    }

    try std.testing.expectEqual(@as(usize, 2), entities.len);

    try std.testing.expectEqualStrings("worldspawn", entities[0].get("classname").?);
    try std.testing.expectEqualStrings("Hello World", entities[0].get("message").?);

    try std.testing.expectEqualStrings("info_player_deathmatch", entities[1].get("classname").?);

    const origin = entities[1].getOrigin().?;
    try std.testing.expectApproxEqAbs(@as(f32, 128.0), origin[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -256.0), origin[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0), origin[2], 0.001);
}

test "vis data visibility check" {
    // 2 clusters, 1 byte each: cluster 0 sees both, cluster 1 sees only itself
    const vis = VisData{
        .num_clusters = 2,
        .bytes_per_cluster = 1,
        .data = &[_]u8{ 0b11, 0b10 },
    };

    try std.testing.expect(vis.isVisible(0, 0));
    try std.testing.expect(vis.isVisible(0, 1));
    try std.testing.expect(!vis.isVisible(1, 0));
    try std.testing.expect(vis.isVisible(1, 1));

    // Negative clusters always visible
    try std.testing.expect(vis.isVisible(-1, 0));
    try std.testing.expect(vis.isVisible(0, -1));
}

test "parse vec3" {
    const result = parseVec3("128 -256.5 64").?;
    try std.testing.expectApproxEqAbs(@as(f32, 128.0), result[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -256.5), result[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0), result[2], 0.001);
}

test "shader getName" {
    var shader: Shader = undefined;
    const name = "textures/base_wall/concrete1";
    @memset(&shader.name, 0);
    @memcpy(shader.name[0..name.len], name);
    try std.testing.expectEqualStrings("textures/base_wall/concrete1", shader.getName());
}

test "frustum AABB culling" {
    // A frustum that only accepts the positive-X halfspace
    const f = Frustum{
        .planes = .{
            .{ 1, 0, 0, 0 }, // x >= 0
            .{ -1, 0, 0, 1000 }, // x <= 1000
            .{ 0, 1, 0, 1000 }, // y >= -1000
            .{ 0, -1, 0, 1000 }, // y <= 1000
            .{ 0, 0, 1, 1000 }, // z >= -1000
            .{ 0, 0, -1, 1000 }, // z <= 1000
        },
    };

    // Box fully in positive X — should pass
    try std.testing.expect(f.testAabb(.{ 10, -10, -10 }, .{ 100, 10, 10 }));

    // Box fully in negative X — should fail
    try std.testing.expect(!f.testAabb(.{ -100, -10, -10 }, .{ -10, 10, 10 }));

    // Box straddling X=0 — should pass (partially inside)
    try std.testing.expect(f.testAabb(.{ -10, -10, -10 }, .{ 10, 10, 10 }));
}

test "frustum point test" {
    const f = Frustum{
        .planes = .{
            .{ 1, 0, 0, 0 }, // x >= 0
            .{ -1, 0, 0, 100 }, // x <= 100
            .{ 0, 1, 0, 0 }, // y >= 0
            .{ 0, -1, 0, 100 }, // y <= 100
            .{ 0, 0, 1, 0 }, // z >= 0
            .{ 0, 0, -1, 100 }, // z <= 100
        },
    };

    try std.testing.expect(f.testPoint(.{ 50, 50, 50 }));
    try std.testing.expect(!f.testPoint(.{ -10, 50, 50 }));
    try std.testing.expect(!f.testPoint(.{ 50, 150, 50 }));
}
