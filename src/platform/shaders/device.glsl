// The game's one shader: what Direct3D 7's fixed function did with the vertices Surrender's driver
// hands over, for SDL's GPU interface. `make shaders` compiles the vertex stage, with VERTEX
// defined, and the fragment stage, with FRAGMENT, into SPIR-V, and from that into Metal's
// language. The platform layer embeds what it makes (src/platform/gpu.zig).
#version 450

#ifdef VERTEX

// A vertex as the driver hands it over: on the screen, pixel centres on whole numbers, as
// Direct3D 7 has them; its depth, nearer greater; and one over its distance, scaled.
layout(location = 0) in vec4 position;
// Its colour's bytes as they lie in memory: blue, green, red and alpha.
layout(location = 1) in vec4 diffuse;
layout(location = 2) in vec2 coordinates;
// Its texture's layer in the bound array, or -1 for none.
layout(location = 3) in int layer;

layout(set = 1, binding = 0) uniform Target {
    // The frame's width and height in pixels.
    vec2 size;
} target;

layout(location = 0) out vec4 colour;
layout(location = 1) out vec2 uv;
layout(location = 2) flat out int image;

void main() {
    // One over the reciprocal depth as the clip w makes colours and texture coordinates vary in
    // perspective, as Direct3D 7 made them by rhw. Stars carry none.
    float w = position.w > 0.0 ? 1.0 / position.w : 1.0;
    // Pixel centres lie half a pixel on from Direct3D 7's here.
    vec2 ndc = vec2((position.x + 0.5) / target.size.x * 2.0 - 1.0, 1.0 - (position.y + 0.5) / target.size.y * 2.0);
    gl_Position = vec4(ndc * w, position.z * w, w);
    gl_PointSize = 1.0;
    colour = diffuse.bgra;
    uv = coordinates;
    image = layer;
}

#endif

#ifdef FRAGMENT

layout(set = 2, binding = 0) uniform sampler2DArray images;

layout(set = 3, binding = 0) uniform Frame {
    // x: 1 to draw in 16-bit colour, dithered. y: 1 to magnify textures with a Catmull-Rom filter
    // rather than bilinearly. z: 1 to dither 32-bit colour as well, which costs nothing and keeps
    // a dark gradient, such as the nebula or a light's falloff, from banding.
    vec4 settings;
} frame;

layout(location = 0) in vec4 colour;
layout(location = 1) in vec2 uv;
layout(location = 2) flat in int image;
layout(location = 0) out vec4 result;

// A texture magnified with a Catmull-Rom filter, from nine bilinear taps: sharper than bilinear,
// smoother than the nearest texel.
vec4 catmullRom(vec2 at, float layer) {
    vec2 size = vec2(textureSize(images, 0).xy);
    vec2 position = at * size;
    vec2 centre = floor(position - 0.5) + 0.5;
    vec2 f = position - centre;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 t0 = (centre - 1.0) / size;
    vec2 t12 = (centre + w2 / w12) / size;
    vec2 t3 = (centre + 2.0) / size;
    vec4 sum = vec4(0.0);
    sum += textureLod(images, vec3(t0.x, t0.y, layer), 0.0) * w0.x * w0.y;
    sum += textureLod(images, vec3(t12.x, t0.y, layer), 0.0) * w12.x * w0.y;
    sum += textureLod(images, vec3(t3.x, t0.y, layer), 0.0) * w3.x * w0.y;
    sum += textureLod(images, vec3(t0.x, t12.y, layer), 0.0) * w0.x * w12.y;
    sum += textureLod(images, vec3(t12.x, t12.y, layer), 0.0) * w12.x * w12.y;
    sum += textureLod(images, vec3(t3.x, t12.y, layer), 0.0) * w3.x * w12.y;
    sum += textureLod(images, vec3(t0.x, t3.y, layer), 0.0) * w0.x * w3.y;
    sum += textureLod(images, vec3(t12.x, t3.y, layer), 0.0) * w12.x * w3.y;
    sum += textureLod(images, vec3(t3.x, t3.y, layer), 0.0) * w3.x * w3.y;
    return clamp(sum, 0.0, 1.0);
}

// The texture at the fragment: magnified as the settings say, minified by the sampler.
vec4 sampled() {
    float layer = float(image);
    if (frame.settings.y > 0.0 && textureQueryLod(images, uv).y < 0.0) return catmullRom(uv, layer);
    return texture(images, vec3(uv, layer));
}

void main() {
    // Direct3D 7's stages: the texture times the colour, or the colour alone.
    vec4 c = image < 0 ? colour : sampled() * colour;
    if (frame.settings.x > 0.0 || frame.settings.z > 0.0) {
        // Over a 4 by 4 ordered dither, to the levels the frame is kept in: five bits of red and
        // blue and six of green in 16-bit colour, eight bits a channel otherwise.
        const float bayer[16] = float[](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
        ivec2 cell = ivec2(gl_FragCoord.xy) & 3;
        float threshold = (bayer[cell.y * 4 + cell.x] + 0.5) / 16.0;
        vec3 levels = frame.settings.x > 0.0 ? vec3(31.0, 63.0, 31.0) : vec3(255.0);
        c.rgb = floor(c.rgb * levels + threshold) / levels;
    }
    result = c;
}

#endif
