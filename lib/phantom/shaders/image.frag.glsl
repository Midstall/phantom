precision mediump float;
uniform sampler2D uTex;
varying vec2 vUV;
varying vec4 vColor;
void main() {
    vec4 t = texture2D(uTex, vUV);
    gl_FragColor = vec4(t.rgb, t.a * vColor.a);
}
