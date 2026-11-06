/*
 * glass_shader.h
 *
 * Optimized GLSL shader sources for the liquid glass rendering effect.
 *
 * PERFORMANCE OPTIMIZATIONS APPLIED:
 * - mediump precision for all non-time variables (ALU bandwidth reduction)
 * - Removed dead code: hash(), smoothNoise(), fbm() (never called)
 * - Removed dead uniform: uResolution (never read in shader)
 * - pow(x,2) → x*x, pow(x,3) → x*x*x (eliminate transcendental calls)
 * - normalize(dir) → dir/d (d already computed, avoid redundant length())
 * - 3 texture fetches instead of 4 (blur approximated from chromatic spread)
 * - Fixed ripple loop (16 iterations, zero-strength sentinel skip)
 */

#ifndef GLASS_SHADER_H
#define GLASS_SHADER_H

// ---- Vertex Shader ----
const char* VERTEX_SHADER_SOURCE = R"(
#version 300 es
layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;
out vec2 vTexCoord;
void main() {
    vTexCoord = aTexCoord;
    gl_Position = vec4(aPosition, 0.0, 1.0);
}
)";

// ---- Fragment Shader ----
const char* FRAGMENT_SHADER_SOURCE = R"(
#version 300 es
precision mediump float;
precision highp float uTime;      // time accumulates; needs full precision

// Inputs
in vec2 vTexCoord;
uniform sampler2D uBackgroundTex;
uniform float uTime;
uniform vec2 uTouchPos;
uniform float uOpacity;
uniform float uBlur;
uniform float uRefraction;
uniform float uWaveSpeed;
uniform vec3 uTint;   // 主题色调：深色压暗、浅色提亮

// Ripple data (max 16 ripples, always iterated, inactive skipped via sentinel)
#define MAX_RIPPLES 16
uniform mediump vec4 uRipples[MAX_RIPPLES];

out vec4 fragColor;

// ---- Main ----
void main() {
    vec2 uv = vTexCoord;
    vec2 center = vec2(0.5, 0.5);
    float dist = distance(uv, center);

    // 1. Base wave motion (multiple sine waves)
    float wave1 = sin(uv.x * 12.0 + uv.y * 8.0 + uTime * uWaveSpeed * 1.3) * 0.015;
    float wave2 = cos(uv.y * 10.0 - uv.x * 14.0 + uTime * uWaveSpeed * 0.9) * 0.012;
    float wave3 = sin((uv.x - uv.y) * 16.0 + uTime * uWaveSpeed * 1.7) * 0.008;
    vec2 waveOffset = vec2(wave1 + wave2 * 0.6, wave2 + wave3 * 0.5);

    // 2. Touch ripple overlay (fixed 16-iteration loop, sentinel skip for inactive)
    vec2 rippleOffset = vec2(0.0);
    for (int i = 0; i < MAX_RIPPLES; i++) {
        vec4 ripple = uRipples[i];
        if (ripple.w <= 0.0) continue;  // zero-strength sentinel: skip

        vec2 dir = uv - ripple.xy;
        float d = length(dir);
        float radius = ripple.z;
        float strength = ripple.w;
        if (d < radius && d > 0.001) {
            float influence = (1.0 - d / radius) * strength;
            vec2 normal = dir / d;    // d > 0.001 guaranteed; avoids redundant length()
            rippleOffset += normal * influence * 0.06;
        }
    }

    // 3. Total offset
    vec2 totalOffset = waveOffset + rippleOffset;

    // 4. Chromatic dispersion (3 texture fetches, different wavelengths)
    float dispersion = 0.008 * uRefraction * 80.0;
    vec2 uvR = uv + totalOffset + vec2(dispersion, 0.0);
    vec2 uvG = uv + totalOffset;
    vec2 uvB = uv + totalOffset - vec2(dispersion, 0.0);

    // Edge dispersion enhancement (prism effect) — pow(x,2.0) → x*x
    float edgeFactor = (1.0 - dist * 1.2) * (1.0 - dist * 1.2);
    uvR += vec2(edgeFactor * 0.004, 0.0);
    uvB -= vec2(edgeFactor * 0.004, 0.0);

    // 5. Sample background texture with chromatic offsets (3 fetches)
    vec4 colorR = texture(uBackgroundTex, uvR);
    vec4 colorG = texture(uBackgroundTex, uvG);
    vec4 colorB = texture(uBackgroundTex, uvB);
    vec3 sharpRgb = vec3(colorR.r, colorG.g, colorB.b);

    // 6. Edge blur — approximated from chromatic samples (no 4th texture fetch)
    // The 3 chromatic samples span a small spatial region. Their RGB average
    // is a free box-filter blur approximation, eliminating the 4th texture fetch.
    vec3 blurApprox = (colorR.rgb + colorG.rgb + colorB.rgb) * 0.3333;
    float edgeBlur = (1.0 - dist * 1.5) * (1.0 - dist * 1.5) * (1.0 - dist * 1.5) * 0.5;
    vec3 bgColor = mix(sharpRgb, blurApprox, edgeBlur);

    // 7. Fresnel edge glow — pow(x,3.0) → x*x*x
    float fresnel = (1.0 - dist * 1.8) * (1.0 - dist * 1.8) * (1.0 - dist * 1.8);
    vec3 fresnelColor = vec3(0.9, 0.95, 1.0) * fresnel * 0.5;

    // 8. Dynamic highlight (follows touch position)
    vec2 lightDir = uTouchPos - uv;
    float lightDist = length(lightDir);
    float highlight = 0.0;
    if (lightDist < 0.3 && uTouchPos.x > 0.0) {
        highlight = (1.0 - lightDist / 0.3) * 0.4;
        highlight *= sin(uTime * 0.5 + uv.x * 20.0) * 0.5 + 0.5;
    }

    // 9. Combine final color
    // 先套主题色调，再叠加冷白高光与菲涅尔光。
    vec3 finalColor = bgColor.rgb * uTint;
    finalColor += fresnelColor;
    finalColor += vec3(1.0, 0.98, 0.95) * highlight;

    // 10. Apply opacity（预乘 alpha：surface 合成时不会二次衰减导致发黑）
    fragColor = vec4(finalColor * uOpacity, uOpacity);
}
)";

#endif // GLASS_SHADER_H
