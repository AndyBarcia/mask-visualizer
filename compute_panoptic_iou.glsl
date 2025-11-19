#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2DArray panoptic_maps;

struct PairEntry {
    uint id_a;
    uint id_b;
    uint count;
    uint _pad;
};

struct AreaEntry {
    uint id;
    uint count;
    uint _pad0;
    uint _pad1;
};

// Binding 1: Intersections (A vs B)
layout(set = 0, binding = 1, std430) restrict buffer PairBuffer {
    PairEntry entries[];
} pair_map;

// Binding 2: Area Histogram for Layer A
layout(set = 0, binding = 2, std430) restrict buffer AreaBufferA {
    AreaEntry entries[];
} area_map_a;

// Binding 3: Area Histogram for Layer B
layout(set = 0, binding = 3, std430) restrict buffer AreaBufferB {
    AreaEntry entries[];
} area_map_b;

layout(push_constant) uniform Params {
    vec2 texture_size;
    uint layer_a;
    uint layer_b;
    uint map_size_pair; // Size for binding 1
    uint map_size_area; // Size for binding 2 and 3
    uint _pad0;          // 24 - 27
    uint _pad1;          // 28 - 31
} params;

uint decode_id(vec3 rgb) {
    uvec3 c = uvec3(round(rgb * 255.0));
    return c.r + (c.g << 8) + (c.b << 16);
}

uint hash_u1(uint v) {
    v ^= v >> 16; v *= 0x85ebca6b; v ^= v >> 13; v *= 0xc2b2ae35; v ^= v >> 16;
    return v;
}

uint hash_u2(uvec2 v) {
    uint h = v.x ^ (v.y * 0x517cc1b7);
    h ^= h >> 16; h *= 0x85ebca6b; h ^= h >> 13; h *= 0xc2b2ae35; h ^= h >> 16;
    return h;
}

void add_area(uint id, uint map_size, bool is_layer_a) {
    uint idx   = hash_u1(id) % map_size;
    uint start = idx;

    for (int i = 0; i < 100; i++) {

        if (is_layer_a) {
            // Try to claim or reuse slot in area_map_a
            uint prev = atomicCompSwap(area_map_a.entries[idx].id, 0u, id);

            if (prev == 0u || prev == id) {
                // Either we just claimed the slot (prev == 0)
                // or it was already ours (prev == id)
                atomicAdd(area_map_a.entries[idx].count, 1u);
                break;
            }
        } else {
            // Same idea for area_map_b
            uint prev = atomicCompSwap(area_map_b.entries[idx].id, 0u, id);

            if (prev == 0u || prev == id) {
                atomicAdd(area_map_b.entries[idx].count, 1u);
                break;
            }
        }

        // Different id in this slot → probe
        idx = (idx + 1u) % map_size;
        if (idx == start) break;
    }
}

void add_pair(uint id_a, uint id_b, uint map_size) {
    uint idx   = hash_u2(uvec2(id_a, id_b)) % map_size;
    uint start = idx;

    for (int i = 0; i < 100; i++) {

        // Try to claim the slot by writing id_a from 0 -> id_a
        uint stored_a = atomicCompSwap(pair_map.entries[idx].id_a, 0u, id_a);

        if (stored_a == 0u) {
            // We just claimed slot; now write id_b and count.
            pair_map.entries[idx].id_b = id_b;
            atomicAdd(pair_map.entries[idx].count, 1u);
            break;
        }

        // Slot already has some id_a
        if (stored_a == id_a && pair_map.entries[idx].id_b == id_b) {
            // Same pair, just increment
            atomicAdd(pair_map.entries[idx].count, 1u);
            break;
        }

        // Different pair -> probe
        idx = (idx + 1u) % map_size;
        if (idx == start) break;
    }
}

void main() {
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
    if (uv.x >= params.texture_size.x || uv.y >= params.texture_size.y) return;

    vec3 c_a = texelFetch(panoptic_maps, ivec3(uv, params.layer_a), 0).rgb;
    vec3 c_b = texelFetch(panoptic_maps, ivec3(uv, params.layer_b), 0).rgb;

    uint id_a = decode_id(c_a);
    uint id_b = decode_id(c_b);

    if (id_a > 0) add_area(id_a, params.map_size_area, true);
    if (id_b > 0) add_area(id_b, params.map_size_area, false);
    if (id_a > 0 && id_b > 0) add_pair(id_a, id_b, params.map_size_pair);
}
