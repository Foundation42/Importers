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

// Re-export constants
pub const known_header_version = @import("resource.zig").known_header_version;
pub const vpk_magic = @import("resource.zig").vpk_magic;

test {
    // Run all tests in submodules
    @import("std").testing.refAllDecls(@This());
}
