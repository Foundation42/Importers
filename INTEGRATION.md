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
