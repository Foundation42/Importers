const std = @import("std");

/// Source 2 compiled resource types, identified by file extension.
pub const ResourceType = enum {
    unknown,
    animation, // .vanim
    animation_group, // .vagrp
    animation_graph, // .vanmgrph
    nm_graph, // .vnmgraph
    nm_graph_variation, // .vnmvar
    nm_skeleton, // .vnmskel
    nm_clip, // .vnmclip
    nm_ik_rig, // .vnmikrig
    action_list, // .valst
    sequence, // .vseq
    particle, // .vpcf
    material, // .vmat
    sheet, // .vmks
    mesh, // .vmesh
    texture, // .vtex
    model, // .vmdl
    physics_collision_mesh, // .vphys
    sound, // .vsnd
    morph, // .vmorf
    resource_manifest, // .vrman
    world, // .vwrld
    world_node, // .vwnod
    world_visibility, // .vvis
    entity_lump, // .vents
    surface_properties, // .vsurf
    sound_event_script, // .vsndevts
    vmix, // .vmix
    sound_stack_script, // .vsndstck
    bitmap_font, // .vfont
    resource_remap_table, // .vrmap
    choreo_scene_file_data, // .vcdlist
    choreo_scene_resource, // .vcd
    panorama, // .vtxt
    panorama_style, // .vcss
    panorama_layout, // .vxml
    panorama_dynamic_images, // .vpdi
    panorama_script, // .vjs
    panorama_typescript, // .vts
    panorama_vector_graphic, // .vsvg
    particle_snapshot_legacy, // .vpsf
    particle_snapshot, // .vsnap
    map, // .vmap
    post_processing, // .vpost
    vdata, // .vdata
    composite_material, // .vcompmat
    response_rules, // .vrr
    econ_item, // .econitem
    artifact_item, // .item
    pulse_graph_def, // .vpulse
    smart_prop, // .vsmart
    processing_graph_instance, // .vpram
    dota_hero_list, // .herolist
    dota_patch_notes, // .vdpn
    dota_visual_novels, // .vdvn
    sbox_managed_resource, // .sbox
    sbox_shader, // .shader
    shader, // .vcs

    /// File extension (without leading dot) for each resource type.
    /// Returns null for unknown.
    pub fn extension(self: ResourceType) ?[]const u8 {
        return switch (self) {
            .unknown => null,
            .animation => "vanim",
            .animation_group => "vagrp",
            .animation_graph => "vanmgrph",
            .nm_graph => "vnmgraph",
            .nm_graph_variation => "vnmvar",
            .nm_skeleton => "vnmskel",
            .nm_clip => "vnmclip",
            .nm_ik_rig => "vnmikrig",
            .action_list => "valst",
            .sequence => "vseq",
            .particle => "vpcf",
            .material => "vmat",
            .sheet => "vmks",
            .mesh => "vmesh",
            .texture => "vtex",
            .model => "vmdl",
            .physics_collision_mesh => "vphys",
            .sound => "vsnd",
            .morph => "vmorf",
            .resource_manifest => "vrman",
            .world => "vwrld",
            .world_node => "vwnod",
            .world_visibility => "vvis",
            .entity_lump => "vents",
            .surface_properties => "vsurf",
            .sound_event_script => "vsndevts",
            .vmix => "vmix",
            .sound_stack_script => "vsndstck",
            .bitmap_font => "vfont",
            .resource_remap_table => "vrmap",
            .choreo_scene_file_data => "vcdlist",
            .choreo_scene_resource => "vcd",
            .panorama => "vtxt",
            .panorama_style => "vcss",
            .panorama_layout => "vxml",
            .panorama_dynamic_images => "vpdi",
            .panorama_script => "vjs",
            .panorama_typescript => "vts",
            .panorama_vector_graphic => "vsvg",
            .particle_snapshot_legacy => "vpsf",
            .particle_snapshot => "vsnap",
            .map => "vmap",
            .post_processing => "vpost",
            .vdata => "vdata",
            .composite_material => "vcompmat",
            .response_rules => "vrr",
            .econ_item => "econitem",
            .artifact_item => "item",
            .pulse_graph_def => "vpulse",
            .smart_prop => "vsmart",
            .processing_graph_instance => "vpram",
            .dota_hero_list => "herolist",
            .dota_patch_notes => "vdpn",
            .dota_visual_novels => "vdvn",
            .sbox_managed_resource => "sbox",
            .sbox_shader => "shader",
            .shader => "vcs",
        };
    }

    /// Determine resource type from file extension.
    /// The extension should be without leading dot and without the "_c" compiled suffix.
    /// E.g. pass "vtex" not ".vtex_c".
    pub fn fromExtension(ext: []const u8) ResourceType {
        const map = comptime buildExtensionMap();
        return map.get(ext) orelse .unknown;
    }

    /// Determine resource type from a full filename.
    /// Handles the "_c" suffix convention (e.g. "model.vmdl_c").
    pub fn fromFileName(filename: []const u8) ResourceType {
        // Get the extension part after the last '.'
        const ext_with_dot = std.fs.path.extension(filename);
        if (ext_with_dot.len == 0) return .unknown;

        // Remove leading dot
        var ext = ext_with_dot[1..];

        // Strip "_c" compiled suffix
        if (ext.len > 2 and std.mem.endsWith(u8, ext, "_c")) {
            ext = ext[0 .. ext.len - 2];
        }

        return fromExtension(ext);
    }

    /// Determine resource type from a compiler identifier string.
    /// Handles the "Compile" prefix convention.
    pub fn fromCompilerIdentifier(identifier: []const u8, string_value: []const u8) ResourceType {
        // Strip "Compile" prefix if present
        const id = if (std.mem.startsWith(u8, identifier, "Compile"))
            identifier[7..]
        else
            identifier;

        // Special mappings
        if (std.mem.eql(u8, id, "Animgraph")) return .animation_graph;
        if (std.mem.eql(u8, id, "AnimGroup")) return .animation_group;
        if (std.mem.eql(u8, id, "ChoreoSceneFileData")) return .choreo_scene_file_data;
        if (std.mem.eql(u8, id, "ChoreoSceneResource")) return .choreo_scene_resource;
        if (std.mem.eql(u8, id, "CSGOEconItem") or std.mem.eql(u8, id, "CSGOItem")) return .econ_item;
        if (std.mem.eql(u8, id, "DotaHeroList")) return .dota_hero_list;
        if (std.mem.eql(u8, id, "DotaItem")) return .artifact_item;
        if (std.mem.eql(u8, id, "DotaPatchNotes")) return .dota_patch_notes;
        if (std.mem.eql(u8, id, "DotaVisualNovels")) return .dota_visual_novels;
        if (std.mem.eql(u8, id, "Font")) return .bitmap_font;
        if (std.mem.eql(u8, id, "GraphInstance")) return .processing_graph_instance;
        if (std.mem.eql(u8, id, "NmClip")) return .nm_clip;
        if (std.mem.eql(u8, id, "NmGraph")) return .nm_graph;
        if (std.mem.eql(u8, id, "NmGraphVariation")) return .nm_graph_variation;
        if (std.mem.eql(u8, id, "NmSkeleton")) return .nm_skeleton;
        if (std.mem.eql(u8, id, "NmIKRig")) return .nm_ik_rig;
        if (std.mem.eql(u8, id, "Panorama")) {
            if (std.mem.eql(u8, string_value, "Panorama Style Compiler Version")) return .panorama_style;
            if (std.mem.eql(u8, string_value, "Panorama Script Compiler Version")) return .panorama_script;
            if (std.mem.eql(u8, string_value, "Panorama Layout Compiler Version")) return .panorama_layout;
            if (std.mem.eql(u8, string_value, "Panorama Dynamic Images Compiler Version")) return .panorama_dynamic_images;
            return .panorama;
        }
        if (std.mem.eql(u8, id, "Psf")) return .particle_snapshot_legacy;
        if (std.mem.eql(u8, id, "PulseGraphDef")) return .pulse_graph_def;
        if (std.mem.eql(u8, id, "RenderMesh")) return .mesh;
        if (std.mem.eql(u8, id, "ResponseRules")) return .response_rules;
        if (std.mem.eql(u8, id, "SBData") or std.mem.eql(u8, id, "ManagedResourceCompiler")) return .sbox_managed_resource;
        if (std.mem.eql(u8, id, "SmartProp")) return .smart_prop;
        if (std.mem.eql(u8, id, "TypeScript")) return .panorama_typescript;
        if (std.mem.eql(u8, id, "VCompMat")) return .composite_material;
        if (std.mem.eql(u8, id, "VData")) return .vdata;
        if (std.mem.eql(u8, id, "VectorGraphic")) return .panorama_vector_graphic;
        if (std.mem.eql(u8, id, "VPhysXData")) return .physics_collision_mesh;

        // Try direct enum name match (e.g. "Texture" -> .texture)
        // Match against known identifiers that correspond directly to enum names
        if (std.mem.eql(u8, id, "Texture")) return .texture;
        if (std.mem.eql(u8, id, "Material")) return .material;
        if (std.mem.eql(u8, id, "Model")) return .model;
        if (std.mem.eql(u8, id, "Particle")) return .particle;
        if (std.mem.eql(u8, id, "Sound")) return .sound;
        if (std.mem.eql(u8, id, "World")) return .world;
        if (std.mem.eql(u8, id, "WorldNode")) return .world_node;
        if (std.mem.eql(u8, id, "EntityLump")) return .entity_lump;
        if (std.mem.eql(u8, id, "Animation")) return .animation;
        if (std.mem.eql(u8, id, "Mesh")) return .mesh;
        if (std.mem.eql(u8, id, "Morph")) return .morph;
        if (std.mem.eql(u8, id, "Sequence")) return .sequence;
        if (std.mem.eql(u8, id, "PostProcessing")) return .post_processing;
        if (std.mem.eql(u8, id, "SurfaceProperties")) return .surface_properties;
        if (std.mem.eql(u8, id, "SoundEventScript")) return .sound_event_script;
        if (std.mem.eql(u8, id, "SoundStackScript")) return .sound_stack_script;

        return .unknown;
    }

    fn buildExtensionMap() std.StaticStringMap(ResourceType) {
        const kvs = .{
            .{ "vanim", ResourceType.animation },
            .{ "vagrp", ResourceType.animation_group },
            .{ "vanmgrph", ResourceType.animation_graph },
            .{ "vnmgraph", ResourceType.nm_graph },
            .{ "vnmvar", ResourceType.nm_graph_variation },
            .{ "vnmskel", ResourceType.nm_skeleton },
            .{ "vnmclip", ResourceType.nm_clip },
            .{ "vnmikrig", ResourceType.nm_ik_rig },
            .{ "valst", ResourceType.action_list },
            .{ "vseq", ResourceType.sequence },
            .{ "vpcf", ResourceType.particle },
            .{ "vmat", ResourceType.material },
            .{ "vmks", ResourceType.sheet },
            .{ "vmesh", ResourceType.mesh },
            .{ "vtex", ResourceType.texture },
            .{ "vmdl", ResourceType.model },
            .{ "vphys", ResourceType.physics_collision_mesh },
            .{ "vsnd", ResourceType.sound },
            .{ "vmorf", ResourceType.morph },
            .{ "vrman", ResourceType.resource_manifest },
            .{ "vwrld", ResourceType.world },
            .{ "vwnod", ResourceType.world_node },
            .{ "vvis", ResourceType.world_visibility },
            .{ "vents", ResourceType.entity_lump },
            .{ "vsurf", ResourceType.surface_properties },
            .{ "vsndevts", ResourceType.sound_event_script },
            .{ "vmix", ResourceType.vmix },
            .{ "vsndstck", ResourceType.sound_stack_script },
            .{ "vfont", ResourceType.bitmap_font },
            .{ "vrmap", ResourceType.resource_remap_table },
            .{ "vcdlist", ResourceType.choreo_scene_file_data },
            .{ "vcd", ResourceType.choreo_scene_resource },
            .{ "vtxt", ResourceType.panorama },
            .{ "vcss", ResourceType.panorama_style },
            .{ "vxml", ResourceType.panorama_layout },
            .{ "vpdi", ResourceType.panorama_dynamic_images },
            .{ "vjs", ResourceType.panorama_script },
            .{ "vts", ResourceType.panorama_typescript },
            .{ "vsvg", ResourceType.panorama_vector_graphic },
            .{ "vpsf", ResourceType.particle_snapshot_legacy },
            .{ "vsnap", ResourceType.particle_snapshot },
            .{ "vmap", ResourceType.map },
            .{ "vpost", ResourceType.post_processing },
            .{ "vdata", ResourceType.vdata },
            .{ "vcompmat", ResourceType.composite_material },
            .{ "vrr", ResourceType.response_rules },
            .{ "econitem", ResourceType.econ_item },
            .{ "item", ResourceType.artifact_item },
            .{ "vpulse", ResourceType.pulse_graph_def },
            .{ "vsmart", ResourceType.smart_prop },
            .{ "vpram", ResourceType.processing_graph_instance },
            .{ "herolist", ResourceType.dota_hero_list },
            .{ "vdpn", ResourceType.dota_patch_notes },
            .{ "vdvn", ResourceType.dota_visual_novels },
            .{ "sbox", ResourceType.sbox_managed_resource },
            .{ "shader", ResourceType.sbox_shader },
            .{ "vcs", ResourceType.shader },
        };
        return std.StaticStringMap(ResourceType).initComptime(kvs);
    }
};

test "ResourceType extension roundtrip" {
    const rt = ResourceType.texture;
    const ext = rt.extension().?;
    try std.testing.expectEqualStrings("vtex", ext);
    try std.testing.expectEqual(ResourceType.texture, ResourceType.fromExtension(ext));
}

test "ResourceType from filename" {
    try std.testing.expectEqual(ResourceType.model, ResourceType.fromFileName("player.vmdl_c"));
    try std.testing.expectEqual(ResourceType.texture, ResourceType.fromFileName("diffuse.vtex_c"));
    try std.testing.expectEqual(ResourceType.material, ResourceType.fromFileName("metal.vmat_c"));
    try std.testing.expectEqual(ResourceType.unknown, ResourceType.fromFileName("random.bin"));
}

test "ResourceType from compiler identifier" {
    try std.testing.expectEqual(ResourceType.texture, ResourceType.fromCompilerIdentifier("CompileTexture", ""));
    try std.testing.expectEqual(ResourceType.animation_graph, ResourceType.fromCompilerIdentifier("CompileAnimgraph", ""));
    try std.testing.expectEqual(ResourceType.panorama_style, ResourceType.fromCompilerIdentifier("CompilePanorama", "Panorama Style Compiler Version"));
    try std.testing.expectEqual(ResourceType.econ_item, ResourceType.fromCompilerIdentifier("CompileCSGOEconItem", ""));
}
