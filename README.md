# Valve Resource Format — Native Zig

A native Zig port of the core [ValveResourceFormat](https://github.com/ValveResourceFormat/ValveResourceFormat) library for parsing Valve's Source 2 compiled resource files (CS2, Dota 2, Half-Life: Alyx, etc.).

Zero external dependencies. Pure Zig with `std.compress.zstd` for ZSTD decompression.

## What it parses

| Format | Description |
|--------|-------------|
| `.vpk` | VPK v1/v2 archives — directory tree, entry lookup, data extraction |
| `.vmat_c` | Materials — shader name, texture/float/int/vector params and attributes |
| `.vtex_c` | Textures — header, mip levels, pixel data decoding |
| `.vmdl_c` | Models — mesh references, LoD masks, material groups, skeleton refs |
| `.vmesh_c` | Meshes — scene objects, draw calls, vertex/index buffer layouts |
| `.vwrld_c` | Worlds — entity lumps, world node references |
| `.vwnod_c` | World Nodes — scene objects, layer names |
| Any `_c` | Generic Source 2 resource — header, blocks (RERL, REDI, RED2, NTRO, DATA, VBIB, CTRL, etc.) |

### Texture decoders

BC1/DXT1, BC3/DXT5, BC4/ATI1N, BC5/ATI2N, BC7, RGBA8888, BGRA8888, I8, IA88.

### KV3 (KeyValues3) binary decoder

Versions 1-5 with LZ4 and ZSTD decompression. Handles aligned multi-width buffers, string tables, typed arrays, nested objects, binary blobs, and v5 dual-buffer architecture.

## Building

Requires Zig 0.14+.

```sh
zig build          # build library + CLI tool
zig build test     # run all 51 tests
zig build run -- path/to/file.vmat_c   # dump resource info
```

## Quick start

### Parse a resource file

```zig
const vrf = @import("valve-resource-format");

var resource = vrf.Resource.init(allocator);
defer resource.deinit();
try resource.readFile("weapon_ak47.vmat_c");

// Resource type detected from extension
// resource.resource_type == .material

// Access blocks
if (resource.externalReferences()) |rerl| {
    for (rerl.resource_ref_info_list) |ref| {
        std.debug.print("{s}\n", .{ref.name});
    }
}
```

### Open a VPK archive

```zig
var pkg = vrf.Package.init(allocator);
defer pkg.deinit();
try pkg.readFile("pak01_dir.vpk");

// Find a file
if (pkg.findEntry("materials/metal/metal_01.vmat_c")) |entry| {
    const data = try pkg.readEntry(entry);
    defer allocator.free(data);
    // Parse the extracted resource...
}

// Iterate all entries
var it = pkg.iterateAll();
while (it.next()) |entry| {
    const path = try entry.getFullPath(allocator);
    defer allocator.free(path);
    std.debug.print("{s} ({d} bytes)\n", .{ path, entry.totalLength() });
}
```

### Decode KV3 data and read material properties

```zig
const binary_kv3 = vrf.binary_kv3;

// Decode KV3 from a DATA block's raw bytes
var doc = try binary_kv3.decode(allocator, raw_data);
defer doc.deinit();

// Parse as material
const root = doc.root.asObject().?;
var mat = vrf.Material.init(allocator);
defer mat.deinit();
try mat.readFromKV3(root);

std.debug.print("Shader: {s}\n", .{mat.shader_name.?});
if (mat.getTexture("g_tColor")) |path| {
    std.debug.print("Color map: {s}\n", .{path});
}
```

### Decode a texture to RGBA pixels

```zig
var tex = vrf.Texture.init(allocator);
defer tex.deinit();
try tex.readHeader(data_block_bytes);

const rgba = try tex.decodeRGBA(); // mip 0 -> RGBA8888
defer allocator.free(rgba);
// rgba is width * height * 4 bytes
```

## Architecture

```
src/
  root.zig              Public API
  binary_reader.zig     Slice-based little-endian reader
  block_type.zig        28 block types (ASCII-packed u32)
  resource_type.zig     58 resource types + extension/compiler-id lookup
  block.zig             Block data union (RERL, REDI, NTRO, DATA, KV3)
  resource.zig          Resource file parser (header + two-pass block reading)
  vpk.zig               VPK v1/v2 archive reader
  kv3.zig               KV3 data model (KVObject, KVArray, KVValue, KVFlag)
  binary_kv3.zig        BinaryKV3 decoder (v1-5, LZ4/ZSTD)
  lz4.zig               LZ4 raw block decompressor
  texture.zig           Texture header parser + format enums
  texture_decode.zig    BCn (BC1/3/4/5/7) + simple format decoders
  material.zig          Material resource handler
  mesh.zig              VBIB, Mesh, DrawCall, DxgiFormat
  model.zig             Model, World, WorldNode handlers
  main.zig              CLI tool (vrf-tool)
```

## Pipeline flow

```
VPK archive
  -> Package.findEntry() / readEntry()
    -> Resource.read()  (header + blocks)
      -> binary_kv3.decode()  (KV3 data from DATA/CTRL/RED2 blocks)
        -> Material / Model / Mesh .readFromKV3()  (structured game data)
      -> Texture.readHeader() + decodeRGBA()  (pixel data)
```

## Credits

Ported from [ValveResourceFormat](https://github.com/ValveResourceFormat/ValveResourceFormat) by the SteamDatabase community. VRF is an incredible reverse-engineering effort — this project wouldn't exist without their work.

## License

MIT
