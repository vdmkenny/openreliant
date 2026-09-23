// The shadow maps' depth pass (src/platform/gpu/shadows.zig): the casters' triangles, in the
// camera's frame, drawn into one cascade's map, their depth from the sun's side. It writes depth
// alone; `make shaders` compiles it as the device's shader is.
#version 450

#ifdef VERTEX

layout(location = 0) in vec3 position;

// Where a point of the camera's frame falls in the cascade's map: each row dotted with the point
// and 1 gives across, up and depth (srshadow.zig).
layout(set = 1, binding = 0) uniform Cascade {
    vec4 rows[3];
} cascade;

void main() {
    vec4 point = vec4(position, 1.0);
    gl_Position = vec4(dot(cascade.rows[0], point), dot(cascade.rows[1], point), dot(cascade.rows[2], point), 1.0);
}

#endif

#ifdef FRAGMENT

void main() {
}

#endif
