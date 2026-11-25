#version 460 core

// A MilkDrop-like visual: each frame warps the previous one (zoom, rotation, wobble) and fades it, then adds a fresh
// pattern picked by uPreset. Bass, mids and treble (0..1) push the warp and the brightness.

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uTime;
uniform float uBass;
uniform float uMid;
uniform float uTreble;
uniform float uBeat;
uniform float uPreset;
uniform float uFeedback;
uniform vec3 uTint;
uniform float uSpeed;
uniform float uIntensity;
uniform float uTrail;
uniform float uWarp;
uniform sampler2D uPrev;

out vec4 fragColor;

const float PI = 3.14159265;

vec3 palette(float t, vec3 tint) {
  vec3 base = 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)));
  return mix(base, base * tint * 1.6, 0.45);
}

mat2 rot(float a) {
  float c = cos(a);
  float s = sin(a);
  return mat2(c, -s, s, c);
}

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = rot(0.5) * p * 2.02;
    a *= 0.5;
  }
  return v;
}

/// Folds the plane into [segments] mirrored wedges.
vec2 kaleido(vec2 p, float segments) {
  float r = length(p);
  float a = atan(p.y, p.x);
  float wedge = 2.0 * PI / segments;
  a = mod(a, wedge);
  a = abs(a - wedge * 0.5);
  return vec2(cos(a), sin(a)) * r;
}

vec3 plasma(vec2 p, float t) {
  float v = sin(p.x * 3.0 + t) + sin(p.y * 4.0 - t * 1.3) + sin((p.x + p.y) * 3.0 + t * 0.7);
  v += sin(length(p) * (6.0 + uBass * 8.0) - t * 2.0);
  return palette(v * 0.25 + t * 0.05, uTint) * (0.35 + uBass * 0.9);
}

vec3 kaleidoscope(vec2 p, float t) {
  vec2 q = kaleido(rot(t * 0.15) * p, 6.0);
  float rings = sin(length(q) * 14.0 - t * 3.0 + uBass * 4.0);
  float spokes = sin(q.x * 10.0 + t) * sin(q.y * 10.0 - t * 0.8);
  float v = smoothstep(0.6, 1.0, rings) + smoothstep(0.5, 1.0, spokes) * (0.4 + uMid);
  return palette(length(q) * 0.8 + t * 0.07, uTint) * v * (0.3 + uBass * 0.8);
}

vec3 tunnel(vec2 p, float t) {
  float r = max(length(p), 0.001);
  float a = atan(p.y, p.x);
  float depth = 0.35 / r + t * (0.6 + uBass * 1.5);
  float stripes = sin(a * 8.0 + depth * 6.0) * sin(depth * 10.0);
  float v = smoothstep(0.2, 1.0, stripes) * smoothstep(0.0, 0.25, r);
  return palette(depth * 0.1, uTint) * v * (0.4 + uMid * 0.9);
}

vec3 nebula(vec2 p, float t) {
  vec2 q = p * 2.0;
  float n = fbm(q + vec2(t * 0.1, -t * 0.07) + fbm(q * 1.5 - t * 0.05) * (1.0 + uBass * 2.0));
  float stars = step(0.995 - uTreble * 0.01, hash(floor(p * uSize.y * 0.25)));
  return palette(n + t * 0.03, uTint) * smoothstep(0.35, 0.9, n) * (0.4 + uBass * 0.7) + vec3(stars) * 0.6;
}

vec3 vortex(vec2 p, float t) {
  float r = length(p);
  float a = atan(p.y, p.x);
  float arms = sin(a * 5.0 + log(r + 0.001) * 6.0 - t * (1.5 + uBass * 3.0));
  float v = smoothstep(0.3, 1.0, arms) * smoothstep(1.2, 0.05, r);
  return palette(r - t * 0.1, uTint) * v * (0.35 + uBass * 0.9);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;
  float aspect = uSize.x / max(uSize.y, 1.0);
  vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
  int preset = int(uPreset + 0.5);
  float t = uTime;

  // The warp: zoom towards the centre, turn a little, wobble with the mids. Sampling inside the previous frame makes
  // everything drift outwards.
  vec2 w = p;
  float zoom = 0.985 - uBass * 0.035 - uBeat * 0.03;
  float turn = (0.004 + uMid * 0.012) * uWarp;
  if (preset == 2) {
    zoom = 0.96 - uBass * 0.04;
  } else if (preset == 4) {
    turn = (0.02 + uBass * 0.03) * uWarp;
  }
  w = rot(turn) * w * (1.0 - (1.0 - zoom) * uWarp);
  w += vec2(sin(p.y * 6.0 + t), cos(p.x * 6.0 - t * 0.9)) * 0.003 * uWarp * (1.0 + uMid * 3.0);
  if (preset == 1) {
    w = kaleido(w, 6.0);
  }
  vec2 prevUv = w / vec2(aspect, 1.0) + 0.5;
#ifdef IMPELLER_TARGET_OPENGLES
  prevUv.y = 1.0 - prevUv.y;
#endif
  vec3 prev = vec3(0.0);
  if (uFeedback > 0.5 && prevUv.x >= 0.0 && prevUv.x <= 1.0 && prevUv.y >= 0.0 && prevUv.y <= 1.0) {
    prev = texture(uPrev, prevUv).rgb;
  }
  float decay = clamp(uTrail + uMid * 0.04, 0.5, 0.985);

  vec3 fresh;
  if (preset == 0) {
    fresh = plasma(p, t);
  } else if (preset == 1) {
    fresh = kaleidoscope(p, t);
  } else if (preset == 2) {
    fresh = tunnel(p, t);
  } else if (preset == 3) {
    fresh = nebula(p, t);
  } else {
    fresh = vortex(p, t);
  }

  vec3 color = prev * decay + fresh * uIntensity * (0.18 + uBeat * 0.25);
  // Keep highlights from saturating to flat white.
  color = color / (1.0 + max(max(color.r, color.g), color.b) * 0.15);
  fragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
