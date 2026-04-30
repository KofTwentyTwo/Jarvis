// Ring vertex shader — 1 material, all 7 HudStates, layered by per-instance
// uniforms (uPhase / uRadiusScale / uPointSize / uIntensity / uCoreBoost).
// Stack 4+ <RingMesh> layers with additive blending for an arc-reactor feel.

uniform float uTime;
uniform float uPulseSpeed;
uniform float uRotateSpeed;
uniform float uStateIdx;
uniform float uStateBlend;       // 0..1, 1 = fully at uStateIdx
uniform float uPrevStateIdx;
uniform float uReduceMotion;     // 1 = disable all motion
uniform float uOutwardWaveAmp;   // non-zero only for `speaking`

uniform float uPhase;            // per-layer rotation offset (radians)
uniform float uRadiusScale;      // per-layer radius multiplier
uniform float uPointSize;        // per-layer base point size in pixels @ z=3

attribute float aRadius;
attribute float aTheta;

varying float vAlpha;

void main() {
  // Per-layer phase + state-driven rotation.
  float theta = aTheta + uPhase + uTime * uRotateSpeed;

  // Subtle radial pulse + larger outward wave on `speaking`.
  float pulse = sin(uTime * uPulseSpeed * 6.2831) * 0.04 * (1.0 - uReduceMotion);
  float wave = uOutwardWaveAmp * sin(uTime * 2.0 + aTheta * 3.0) * (1.0 - uReduceMotion);
  float r = (aRadius + pulse + wave) * uRadiusScale;

  vec3 pos = vec3(cos(theta) * r, sin(theta) * r, 0.0);
  vec4 mvPosition = modelViewMatrix * vec4(pos, 1.0);
  gl_Position = projectionMatrix * mvPosition;

  // Use uPointSize directly as the on-screen pixel size. The perspective
  // multiplier (`300 / -z`) blew past the ~63-px GPU clamp on macOS Metal,
  // so all layers ended up at the same clamped size and the stack looked
  // like one ring. Direct mode keeps per-layer differentiation.
  gl_PointSize = uPointSize;

  // Slight per-particle alpha jitter so dense rings don't look uniform.
  vAlpha = 0.78 + 0.22 * fract(sin(aTheta * 12.9898 + uPhase) * 43758.5453);
}
