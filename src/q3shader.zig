//! Quake 3 shader script parser.
//!
//! Parses .shader files that define material properties for Q3 BSP surfaces.
//! Each shader has a name (matching the BSP shader lump), surface parameters,
//! and one or more rendering stages with texture references and blend modes.

const std = @import("std");

// ============================================================================
// Shader structures
// ============================================================================

pub const BlendFunc = enum {
    gl_one,
    gl_zero,
    gl_src_alpha,
    gl_one_minus_src_alpha,
    gl_dst_color,
    gl_one_minus_dst_color,
    gl_src_color,
    gl_one_minus_src_color,
    gl_dst_alpha,
    gl_one_minus_dst_alpha,
};

pub const TcGen = enum {
    base,
    lightmap,
    environment,
};

pub const AlphaFunc = enum {
    none,
    gt0,
    lt128,
    ge128,
};

pub const Stage = struct {
    /// Texture map path (e.g. "textures/gothic_block/blocks11b").
    /// "$lightmap" means use the lightmap texture.
    map: []const u8,
    blend_src: BlendFunc = .gl_one,
    blend_dst: BlendFunc = .gl_zero,
    tc_gen: TcGen = .base,
    alpha_func: AlphaFunc = .none,
    is_lightmap: bool = false,
    /// If true, this is an animMap with multiple frames.
    is_anim_map: bool = false,
    anim_frequency: f32 = 0,
    /// Additional frames for animMap.
    anim_frames: []const []const u8 = &.{},
    depth_write: bool = false,
    clamp: bool = false,
    map_owned: bool = false,

    pub fn deinit(self: *Stage, allocator: std.mem.Allocator) void {
        if (self.map_owned) allocator.free(self.map);
        for (self.anim_frames) |frame| allocator.free(frame);
        if (self.anim_frames.len > 0) allocator.free(self.anim_frames);
    }
};

pub const CullMode = enum {
    front,
    back,
    none,
};

pub const Shader = struct {
    name: []const u8,
    stages: []Stage,
    cull: CullMode = .front,
    sky_parms: bool = false,
    /// `polygonOffset` directive — the shader is a decal meant to render
    /// with a depth bias over the coplanar surface beneath it.
    polygon_offset: bool = false,
    is_transparent: bool = false,
    sort_key: ?f32 = null,
    surface_parms: std.StringArrayHashMap(void),
    /// Emissive intensity from `q3map_surfacelight N` (0 = not a surface light).
    /// In Q3's radiosity units; calibrated to radiance downstream.
    surface_light: f32 = 0,
    /// Emissive colour from `q3map_lightrgb r g b` (RGB multiplier, default white).
    light_rgb: [3]f32 = .{ 1, 1, 1 },
    /// Optional texture reference from `q3map_lightimage path` (for colour extraction).
    /// Owned by the Shader when non-null.
    light_image: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Shader) void {
        self.allocator.free(self.name);
        for (self.stages) |*s| {
            var stage = s.*;
            stage.deinit(self.allocator);
        }
        self.allocator.free(self.stages);
        for (self.surface_parms.keys()) |k| self.allocator.free(k);
        self.surface_parms.deinit();
        if (self.light_image) |img| self.allocator.free(img);
    }

    /// True if this shader is a surface light (`q3map_surfacelight > 0`).
    pub fn isEmissive(self: *const Shader) bool {
        return self.surface_light > 0;
    }

    /// Get the primary diffuse texture path.
    /// Searches stages in priority order: first non-lightmap, non-special map.
    /// For animMap shaders, returns the first frame.
    pub fn getDiffuseMap(self: *const Shader) ?[]const u8 {
        // First pass: look for a stage with a real texture map
        for (self.stages) |s| {
            if (s.is_lightmap) continue;
            if (s.map.len == 0) continue;
            if (isSpecialMap(s.map)) continue;
            return s.map;
        }
        return null;
    }

    /// Get all unique texture paths referenced by this shader (all stages).
    /// Includes animMap frames. Excludes $lightmap and $whiteimage.
    /// Returned slices point into the Shader's owned memory — do not free.
    pub fn getAllTextures(self: *const Shader, buf: [][]const u8) u32 {
        var count: u32 = 0;
        for (self.stages) |s| {
            if (s.map.len > 0 and !isSpecialMap(s.map)) {
                if (count < buf.len) {
                    // Avoid duplicates
                    var dupe = false;
                    for (buf[0..count]) |existing| {
                        if (std.mem.eql(u8, existing, s.map)) {
                            dupe = true;
                            break;
                        }
                    }
                    if (!dupe) {
                        buf[count] = s.map;
                        count += 1;
                    }
                }
            }
            // Also include animMap frames
            for (s.anim_frames) |frame| {
                if (frame.len > 0 and !isSpecialMap(frame) and count < buf.len) {
                    var dupe = false;
                    for (buf[0..count]) |existing| {
                        if (std.mem.eql(u8, existing, frame)) {
                            dupe = true;
                            break;
                        }
                    }
                    if (!dupe) {
                        buf[count] = frame;
                        count += 1;
                    }
                }
            }
        }
        return count;
    }

    /// Check if this shader has a lightmap stage.
    pub fn hasLightmap(self: *const Shader) bool {
        for (self.stages) |s| {
            if (s.is_lightmap) return true;
        }
        return false;
    }

    /// Check if a surface parameter is set.
    pub fn hasSurfaceParm(self: *const Shader, parm: []const u8) bool {
        return self.surface_parms.contains(parm);
    }

    /// Whether this shader should be skipped for rendering (tool textures, sky, etc).
    pub fn isNonDrawable(self: *const Shader) bool {
        if (self.sky_parms) return true;
        if (self.hasSurfaceParm("nodraw")) return true;
        if (self.hasSurfaceParm("skip")) return true;
        if (self.stages.len == 0 and !self.sky_parms) return true;
        return false;
    }
};

fn isSpecialMap(map: []const u8) bool {
    return std.mem.eql(u8, map, "$lightmap") or
        std.mem.eql(u8, map, "$whiteimage") or
        std.mem.eql(u8, map, "*white") or
        std.mem.eql(u8, map, "$blackimage");
}

// ============================================================================
// Shader database
// ============================================================================

/// A collection of parsed shaders, keyed by name.
pub const ShaderDb = struct {
    shaders: std.StringArrayHashMap(Shader),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShaderDb {
        return .{
            .shaders = std.StringArrayHashMap(Shader).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ShaderDb) void {
        for (self.shaders.values()) |*s| {
            var shader = s.*;
            shader.deinit();
        }
        // Keys are owned by the Shader.name — don't double-free
        self.shaders.deinit();
    }

    /// Look up a shader by name.
    pub fn find(self: *const ShaderDb, name: []const u8) ?*const Shader {
        return self.shaders.getPtr(name);
    }

    /// Parse all shaders from a .shader file's contents and add to the database.
    pub fn loadShaderScript(self: *ShaderDb, source: []const u8) !void {
        var pos: usize = 0;
        while (pos < source.len) {
            // Skip whitespace and comments
            pos = skipWhitespaceAndComments(source, pos);
            if (pos >= source.len) break;

            // Read shader name (first non-whitespace token before '{')
            const name_start = pos;
            while (pos < source.len and !isWhitespace(source[pos]) and source[pos] != '{') : (pos += 1) {}
            if (pos == name_start) {
                pos += 1;
                continue;
            }
            const name = source[name_start..pos];

            // Skip to opening brace
            pos = skipWhitespaceAndComments(source, pos);
            if (pos >= source.len or source[pos] != '{') continue;
            pos += 1; // skip '{'

            // Parse shader body
            var shader = try self.parseShaderBody(name, source, &pos);
            errdefer shader.deinit();

            // If shader already exists, skip (first definition wins)
            if (self.shaders.contains(shader.name)) {
                shader.deinit();
            } else {
                try self.shaders.put(shader.name, shader);
            }
        }
    }

    fn parseShaderBody(self: *ShaderDb, name: []const u8, source: []const u8, pos: *usize) !Shader {
        const allocator = self.allocator;
        var stages = std.ArrayList(Stage).init(allocator);
        errdefer {
            for (stages.items) |*s| s.deinit(allocator);
            stages.deinit();
        }

        var cull: CullMode = .front;
        var polygon_offset = false;
        var sky_parms = false;
        var is_transparent = false;
        var sort_key: ?f32 = null;
        var surface_parms = std.StringArrayHashMap(void).init(allocator);
        errdefer {
            for (surface_parms.keys()) |k| allocator.free(k);
            surface_parms.deinit();
        }
        var surface_light: f32 = 0;
        var light_rgb: [3]f32 = .{ 1, 1, 1 };
        var light_image: ?[]const u8 = null;
        errdefer if (light_image) |img| allocator.free(img);

        var depth: u32 = 1; // already inside outer '{'
        while (pos.* < source.len and depth > 0) {
            pos.* = skipWhitespaceAndComments(source, pos.*);
            if (pos.* >= source.len) break;

            if (source[pos.*] == '}') {
                depth -= 1;
                pos.* += 1;
                continue;
            }

            if (source[pos.*] == '{') {
                // Stage block
                pos.* += 1;
                if (depth == 1) {
                    const stage = try self.parseStage(source, pos);
                    try stages.append(stage);
                } else {
                    // Nested block — skip
                    var inner: u32 = 1;
                    while (pos.* < source.len and inner > 0) {
                        if (source[pos.*] == '{') inner += 1;
                        if (source[pos.*] == '}') inner -= 1;
                        pos.* += 1;
                    }
                }
                continue;
            }

            // Read directive
            const token = readToken(source, pos);

            if (std.ascii.eqlIgnoreCase(token, "cull")) {
                const val = readToken(source, pos);
                if (std.ascii.eqlIgnoreCase(val, "none") or std.ascii.eqlIgnoreCase(val, "disable") or std.ascii.eqlIgnoreCase(val, "twosided")) {
                    cull = .none;
                } else if (std.ascii.eqlIgnoreCase(val, "back") or std.ascii.eqlIgnoreCase(val, "backside") or std.ascii.eqlIgnoreCase(val, "backsided")) {
                    cull = .back;
                }
            } else if (std.ascii.eqlIgnoreCase(token, "surfaceparm")) {
                const val = readToken(source, pos);
                if (val.len > 0) {
                    if (std.mem.eql(u8, val, "trans")) is_transparent = true;
                    if (!surface_parms.contains(val)) {
                        const duped = try allocator.dupe(u8, val);
                        try surface_parms.put(duped, {});
                    }
                }
            } else if (std.ascii.eqlIgnoreCase(token, "skyparms")) {
                sky_parms = true;
                skipLine(source, pos);
            } else if (std.ascii.eqlIgnoreCase(token, "polygonOffset")) {
                polygon_offset = true;
            } else if (std.ascii.eqlIgnoreCase(token, "sort")) {
                const val = readToken(source, pos);
                sort_key = std.fmt.parseFloat(f32, val) catch blk: {
                    // Named sort keys
                    if (std.ascii.eqlIgnoreCase(val, "portal")) break :blk @as(f32, 1);
                    if (std.ascii.eqlIgnoreCase(val, "sky")) break :blk @as(f32, 2);
                    if (std.ascii.eqlIgnoreCase(val, "opaque")) break :blk @as(f32, 3);
                    if (std.ascii.eqlIgnoreCase(val, "banner")) break :blk @as(f32, 6);
                    if (std.ascii.eqlIgnoreCase(val, "underwater")) break :blk @as(f32, 8);
                    if (std.ascii.eqlIgnoreCase(val, "additive")) break :blk @as(f32, 9);
                    if (std.ascii.eqlIgnoreCase(val, "nearest")) break :blk @as(f32, 16);
                    break :blk null;
                };
            } else if (std.ascii.eqlIgnoreCase(token, "q3map_surfacelight") or
                std.ascii.eqlIgnoreCase(token, "q3map_surfacelight2"))
            {
                const val = readToken(source, pos);
                surface_light = std.fmt.parseFloat(f32, val) catch 0;
            } else if (std.ascii.eqlIgnoreCase(token, "q3map_lightrgb")) {
                const r = std.fmt.parseFloat(f32, readToken(source, pos)) catch 1;
                const g = std.fmt.parseFloat(f32, readToken(source, pos)) catch 1;
                const b = std.fmt.parseFloat(f32, readToken(source, pos)) catch 1;
                light_rgb = .{ r, g, b };
            } else if (std.ascii.eqlIgnoreCase(token, "q3map_lightimage")) {
                const val = readToken(source, pos);
                if (val.len > 0) {
                    if (light_image) |existing| allocator.free(existing);
                    light_image = try allocator.dupe(u8, val);
                }
            } else {
                // Unknown directive — skip rest of line
                skipLine(source, pos);
            }
        }

        const owned_name = try allocator.dupe(u8, name);

        return Shader{
            .name = owned_name,
            .stages = try stages.toOwnedSlice(),
            .cull = cull,
            .sky_parms = sky_parms,
            .polygon_offset = polygon_offset,
            .is_transparent = is_transparent,
            .sort_key = sort_key,
            .surface_parms = surface_parms,
            .surface_light = surface_light,
            .light_rgb = light_rgb,
            .light_image = light_image,
            .allocator = allocator,
        };
    }

    fn parseStage(self: *ShaderDb, source: []const u8, pos: *usize) !Stage {
        const allocator = self.allocator;
        var map: []const u8 = "";
        var map_allocated = false;
        var blend_src: BlendFunc = .gl_one;
        var blend_dst: BlendFunc = .gl_zero;
        var tc_gen: TcGen = .base;
        var alpha_func: AlphaFunc = .none;
        var is_lightmap = false;
        var is_anim_map = false;
        var anim_frequency: f32 = 0;
        var anim_frames = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (anim_frames.items) |f| allocator.free(f);
            anim_frames.deinit();
        }
        var depth_write = false;
        var clamp = false;

        while (pos.* < source.len) {
            pos.* = skipWhitespaceAndComments(source, pos.*);
            if (pos.* >= source.len) break;

            if (source[pos.*] == '}') {
                pos.* += 1;
                break;
            }

            const token = readToken(source, pos);

            if (std.ascii.eqlIgnoreCase(token, "map")) {
                const val = readToken(source, pos);
                if (map_allocated) allocator.free(map);
                if (std.mem.eql(u8, val, "$lightmap")) {
                    is_lightmap = true;
                    map = try allocator.dupe(u8, "$lightmap");
                } else {
                    map = try allocator.dupe(u8, val);
                }
                map_allocated = true;
            } else if (std.ascii.eqlIgnoreCase(token, "clampMap")) {
                const val = readToken(source, pos);
                if (map_allocated) allocator.free(map);
                map = try allocator.dupe(u8, val);
                map_allocated = true;
                clamp = true;
            } else if (std.ascii.eqlIgnoreCase(token, "animMap")) {
                is_anim_map = true;
                const freq = readToken(source, pos);
                anim_frequency = std.fmt.parseFloat(f32, freq) catch 1.0;
                // Read frames until end of line
                while (pos.* < source.len and source[pos.*] != '\n' and source[pos.*] != '\r') {
                    pos.* = skipInlineWhitespace(source, pos.*);
                    if (pos.* >= source.len or source[pos.*] == '\n' or source[pos.*] == '\r') break;
                    const frame = readToken(source, pos);
                    if (frame.len > 0) {
                        try anim_frames.append(try allocator.dupe(u8, frame));
                    }
                }
                if (anim_frames.items.len > 0) {
                    if (map_allocated) allocator.free(map);
                    map = try allocator.dupe(u8, anim_frames.items[0]);
                    map_allocated = true;
                }
            } else if (std.ascii.eqlIgnoreCase(token, "blendFunc")) {
                const val = readToken(source, pos);
                if (std.ascii.eqlIgnoreCase(val, "add")) {
                    blend_src = .gl_one;
                    blend_dst = .gl_one;
                } else if (std.ascii.eqlIgnoreCase(val, "filter")) {
                    blend_src = .gl_dst_color;
                    blend_dst = .gl_zero;
                } else if (std.ascii.eqlIgnoreCase(val, "blend")) {
                    blend_src = .gl_src_alpha;
                    blend_dst = .gl_one_minus_src_alpha;
                } else {
                    blend_src = parseBlendFunc(val);
                    const val2 = readToken(source, pos);
                    blend_dst = parseBlendFunc(val2);
                }
            } else if (std.ascii.eqlIgnoreCase(token, "tcGen")) {
                const val = readToken(source, pos);
                if (std.ascii.eqlIgnoreCase(val, "lightmap")) {
                    tc_gen = .lightmap;
                } else if (std.ascii.eqlIgnoreCase(val, "environment")) {
                    tc_gen = .environment;
                }
            } else if (std.ascii.eqlIgnoreCase(token, "alphaFunc")) {
                const val = readToken(source, pos);
                if (std.ascii.eqlIgnoreCase(val, "GT0")) {
                    alpha_func = .gt0;
                } else if (std.ascii.eqlIgnoreCase(val, "LT128")) {
                    alpha_func = .lt128;
                } else if (std.ascii.eqlIgnoreCase(val, "GE128")) {
                    alpha_func = .ge128;
                }
            } else if (std.ascii.eqlIgnoreCase(token, "depthWrite")) {
                depth_write = true;
            } else {
                skipLine(source, pos);
            }
        }

        return Stage{
            .map = map,
            .blend_src = blend_src,
            .blend_dst = blend_dst,
            .tc_gen = tc_gen,
            .alpha_func = alpha_func,
            .is_lightmap = is_lightmap,
            .is_anim_map = is_anim_map,
            .anim_frequency = anim_frequency,
            .anim_frames = try anim_frames.toOwnedSlice(),
            .depth_write = depth_write,
            .clamp = clamp,
            .map_owned = map_allocated,
        };
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn parseBlendFunc(s: []const u8) BlendFunc {
    if (std.ascii.eqlIgnoreCase(s, "GL_ONE")) return .gl_one;
    if (std.ascii.eqlIgnoreCase(s, "GL_ZERO")) return .gl_zero;
    if (std.ascii.eqlIgnoreCase(s, "GL_SRC_ALPHA")) return .gl_src_alpha;
    if (std.ascii.eqlIgnoreCase(s, "GL_ONE_MINUS_SRC_ALPHA")) return .gl_one_minus_src_alpha;
    if (std.ascii.eqlIgnoreCase(s, "GL_DST_COLOR")) return .gl_dst_color;
    if (std.ascii.eqlIgnoreCase(s, "GL_ONE_MINUS_DST_COLOR")) return .gl_one_minus_dst_color;
    if (std.ascii.eqlIgnoreCase(s, "GL_SRC_COLOR")) return .gl_src_color;
    if (std.ascii.eqlIgnoreCase(s, "GL_ONE_MINUS_SRC_COLOR")) return .gl_one_minus_src_color;
    if (std.ascii.eqlIgnoreCase(s, "GL_DST_ALPHA")) return .gl_dst_alpha;
    if (std.ascii.eqlIgnoreCase(s, "GL_ONE_MINUS_DST_ALPHA")) return .gl_one_minus_dst_alpha;
    return .gl_one;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn skipWhitespaceAndComments(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len) {
        // Skip whitespace
        if (isWhitespace(source[i])) {
            i += 1;
            continue;
        }
        // Skip // comments. '\r' terminates too — bare-CR line separators
        // appear in the wild (see skipLine) and a comment must not eat
        // directives packed after the CR on the same physical line.
        if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n' and source[i] != '\r') : (i += 1) {}
            continue;
        }
        // Skip /* */ comments
        if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len) {
                if (source[i] == '*' and source[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
        break;
    }
    return i;
}

fn skipInlineWhitespace(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    return i;
}

fn skipLine(source: []const u8, pos: *usize) void {
    // Stop at '\r' too: shader scripts in the wild use bare carriage
    // returns as line separators (old Mac-style / mixed endings), often
    // packing several directives — and even a stage's closing brace —
    // into one '\n'-terminated physical line. Skipping to '\n' alone
    // blows past those braces and desyncs the block parser (see the
    // dm17_jpad shader in OpenArena's cosmoflash.shader).
    while (pos.* < source.len and source[pos.*] != '\n' and source[pos.*] != '\r') : (pos.* += 1) {}
}

fn readToken(source: []const u8, pos: *usize) []const u8 {
    // Skip inline whitespace (not newlines — tokens are line-sensitive sometimes)
    while (pos.* < source.len and (source[pos.*] == ' ' or source[pos.*] == '\t')) : (pos.* += 1) {}

    if (pos.* >= source.len) return "";

    const start = pos.*;
    while (pos.* < source.len and !isWhitespace(source[pos.*]) and
        source[pos.*] != '{' and source[pos.*] != '}') : (pos.* += 1)
    {}
    return source[start..pos.*];
}

// ============================================================================
// Tests
// ============================================================================

test "parse simple shader" {
    const source =
        \\textures/gothic_block/blocks11b
        \\{
        \\    surfaceparm solid
        \\    cull none
        \\    {
        \\        map textures/gothic_block/blocks11b.tga
        \\        blendFunc blend
        \\    }
        \\    {
        \\        map $lightmap
        \\        blendFunc filter
        \\        tcGen lightmap
        \\    }
        \\}
    ;

    var db = ShaderDb.init(std.testing.allocator);
    defer db.deinit();

    try db.loadShaderScript(source);

    const shader = db.find("textures/gothic_block/blocks11b").?;
    try std.testing.expectEqualStrings("textures/gothic_block/blocks11b", shader.name);
    try std.testing.expectEqual(CullMode.none, shader.cull);
    try std.testing.expectEqual(@as(usize, 2), shader.stages.len);
    try std.testing.expect(shader.hasSurfaceParm("solid"));

    // First stage: diffuse
    try std.testing.expectEqualStrings("textures/gothic_block/blocks11b.tga", shader.stages[0].map);
    try std.testing.expect(!shader.stages[0].is_lightmap);
    try std.testing.expectEqual(BlendFunc.gl_src_alpha, shader.stages[0].blend_src);
    try std.testing.expectEqual(BlendFunc.gl_one_minus_src_alpha, shader.stages[0].blend_dst);

    // Second stage: lightmap
    try std.testing.expect(shader.stages[1].is_lightmap);
    try std.testing.expectEqual(TcGen.lightmap, shader.stages[1].tc_gen);

    // Helper methods
    try std.testing.expectEqualStrings("textures/gothic_block/blocks11b.tga", shader.getDiffuseMap().?);
    try std.testing.expect(shader.hasLightmap());
}

test "parse shader with surfaceparms and sort" {
    const source =
        \\textures/liquids/water
        \\{
        \\    surfaceparm trans
        \\    surfaceparm nonsolid
        \\    surfaceparm water
        \\    sort underwater
        \\    cull back
        \\    {
        \\        map textures/liquids/water.tga
        \\        blendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA
        \\    }
        \\}
    ;

    var db = ShaderDb.init(std.testing.allocator);
    defer db.deinit();

    try db.loadShaderScript(source);

    const shader = db.find("textures/liquids/water").?;
    try std.testing.expect(shader.is_transparent);
    try std.testing.expect(shader.hasSurfaceParm("trans"));
    try std.testing.expect(shader.hasSurfaceParm("water"));
    try std.testing.expect(shader.hasSurfaceParm("nonsolid"));
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), shader.sort_key.?, 0.001);
    try std.testing.expectEqual(CullMode.back, shader.cull);
}

test "parse emissive directives (q3map_surfacelight / lightrgb / lightimage)" {
    const source =
        \\textures/sfx/teleporter_light
        \\{
        \\    qer_editorimage textures/sfx/teleporter.tga
        \\    surfaceparm nolightmap
        \\    q3map_surfacelight 800
        \\    q3map_lightrgb 0.4 0.6 1.0
        \\    q3map_lightimage textures/sfx/teleporter_glow.tga
        \\    {
        \\        map textures/sfx/teleporter.tga
        \\        blendFunc add
        \\    }
        \\}
        \\textures/base_wall/concrete
        \\{
        \\    {
        \\        map textures/base_wall/concrete.tga
        \\    }
        \\    {
        \\        map $lightmap
        \\        blendFunc filter
        \\    }
        \\}
    ;

    var db = ShaderDb.init(std.testing.allocator);
    defer db.deinit();

    try db.loadShaderScript(source);

    const emissive = db.find("textures/sfx/teleporter_light").?;
    try std.testing.expect(emissive.isEmissive());
    try std.testing.expectApproxEqAbs(@as(f32, 800), emissive.surface_light, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), emissive.light_rgb[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), emissive.light_rgb[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), emissive.light_rgb[2], 0.001);
    try std.testing.expectEqualStrings("textures/sfx/teleporter_glow.tga", emissive.light_image.?);

    const non_emissive = db.find("textures/base_wall/concrete").?;
    try std.testing.expect(!non_emissive.isEmissive());
    try std.testing.expectEqual(@as(f32, 0), non_emissive.surface_light);
    try std.testing.expect(non_emissive.light_image == null);
}

test "q3map_surfacelight2 treated the same" {
    const source =
        \\textures/lava/fire
        \\{
        \\    q3map_surfacelight2 1500
        \\}
    ;
    var db = ShaderDb.init(std.testing.allocator);
    defer db.deinit();
    try db.loadShaderScript(source);
    const s = db.find("textures/lava/fire").?;
    try std.testing.expect(s.isEmissive());
    try std.testing.expectApproxEqAbs(@as(f32, 1500), s.surface_light, 0.001);
}

test "parse multiple shaders" {
    const source =
        \\// A comment
        \\textures/base/floor1
        \\{
        \\    {
        \\        map textures/base/floor1.tga
        \\    }
        \\}
        \\textures/base/wall2
        \\{
        \\    {
        \\        map textures/base/wall2.tga
        \\    }
        \\}
    ;

    var db = ShaderDb.init(std.testing.allocator);
    defer db.deinit();

    try db.loadShaderScript(source);

    try std.testing.expect(db.find("textures/base/floor1") != null);
    try std.testing.expect(db.find("textures/base/wall2") != null);
}

test "bare-CR line separators don't desync block parsing" {
    // Mirrors OpenArena's cosmoflash.shader: bare '\r' (no '\n') separates
    // directives, and a stage's closing brace can share one '\n'-terminated
    // physical line with unknown directives. skipLine must stop at '\r' or
    // the brace is swallowed and the next shader definitions get parsed as
    // part of this shader's body.
    const source = "textures/test/jpad\n" ++
        "{\n" ++
        "    surfaceparm nomarks\r    q3map_surfacelight 100\n" ++
        "\t{\r\t\tmap a.tga\r\t\ttcMod stretch sin 1.2 .8 0 1.5\r\t}\r    {\n" ++
        "        map b.tga\r\t\trgbGen identity\r\t}\r}\n" ++
        "textures/test/decal{\tqer_editorimage d.tga\n" ++
        "    polygonOffset\n" ++
        "    {\n" ++
        "        map d.tga\n" ++
        "        blendFunc blend\r\t\trgbGen identity\r\t}\n" ++
        "}\n";

    var db = ShaderDb.init(std.testing.allocator);
    defer db.deinit();

    try db.loadShaderScript(source);

    const jpad = db.find("textures/test/jpad") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), jpad.stages.len);
    try std.testing.expect(!jpad.polygon_offset);

    const decal = db.find("textures/test/decal") orelse return error.TestUnexpectedResult;
    try std.testing.expect(decal.polygon_offset);
    try std.testing.expectEqual(@as(usize, 1), decal.stages.len);
}
