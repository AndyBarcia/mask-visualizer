#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D panoptic_map;

struct BBoxEntry {
    uint id;
    uint min_x;
    uint min_y;
    uint max_x;
    uint max_y;
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

layout(set = 0, binding = 1, std430) restrict buffer BBoxBuffer {
    BBoxEntry entries[];
} bbox_map;

layout(push_constant) uniform Params {
    vec2 texture_size;
    uint map_size;
    uint _pad0;
} params;

uint decode_id(vec3 rgb) {
    uvec3 c = uvec3(round(rgb * 255.0));
    return c.r + (c.g << 8) + (c.b << 16);
}

uint hash_u1(uint v) {
    v ^= v >> 16; v *= 0x85ebca6bu; v ^= v >> 13; v *= 0xc2b2ae35u; v ^= v >> 16;
    return v;
}

void main() {
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
    if (uv.x >= params.texture_size.x || uv.y >= params.texture_size.y) return;

    vec3 c = texelFetch(panoptic_map, uv, 0).rgb;
    uint id = decode_id(c);
    if (id == 0u) return;

    uint idx = hash_u1(id) % params.map_size;
    uint start = idx;

    for (int i = 0; i < 128; i++) {
        uint prev = atomicCompSwap(bbox_map.entries[idx].id, 0u, id);
        if (prev == 0u || prev == id) {
            atomicMin(bbox_map.entries[idx].min_x, uint(uv.x));
            atomicMin(bbox_map.entries[idx].min_y, uint(uv.y));
            atomicMax(bbox_map.entries[idx].max_x, uint(uv.x));
            atomicMax(bbox_map.entries[idx].max_y, uint(uv.y));
            break;
        }

        idx = (idx + 1u) % params.map_size;
        if (idx == start) break;
    }
}
