//! Valve Resource Format (VRF) parser for Source 2 compiled resources.
//!
//! A native Zig port of the core ValveResourceFormat library
//! (https://github.com/ValveResourceFormat/ValveResourceFormat).
//!
//! This library parses Valve's Source 2 compiled resource files (typically
//! ending in `_c`) and provides access to their blocks and data.

pub const BlockType = @import("block_type.zig").BlockType;
pub const ResourceType = @import("resource_type.zig").ResourceType;
pub const BinaryReader = @import("binary_reader.zig").BinaryReader;
pub const Resource = @import("resource.zig").Resource;

pub const block = @import("block.zig");
pub const Block = block.Block;
pub const BlockData = block.BlockData;
pub const RerlData = block.RerlData;
pub const RediData = block.RediData;
pub const ResourceReferenceInfo = block.ResourceReferenceInfo;
pub const InputDependency = block.InputDependency;
pub const SpecialDependency = block.SpecialDependency;
pub const ArgumentDependency = block.ArgumentDependency;
pub const AdditionalRelatedFile = block.AdditionalRelatedFile;

// VPK archive reader
pub const vpk = @import("vpk.zig");
pub const Package = vpk.Package;
pub const PackageEntry = vpk.PackageEntry;

// KV3 (KeyValues3) data model and binary decoder
pub const kv3 = @import("kv3.zig");
pub const KVValue = kv3.KVValue;
pub const KVObject = kv3.KVObject;
pub const KVArray = kv3.KVArray;
pub const KVFlag = kv3.KVFlag;
pub const binary_kv3 = @import("binary_kv3.zig");
pub const KV3Document = binary_kv3.KV3Document;

// Texture parsing and decoding
pub const texture = @import("texture.zig");
pub const Texture = texture.Texture;
pub const VTexFormat = texture.VTexFormat;
pub const VTexFlags = texture.VTexFlags;
pub const texture_decode = @import("texture_decode.zig");

// Resource type handlers
pub const material = @import("material.zig");
pub const Material = material.Material;
pub const mesh_mod = @import("mesh.zig");
pub const VBIB = mesh_mod.VBIB;
pub const Mesh = mesh_mod.Mesh;
pub const DrawCall = mesh_mod.DrawCall;
pub const SceneObject = mesh_mod.SceneObject;
pub const DxgiFormat = mesh_mod.DxgiFormat;
pub const RenderInputLayoutField = mesh_mod.RenderInputLayoutField;
pub const model = @import("model.zig");
pub const Model = model.Model;
pub const World = model.World;
pub const WorldNode = model.WorldNode;

// Compression and mesh decoding
pub const lz4 = @import("lz4.zig");
pub const meshopt = @import("meshopt.zig");

// Quake 3 BSP
pub const q3bsp = @import("q3bsp.zig");
pub const Q3Bsp = q3bsp.Q3Bsp;
pub const ExtractedMesh = q3bsp.ExtractedMesh;
pub const SubMesh = q3bsp.SubMesh;
pub const ExtractOptions = q3bsp.ExtractOptions;
pub const LightmapAtlas = q3bsp.LightmapAtlas;
pub const buildLightmapAtlas = q3bsp.buildLightmapAtlas;
pub const remapLightmapUVs = q3bsp.remapLightmapUVs;
pub const Frustum = q3bsp.Frustum;
pub const VisibleSet = q3bsp.VisibleSet;

// Quake 3 PK3 archives and shader scripts
pub const pk3 = @import("pk3.zig");
pub const Pk3 = pk3.Pk3;
pub const q3shader = @import("q3shader.zig");
pub const ShaderDb = q3shader.ShaderDb;
pub const Q3Shader = q3shader.Shader;

// Re-export constants
pub const known_header_version = @import("resource.zig").known_header_version;
pub const vpk_magic = @import("resource.zig").vpk_magic;

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
