// Ring vertex shader — 1 draw call for all 7 HudStates.
// Uniforms are state-driven; see STATE_PARAMS in stateUniforms.ts.

uniform float uTime;
uniform float uPulseSpeed;
uniform float uRotateSpeed;
uniform float uStateIdx;
uniform float uStateBlend;       // 0..1, 1 = fully at uStateIdx
uniform float uPrevStateIdx;
uniform float uReduceMotion;     // 1 = disable all motion
uniform float uOutwardWaveAmp;   // non-zero only for `speaking`

attribute float aRadius;
attribute float aTheta;

varying float vAlpha;

void main() {
  float theta = aTheta + uTime * uRotateSpeed;
  float pulse = sin(uTime * uPulseSpeed * 6.2831) * 0.05 * (1.0 - uReduceMotion);
  float wave = uOutwardWaveAmp * sin(uTime * 2.0 + aTheta * 3.0) * (1.0 - uReduceMotion);
  float r = aRadius + pulse + wave;

  vec3 pos = vec3(cos(theta) * r, sin(theta) * r, 0.0);
  vec4 mvPosition = modelViewMatrix * vec4(pos, 1.0);
  gl_Position = projectionMatrix * mvPosition;
  gl_PointSize = 4.0 * (300.0 / -mvPosition.z);
  vAlpha = 0.85;
}
