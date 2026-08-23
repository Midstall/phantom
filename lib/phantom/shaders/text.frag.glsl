precision mediump float;
uniform sampler2D uAtlas;
varying vec2 vUV;
varying vec4 vColor;
void main() {
    float a = texture2D(uAtlas, vUV).a;
    gl_FragColor = vec4(vColor.rgb, vColor.a * a);
}
