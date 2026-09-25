// The shadow maps' depth pass (src/platform/gpu/shadows.zig): the casters' triangles, in the
// camera's frame, drawn into one cascade's map, their depth from the sun's side. It writes depth
// alone; `make shaders` compiles it as the device's shader is.
#version 450

#ifdef VERTEX

layout(location = 0) in vec3 position;
// How strong a shadow the triangle casts, from nothing to whole (srshadow.Corner).
layout(location = 1) in float strength;

layout(location = 0) flat out float kept;

// Where a point of the camera's frame falls in the cascade's map: each row dotted with the point
// and 1 gives across, up and depth (srshadow.zig).
layout(set = 1, binding = 0) uniform Cascade {
    vec4 rows[3];
} cascade;

void main() {
    vec4 point = vec4(position, 1.0);
    gl_Position = vec4(dot(cascade.rows[0], point), dot(cascade.rows[1], point), dot(cascade.rows[2], point), 1.0);
    kept = strength;
}

#endif

#ifdef FRAGMENT

layout(location = 0) flat in float kept;

// The order in which a faint caster's texels drop out, over each four by four: a whole one keeps
// them all, and one half as strong every other, which the lookup's filtering blends into a shadow
// half as dark.
const float dither[16] = float[](
    0.0, 8.0, 2.0, 10.0,
    12.0, 4.0, 14.0, 6.0,
    3.0, 11.0, 1.0, 9.0,
    15.0, 7.0, 13.0, 5.0
);

void main() {
    ivec2 texel = ivec2(gl_FragCoord.xy) & 3;
    if (kept < 1.0 && kept * 16.0 <= dither[texel.y * 4 + texel.x]) discard;
}

#endif
