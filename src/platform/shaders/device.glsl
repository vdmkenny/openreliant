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
// For lighting each pixel: where it stands in the camera's frame, its normal there, and the lights
// that don't reach it, all ones for none.
layout(location = 4) in vec3 view;
layout(location = 5) in vec3 normal;
layout(location = 6) in uint lightMask;
// The shadows its pixels take: 0 none, 1 the world's (device.zig's Receives).
layout(location = 7) in uint receives;

layout(set = 1, binding = 0) uniform Target {
    // The frame's width and height in pixels.
    vec2 size;
} target;

layout(location = 0) out vec4 colour;
layout(location = 1) out vec2 uv;
layout(location = 2) flat out int image;
layout(location = 3) out vec3 place;
layout(location = 4) out vec3 facing;
layout(location = 5) flat out uint mask;
layout(location = 6) flat out uint shade;

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
    place = view;
    facing = normal;
    mask = lightMask;
    shade = receives;
}

#endif

#ifdef FRAGMENT

layout(set = 2, binding = 0) uniform sampler2DArray images;
// The shadows' maps, a layer for each cascade, compared with a pixel's depth (gpu/shadows.zig).
layout(set = 2, binding = 1) uniform sampler2DArrayShadow shadowMaps;

layout(set = 3, binding = 0) uniform Frame {
    // x: 1 to draw in 16-bit colour, dithered. y: 1 to magnify textures with a Catmull-Rom filter
    // rather than bilinearly. z: 1 to dither 32-bit colour as well, which costs nothing and keeps
    // a dark gradient, such as the nebula or a light's falloff, from banding.
    vec4 settings;
} frame;

// The frame's directional and point lights, for lighting each pixel. A light's colour is its red,
// green and blue; its vector, toward a directional light and as long as its intensity, or a point
// light's place and its reach; its mask; its kind, 0 directional or 1 point; and whether a caster
// shades what it lights.
struct Light {
    vec4 colour;
    vec4 vector;
    uint mask;
    uint kind;
    uint shadowed;
    uint unused;
};

layout(set = 3, binding = 1) uniform Lighting {
    uvec4 count;
    Light lights[64];
} lighting;

layout(location = 0) in vec4 colour;
layout(location = 1) in vec2 uv;
layout(location = 2) flat in int image;
layout(location = 3) in vec3 place;
layout(location = 4) in vec3 facing;
layout(location = 5) flat in uint mask;
layout(location = 6) flat in uint shade;
layout(location = 0) out vec4 result;

// A cascade of the shadows (srshadow.zig): where a point of the camera's frame falls in its map,
// each row dotted with the point and 1, across and up from -1 to 1 and its depth from the sun's
// side from 0 to 1; the view depth it reaches to; and a texel's width in the world.
struct Cascade {
    vec4 rows[3];
    vec4 extent;
};

const int cascadeCount = 4;

layout(set = 3, binding = 2) uniform Shadows {
    Cascade cascades[cascadeCount];
    // x: 1 where the frame has shadows. y: one over the maps' texels across. z: 1 to look them up
    // in sixteen taps rather than four.
    vec4 settings;
} shadows;

// How many texels a pixel's place is moved off its surface, along its normal, before its shadow
// is looked up, so that a surface does not shade itself.
const float normalOffset = 1.5;

// How much of the sun reaches the pixel, from 0 in shadow to 1: looked up in the first cascade
// that reaches as deep as it stands, from a square of taps around it, two or four across, each
// comparing the four texels around it. Outside the maps it is lit, and it fades to lit toward the
// last cascade's end.
float sunlit(vec3 n) {
    for (int i = 0; i < cascadeCount; i++) {
        Cascade cascade = shadows.cascades[i];
        if (place.z > cascade.extent.x) continue;
        vec4 p = vec4(place + n * (cascade.extent.y * normalOffset), 1.0);
        vec3 at = vec3(dot(cascade.rows[0], p), dot(cascade.rows[1], p), dot(cascade.rows[2], p));
        if (any(greaterThan(abs(at.xy), vec2(1.0)))) return 1.0;
        vec2 uv = vec2(at.x, -at.y) * 0.5 + 0.5;
        int across = shadows.settings.z > 0.0 ? 4 : 2;
        float middle = float(across - 1) * 0.5;
        float sum = 0.0;
        for (int y = 0; y < across; y++) {
            for (int x = 0; x < across; x++) {
                vec2 offset = (vec2(x, y) - middle) * shadows.settings.y;
                sum += texture(shadowMaps, vec4(uv + offset, float(i), at.z));
            }
        }
        float lit = sum / float(across * across);
        if (i == cascadeCount - 1) lit = mix(lit, 1.0, smoothstep(cascade.extent.x * 0.8, cascade.extent.x, place.z));
        return lit;
    }
    return 1.0;
}

// The vertices' colour with the directional and point lights added for this pixel, as the
// pipeline adds them for each vertex (srmesh.zig), each channel then held to 1. A vertex that comes
// lit already, as every one does in the original's look, takes its colour as it stands. A shadowed
// light is scaled by how much of the sun reaches the pixel, looked up once, and only where such a
// light faces it.
vec4 lit(vec4 base) {
    float length = length(facing);
    if (mask == 0xFFFFFFFFu || length < 1e-6) return base;
    vec3 n = facing / length;
    vec3 sum = base.rgb;
    bool shaded = shade == 1u && shadows.settings.x > 0.0;
    float sun = -1.0;
    for (uint i = 0u; i < lighting.count.x; i++) {
        Light light = lighting.lights[i];
        if ((light.mask & mask) != 0u) continue;
        if (light.kind == 0u) {
            float amount = dot(n, light.vector.xyz);
            if (amount <= 0.0) continue;
            if (shaded && light.shadowed != 0u) {
                if (sun < 0.0) sun = sunlit(n);
                amount *= sun;
            }
            sum += amount * light.colour.rgb;
            continue;
        }
        vec3 d = light.vector.xyz - place;
        float r2 = dot(d, d);
        float reach = light.vector.w;
        if (r2 >= reach * reach) continue;
        float along = dot(d, n);
        if (along <= 0.0) continue;
        float r = sqrt(r2);
        // (1 - r / reach)^2 times the cosine, as the pipeline works it out.
        sum += (1.0 / r + r / (reach * reach) - 2.0 / reach) * along * light.colour.rgb;
    }
    return vec4(min(sum, vec3(1.0)), base.a);
}

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
    vec4 shaded = lit(colour);
    vec4 c = image < 0 ? shaded : sampled() * shaded;
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
