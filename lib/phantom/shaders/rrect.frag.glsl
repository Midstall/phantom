precision mediump float;
varying vec2 vLocal;
varying vec4 vParams;
varying vec4 vColor;
float sdRoundedBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}
void main() {
    float d = sdRoundedBox(vLocal, vParams.xy, vParams.z);
    float sw = vParams.w;
    float cov;
    if (sw > 0.0) {
        // inside stroke: a ring occupying the SDF band d in [-sw, 0], so the
        // border sits INSIDE the box bounds (matches DOM box-sizing:border-box).
        cov = clamp(0.5 - (abs(d + sw * 0.5) - sw * 0.5), 0.0, 1.0);
    } else {
        cov = clamp(0.5 - d, 0.0, 1.0);
    }
    gl_FragColor = vec4(vColor.rgb, vColor.a * cov);
}
