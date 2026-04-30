// Ring fragment shader — radial color gradient core for arc-reactor bloom.
//
// Each particle is rendered as a soft point sprite with a smoothstep alpha
// falloff. The output color is a radial gradient: bright white at the
// center, cyan-shifted in the inner ring, falling off into the configured
// `uColorGlow` at the outer edge. Stack multiple `<RingMesh>` layers with
// `THREE.AdditiveBlending` and the bright cores naturally bloom — no
// post-processing pass required.

uniform vec3 uColorGlow;
uniform float uIntensity;     // layer-specific brightness multiplier (0..1+)
uniform float uCoreBoost;     // 0..1; how much the inner-ring layer pushes white

varying float vAlpha;

void main() {
  // Distance from the point sprite's center, in [0, 0.5].
  vec2 uv = gl_PointCoord - vec2(0.5);
  float d = length(uv);

  // Soft circular alpha — small inner plateau then smoothstep falloff.
  float alpha = smoothstep(0.5, 0.18, d) * vAlpha;

  // Radial color: bright cyan-white center, falling off into uColorGlow.
  // `uCoreBoost` lifts the center toward pure white for inner-ring layers
  // (arc-reactor core feel) without losing the tinted halo.
  vec3 hot = vec3(0.92, 1.0, 1.0);
  vec3 mid = mix(uColorGlow, hot, 0.55);
  float coreT = smoothstep(0.5, 0.0, d);                        // 1 at center
  vec3 col = mix(uColorGlow, mid, coreT);
  col = mix(col, hot, coreT * uCoreBoost);

  gl_FragColor = vec4(col * max(uIntensity, 0.001), alpha);
}
