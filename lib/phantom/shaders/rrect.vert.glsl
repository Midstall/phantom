attribute vec2 aPos;
attribute vec2 aLocal;
attribute vec4 aParams;
attribute vec4 aColor;
varying vec2 vLocal;
varying vec4 vParams;
varying vec4 vColor;
void main() {
    gl_Position = vec4(aPos, 0.0, 1.0);
    vLocal = aLocal;
    vParams = aParams;
    vColor = aColor;
}
