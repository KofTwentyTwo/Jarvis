// Ring fragment shader — circular point sprite tinted by uColorGlow.

uniform vec3 uColorGlow;

varying float vAlpha;

void main() {
  vec2 uv = gl_PointCoord - vec2(0.5);
  float d = length(uv);
  float alpha = smoothstep(0.5, 0.2, d) * vAlpha;
  gl_FragColor = vec4(uColorGlow, alpha);
}
