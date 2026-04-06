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
    is_transparent: bool = false,
    sort_key: ?f32 = null,
    surface_parms: std.StringArrayHashMap(void),
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
    }

    /// Get the first non-lightmap texture path, if any.
    pub fn getDiffuseMap(self: *const Shader) ?[]const u8 {
        for (self.stages) |s| {
            if (!s.is_lightmap and s.map.len > 0 and
                !std.mem.eql(u8, s.map, "$whiteimage"))
            {
                return s.map;
            }
        }
        return null;
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
};

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
        var sky_parms = false;
        var is_transparent = false;
        var sort_key: ?f32 = null;
        var surface_parms = std.StringArrayHashMap(void).init(allocator);
        errdefer {
            for (surface_parms.keys()) |k| allocator.free(k);
            surface_parms.deinit();
        }

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
            .is_transparent = is_transparent,
            .sort_key = sort_key,
            .surface_parms = surface_parms,
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
        // Skip // comments
        if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
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
    while (pos.* < source.len and source[pos.*] != '\n') : (pos.* += 1) {}
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
