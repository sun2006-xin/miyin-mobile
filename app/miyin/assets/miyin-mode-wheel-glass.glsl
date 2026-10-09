#ifdef GL_ES
precision mediump float;
#endif

/** @resolution */
uniform vec2 u_resolution;
/** @time */
uniform float u_time;
/** @sdf */
uniform sampler2D u_sdf;
/** @backdrop */
uniform sampler2D u_backdrop;

void main() {
  vec2 uv = gl_FragCoord.xy / max(u_resolution, vec2(1.0));
  vec2 sampleUv = clamp(uv, vec2(0.001), vec2(0.999));
  float signedDistance = (texture2D(u_sdf, sampleUv).r - 0.5) * 36.0;
  float shapeMask = smoothstep(-1.0, 1.0, signedDistance);
  vec3 backdrop = texture2D(u_backdrop, sampleUv).rgb;
  float sweep = mod(u_time * 0.22, 1.7) - 0.35;
  float diagonal = uv.x + uv.y * 0.42;
  float shine = 1.0 - smoothstep(0.0, 0.11, abs(diagonal - sweep));
  shine *= smoothstep(0.08, 0.28, uv.y) * (1.0 - smoothstep(0.72, 0.94, uv.y));
  float edge = 1.0 - smoothstep(0.0, 2.5, abs(signedDistance));
  vec3 glass = mix(backdrop, vec3(0.985, 0.99, 0.995), 0.38);
  glass = mix(glass, vec3(1.0), shine * 0.55 + edge * 0.12);
  float alpha = shapeMask * (0.46 + shine * 0.24 + edge * 0.10);
  gl_FragColor = vec4(glass, alpha);
}
