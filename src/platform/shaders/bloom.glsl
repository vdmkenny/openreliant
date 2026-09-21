// The bloom the engine draws the finished frame through, so that the game's own bright things, its
// lights, its engine glows, its flares and the sun, bleed a little light into what stands around
// them, as a camera does. The original drew none: `--original` turns it off and the frame goes
// straight to the screen instead.
//
// One shader for all three passes, which `frame.settings.x` picks. `make shaders` compiles the
// vertex stage, with VERTEX defined, and the fragment stage, with FRAGMENT, as it does the device's.
#version 450

#ifdef VERTEX

layout(location = 0) out vec2 uv;

void main() {
    // One triangle over the whole screen, from the vertex's number alone: no buffer to bind.
    vec2 corner = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    // The frame's first row is its top, where the clip space's top is +1.
    uv = vec2(corner.x, 1.0 - corner.y);
}

#endif

#ifdef FRAGMENT

/// What the pass reads: the frame for the first, what the pass before left for the others.
layout(set = 2, binding = 0) uniform sampler2D source;
/// The frame itself, which only the last pass adds the bloom back onto.
layout(set = 2, binding = 1) uniform sampler2D frame_image;

layout(set = 3, binding = 0) uniform Frame {
    // x: which pass, 0 to take the bright parts, 1 to blur, 2 to add the bloom back. yz: one texel
    // of the image being read, along the axis a blur runs. w: the brightness a colour must pass to
    // bloom, and, in the last pass, how much of the bloom is added.
    vec4 settings;
} frame;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 result;

void main() {
    int pass = int(frame.settings.x);
    vec2 texel = frame.settings.yz;
    if (pass == 0) {
        // Only what stands above the threshold blooms, so that an ordinary lit hull does not.
        vec3 colour = texture(source, uv).rgb;
        result = vec4(max(colour - vec3(frame.settings.w), vec3(0.0)), 1.0);
    } else if (pass == 1) {
        // Nine taps along one axis, weighted as a Gaussian; the two passes together blur both.
        const float weights[5] = float[](0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216);
        vec3 colour = texture(source, uv).rgb * weights[0];
        for (int tap = 1; tap < 5; tap++) {
            vec2 along = texel * float(tap);
            colour += texture(source, uv + along).rgb * weights[tap];
            colour += texture(source, uv - along).rgb * weights[tap];
        }
        result = vec4(colour, 1.0);
    } else {
        result = vec4(texture(frame_image, uv).rgb + texture(source, uv).rgb * frame.settings.w, 1.0);
    }
}

#endif
