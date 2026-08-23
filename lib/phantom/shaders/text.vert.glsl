attribute vec2 aPos;
attribute vec2 aUV;
attribute vec4 aColor;
varying vec2 vUV;
varying vec4 vColor;
void main() {
    gl_Position = vec4(aPos, 0.0, 1.0);
    vUV = aUV;
    vColor = aColor;
}
