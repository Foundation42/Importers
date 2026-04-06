# Forge Integration Guide

How to integrate the Valve Resource Format (VRF) Zig library into the Forge engine (`~/dev/ac`).

## Approach: Zig module dependency

Since both Forge and this library are pure Zig, the simplest integration is adding this as a local module dependency in Forge's `build.zig`.

### Step 1: Add the module to Forge's build

In `~/dev/ac/build.zig`, add the VRF module alongside the existing dependencies:

```zig
// After the existing module setup for ac-viewer
const vrf_mod = b.addModule("valve-resource-format", .{
    .root_source_file = .{ .path = "../importers/src/root.zig" },
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("valve-resource-format", vrf_mod);
```

### Step 2: Import in Forge code

```zig
const vrf = @import("valve-resource-format");
```

## Integration points with Forge's existing architecture

### Asset Registry

Forge's `asset_registry.zig` manages materials and particle systems with a central registry pattern. VRF materials map naturally to this:

```zig
// In a new source2_import.zig or within gltf_import.zig
const vrf = @import("valve-resource-format");

pub fn importVMaterial(allocator: std.mem.Allocator, data: []const u8) !ImportedMaterial {
    // Parse resource
    var resource = vrf.Resource.init(allocator);
    defer resource.deinit();
    try resource.read(data);

    // Find and decode KV3 DATA block
    const data_block = resource.dataBlock() orelse return error.NoDataBlock;
    const raw = switch (data_block.data) {
        .data_block => |db| db.raw_data orelse return error.NoData,
        else => return error.UnexpectedBlock,
    };

    var doc = try vrf.binary_kv3.decode(allocator, raw);
    defer doc.deinit();

    var mat = vrf.Material.init(allocator);
    defer mat.deinit();
    try mat.readFromKV3(doc.root.asObject().?);

    // Map to Forge's material system
    return ImportedMaterial{
        .shader_name = mat.shader_name,
        .color_texture = mat.getTexture("g_tColor") orelse mat.getTexture("g_tColor1"),
        .normal_texture = mat.getTexture("g_tNormal") orelse mat.getTexture("g_tNormal1"),
        .roughness_texture = mat.getTexture("g_tRoughness"),
        .metalness = mat.getFloat("g_flMetalness") orelse 0.0,
        // ... map more params as needed
    };
}
```

### Texture loading

Forge's `texture.zig` loads textures via raylib's `rlLoadTexture`. VRF textures decode to RGBA8888, which maps directly:

```zig
pub fn importVTexture(allocator: std.mem.Allocator, data: []const u8) !rl.Texture2D {
    var resource = vrf.Resource.init(allocator);
    defer resource.deinit();
    try resource.read(data);

    const raw = ...; // extract DATA block raw bytes

    var tex = vrf.Texture.init(allocator);
    defer tex.deinit();
    try tex.readHeader(raw);

    const rgba = try tex.decodeRGBA();
    defer allocator.free(rgba);

    // Upload to GPU via raylib
    const rl_image = rl.Image{
        .data = rgba.ptr,
        .width = @intCast(tex.actualWidth()),
        .height = @intCast(tex.actualHeight()),
        .mipmaps = 1,
        .format = .PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };
    return rl.LoadTextureFromImage(rl_image);
}
```

### Model / Mesh import

Forge already has `gltf_import.zig` returning `ImportedScene` with `ImportedModel` structs. VRF models can follow the same pattern:

```zig
pub fn importVModel(allocator: std.mem.Allocator, vpk: *vrf.Package, model_path: []const u8) !ImportedScene {
    // 1. Extract and parse the .vmdl_c
    const entry = vpk.findEntry(model_path) orelse return error.NotFound;
    const data = try vpk.readEntry(entry);
    defer allocator.free(data);

    var resource = vrf.Resource.init(allocator);
    defer resource.deinit();
    try resource.read(data);

    // 2. Decode KV3 and parse model
    // ... decode DATA block ...
    var model = vrf.Model.init(allocator);
    defer model.deinit();
    try model.readFromKV3(root);

    // 3. For each referenced mesh, extract from VPK and parse
    for (model.ref_meshes) |mesh_path| {
        // Extract .vmesh_c from VPK
        // Parse VBIB block for vertex/index data
        // Build ImportedModel with positions, normals, texcoords
    }

    // 4. Map material groups to Forge materials
    for (model.material_groups) |group| {
        // Each group.materials[] is a .vmat path
    }
}
```

### VPK as asset source

For browsing CS2 game content, integrate VPK into the Asset Panel:

```zig
// Open CS2's main VPK
var cs2_pak = vrf.Package.init(allocator);
try cs2_pak.readFile("/path/to/cs2/pak01_dir.vpk");

// List all materials
var it = cs2_pak.iterateAll();
while (it.next()) |entry| {
    if (std.mem.endsWith(u8, entry.type_name, "vmat_c")) {
        // Show in asset browser
    }
}
```

## Source 2 to Forge shader mapping

Common CS2 shader parameters and their Forge equivalents:

| CS2 Parameter | CS2 Shader | Forge Equivalent |
|---------------|-----------|------------------|
| `g_tColor` / `g_tColor1` | Base color texture | Diffuse texture slot |
| `g_tNormal` / `g_tNormal1` | Normal map | Normal map slot |
| `g_tRoughness` | Roughness map | Roughness slot (if PBR) |
| `g_tMetalness` | Metalness map | Metalness slot (if PBR) |
| `g_tAmbientOcclusion` | AO map | AO texture slot |
| `g_flMetalness` | Float metalness | Material float param |
| `g_vColorTint` | Color tint vector | Material color property |
| `g_flAlphaTestReference` | Alpha test threshold | Alpha cutoff |
| `g_bFogEnabled` | Fog toggle | Render state flag |

## CS2 coordinate system

Source 2 uses Z-up, right-handed coordinates. Forge's existing `gltf_import.zig` already handles Y-up to Z-up conversion — the same transform applies to Source 2 vertex data.

---

# Quake 3 BSP Integration Guide

How to load Quake 3 BSP maps into Forge with geometry, lightmaps, materials, and PVS visibility.

## Quick start — loading a Q3 map

```zig
const vrf = @import("valve-resource-format");

pub fn loadQ3Map(allocator: std.mem.Allocator, bsp_path: []const u8) !void {
    // 1. Read the BSP file
    const file = try std.fs.cwd().openFile(bsp_path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, 256 * 1024 * 1024);
    defer allocator.free(data);

    var bsp = try vrf.Q3Bsp.read(allocator, data);
    defer bsp.deinit();

    // 2. Extract all renderable geometry (polygons + bezier patches)
    var mesh = try bsp.extractGeometry(allocator, .{});
    defer mesh.deinit();

    // 3. Build lightmap atlas
    var atlas = try vrf.buildLightmapAtlas(&bsp, allocator);
    defer atlas.deinit();

    // 4. Remap lightmap UVs to atlas space
    vrf.remapLightmapUVs(&mesh, &atlas);

    // 5. Upload to GPU (see sections below)
    // ...
}
```

## Uploading geometry to raylib

The extracted mesh has interleaved vertex data ready for GPU upload:

```zig
const rl = @import("raylib");

fn uploadMesh(mesh: *const vrf.ExtractedMesh) rl.Mesh {
    var rl_mesh: rl.Mesh = std.mem.zeroes(rl.Mesh);
    rl_mesh.vertexCount = @intCast(mesh.vertices.len);
    rl_mesh.triangleCount = @intCast(mesh.triangleCount());

    // Positions (3 floats per vertex)
    const positions = allocator.alloc(f32, mesh.vertices.len * 3);
    for (mesh.vertices, 0..) |v, i| {
        // Q3 is Z-up, Forge/raylib is Y-up: swizzle Y/Z
        positions[i * 3 + 0] = v.position[0];
        positions[i * 3 + 1] = v.position[2];  // Z -> Y
        positions[i * 3 + 2] = -v.position[1]; // -Y -> Z
    }
    rl_mesh.vertices = @ptrCast(positions.ptr);

    // Normals (same swizzle)
    const normals = allocator.alloc(f32, mesh.vertices.len * 3);
    for (mesh.vertices, 0..) |v, i| {
        normals[i * 3 + 0] = v.normal[0];
        normals[i * 3 + 1] = v.normal[2];
        normals[i * 3 + 2] = -v.normal[1];
    }
    rl_mesh.normals = @ptrCast(normals.ptr);

    // Texture coords (diffuse)
    const texcoords = allocator.alloc(f32, mesh.vertices.len * 2);
    for (mesh.vertices, 0..) |v, i| {
        texcoords[i * 2 + 0] = v.tex_coord[0];
        texcoords[i * 2 + 1] = v.tex_coord[1];
    }
    rl_mesh.texcoords = @ptrCast(texcoords.ptr);

    // Lightmap UVs (second UV channel) — already remapped to atlas space
    const texcoords2 = allocator.alloc(f32, mesh.vertices.len * 2);
    for (mesh.vertices, 0..) |v, i| {
        texcoords2[i * 2 + 0] = v.lightmap_coord[0];
        texcoords2[i * 2 + 1] = v.lightmap_coord[1];
    }
    rl_mesh.texcoords2 = @ptrCast(texcoords2.ptr);

    // Vertex colors
    const colors = allocator.alloc(u8, mesh.vertices.len * 4);
    for (mesh.vertices, 0..) |v, i| {
        colors[i * 4 + 0] = v.color[0];
        colors[i * 4 + 1] = v.color[1];
        colors[i * 4 + 2] = v.color[2];
        colors[i * 4 + 3] = v.color[3];
    }
    rl_mesh.colors = @ptrCast(colors.ptr);

    // Indices
    const indices = allocator.alloc(u16, mesh.indices.len);
    for (mesh.indices, 0..) |idx, i| {
        indices[i] = @intCast(idx);
    }
    rl_mesh.indices = @ptrCast(indices.ptr);

    rl.UploadMesh(&rl_mesh, false);
    return rl_mesh;
}
```

## Lightmap atlas as a texture

```zig
fn uploadLightmapAtlas(atlas: *const vrf.LightmapAtlas) rl.Texture2D {
    const image = rl.Image{
        .data = @ptrCast(atlas.pixels.ptr),
        .width = @intCast(atlas.width),
        .height = @intCast(atlas.height),
        .mipmaps = 1,
        .format = .PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };
    return rl.LoadTextureFromImage(image);
}
```

The lightmap atlas packs all 128x128 lightmaps into a grid. After calling `remapLightmapUVs()`, the `lightmap_coord` on each vertex already points into the correct atlas region. Use the second UV channel (`texcoords2`) to sample from this atlas in your shader.

## Lightmap shader

A minimal Q3-style lightmap shader multiplies diffuse texture by lightmap:

```glsl
// Fragment shader
uniform sampler2D texture0;   // diffuse
uniform sampler2D texture1;   // lightmap atlas

varying vec2 fragTexCoord;    // diffuse UVs
varying vec2 fragTexCoord2;   // lightmap UVs (atlas space)

void main() {
    vec4 diffuse = texture2D(texture0, fragTexCoord);
    vec4 light = texture2D(texture1, fragTexCoord2);
    gl_FragColor = diffuse * light * 2.0;  // x2 overbright like Q3
}
```

## Loading textures from PK3 files

PK3 files are ZIP archives containing textures and shader scripts:

```zig
fn loadTexturesFromPk3(
    allocator: std.mem.Allocator,
    pk3_path: []const u8,
    bsp: *const vrf.Q3Bsp,
) !void {
    // Read and open the pk3
    const pk3_data = try std.fs.cwd().readFileAlloc(allocator, pk3_path, 512 * 1024 * 1024);
    defer allocator.free(pk3_data);

    var pk3 = try vrf.Pk3.read(allocator, pk3_data);
    defer pk3.deinit();

    // Load shader scripts for material definitions
    var shader_db = vrf.ShaderDb.init(allocator);
    defer shader_db.deinit();

    for (pk3.iterateAll()) |path| {
        if (std.mem.endsWith(u8, path, ".shader")) {
            if (try pk3.extractFile(path, allocator)) |src| {
                defer allocator.free(src);
                try shader_db.loadShaderScript(src);
            }
        }
    }

    // Resolve textures for each BSP shader
    for (bsp.shaders) |*shader| {
        const name = shader.getName();

        // Check shader DB for texture path
        const tex_path = if (shader_db.find(name)) |s|
            s.getDiffuseMap()
        else
            null;

        // Try to extract texture from pk3
        const path_to_try = tex_path orelse name;
        const extensions = [_][]const u8{ "", ".tga", ".jpg", ".png" };
        for (extensions) |ext| {
            var buf: [512]u8 = undefined;
            const full_path = std.fmt.bufPrint(&buf, "{s}{s}", .{ path_to_try, ext }) catch continue;
            if (try pk3.extractFile(full_path, allocator)) |tex_data| {
                defer allocator.free(tex_data);
                // Load with raylib: rl.LoadImageFromMemory(), rl.LoadTextureFromImage()
                break;
            }
        }
    }
}
```

## Material properties from shader scripts

The shader DB provides rendering hints:

```zig
const shader = shader_db.find("textures/gothic_block/blocks11b");
if (shader) |s| {
    // Diffuse texture path
    const diffuse = s.getDiffuseMap(); // "textures/gothic_block/blocks11b.tga"

    // Rendering state
    const has_lightmap = s.hasLightmap();      // true for most world surfaces
    const is_transparent = s.is_transparent;    // surfaceparm trans
    const cull_mode = s.cull;                   // .front, .back, or .none
    const is_sky = s.sky_parms;                // skyparms directive

    // Blend mode from first stage
    if (s.stages.len > 0) {
        const stage = s.stages[0];
        // stage.blend_src / stage.blend_dst -> GL blend functions
        // stage.alpha_func -> alpha test (.gt0, .lt128, .ge128)
    }

    // Surface properties
    const is_water = s.hasSurfaceParm("water");
    const is_lava = s.hasSurfaceParm("lava");
    const no_lightmap = s.hasSurfaceParm("nolightmap");
}
```

## Q3 shader to Forge material mapping

| Q3 Shader Property | Forge Equivalent |
|---------------------|------------------|
| Stage 0 `map` (non-lightmap) | Diffuse texture slot |
| Stage `map $lightmap` | Lightmap atlas (second UV) |
| `blendFunc blend` | Alpha blending enabled |
| `blendFunc add` | Additive blending |
| `blendFunc filter` | Modulate (lightmap multiply) |
| `alphaFunc GE128` | Alpha test, cutoff = 0.5 |
| `cull none` | Double-sided rendering |
| `surfaceparm trans` | Transparent material flag |
| `surfaceparm nolightmap` | Skip lightmap sampling |
| `skyparms` | Skybox material |
| Vertex `color[4]` | Vertex color modulation |

## PVS visibility for runtime rendering

Use the BSP's PVS (Potentially Visible Set) to cull geometry each frame:

```zig
fn renderQ3Map(bsp: *const vrf.Q3Bsp, camera_pos: [3]f32, vp_matrix: [4][4]f32) void {
    // Build frustum from view-projection matrix
    const frustum = vrf.Frustum.fromViewProjection(vp_matrix);

    // Collect visible faces using PVS + frustum culling
    var vis = bsp.collectVisibleFaces(allocator, camera_pos, &frustum) catch return;
    defer vis.deinit();

    // Render only visible faces
    for (vis.face_indices[0..vis.count]) |face_idx| {
        const face = &bsp.faces[face_idx];
        // Draw this face's geometry...
    }
}
```

For a simpler approach (no per-frame culling), just render the full extracted mesh — the `extractGeometry()` output is a single indexed triangle list you can draw in one call.

## Front-to-back traversal for transparency

For scenes with transparent surfaces, use BSP front-to-back ordering:

```zig
bsp.walkFrontToBack(camera_pos, *RenderState, &state, struct {
    fn callback(ctx: *RenderState, leaf_index: usize, leaf: *const vrf.q3bsp.Leaf) void {
        // Render opaque faces in this leaf first (front-to-back)
        // Queue transparent faces for back-to-front pass
        _ = leaf_index;
        _ = leaf;
        _ = ctx;
    }
}.callback);
```

## Q3 coordinate system

Quake 3 uses **Z-up, right-handed** coordinates (same as Source 2). To convert to Forge/raylib's Y-up system:

```
Forge.X =  Q3.X
Forge.Y =  Q3.Z      (Q3 up -> Forge up)
Forge.Z = -Q3.Y      (Q3 forward -> Forge forward, negated)
```

Scale: Q3 units are roughly 1 inch. Divide by 64 for ~meter scale (as in the Blade3D loader), or use `1.0/32.0` for a common convention. Adjust to taste.

## Extraction options

Control what gets extracted:

```zig
var mesh = try bsp.extractGeometry(allocator, .{
    .patch_lod = 6,              // Bezier tessellation (higher = smoother)
    .skip_surface_flags = 0xC14, // Skip sky, nodraw, caulk
    .include_patches = true,     // Include curved surfaces
    .include_billboards = false, // Skip flare sprites
});
```

## What's ready now vs. future work

### Ready now
- Full IBSP v46 parsing (all 17 lumps)
- Geometry extraction (polygons, meshes, Bezier patches with configurable LOD)
- Lightmap atlas building and UV remapping
- PK3 archive reading (store + deflate compression)
- Shader script parsing (stages, blend modes, surface params, cull, sort)
- Entity parsing with typed accessors (classname, origin, angle)
- PVS cluster visibility testing
- Frustum culling (AABB + point tests)
- BSP tree front-to-back traversal
- Material/texture resolution from shader DB + PK3 lookup

### Future work
- Shader animation (tcMod scroll/rotate/turb, animMap frame cycling)
- Skybox rendering (skyparms farbox/nearbox)
- Fog volumes (effect/fog brush rendering)
- Curved surface LOD (distance-based patch tessellation)
- Collision detection using brush/brushside data
- Light volume sampling for dynamic object lighting
- Entity spawning (weapons, items, player starts -> Forge scene objects)

---

## What's ready now vs. future work

### Ready now
- VPK archive browsing and extraction
- Resource file parsing (all block types)
- KV3 decoding (v1-5, uncompressed + ZSTD + LZ4)
- Material property extraction (shader, textures, params)
- Texture decoding to RGBA8888 (BC1/3/4/5/7, RGBA, BGRA, I8, IA88)
- Model metadata (mesh refs, material groups, LoD masks)
- Mesh structure (scene objects, draw calls, buffer layouts)
- World/WorldNode structure

### Future work
- VBIB binary buffer parsing (raw vertex/index data extraction from VBIB blocks)
- Vertex attribute decoding (compressed normals, half-float UVs, etc.)
- Skeleton/bone hierarchy parsing
- Animation data
- LZ4 chain decoding for compressed texture mip data
- glTF export (bridge to Forge's existing glTF importer)
- Particle system import (VRF ParticleSystem -> Forge particle graph)
