// 生成带定位标记的 24bpp BMP 测试图：
//   最外 4px 边框：上=红 下=绿 左=蓝 右=黄；每 32px 一条灰色网格线，
//   每 64px 一条白色粗网格线；四角各有一个 24x24 的品红方块。
const fs = require('fs');
function gen(W, H, name) {
  const stride = (W * 3 + 3) & ~3, size = 54 + stride * H;
  const b = Buffer.alloc(size);
  b.write('BM', 0); b.writeUInt32LE(size, 2); b.writeUInt32LE(54, 10);
  b.writeUInt32LE(40, 14); b.writeInt32LE(W, 18); b.writeInt32LE(H, 22);
  b.writeUInt16LE(1, 26); b.writeUInt16LE(24, 28); b.writeUInt32LE(stride * H, 34);
  const sx = W / 640, sy = H / 480;               // 网格按 640x480 坐标缩放
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const X = x / sx, Y = y / sy;                   // 映射到输出坐标
    let r = 40, g = 40, bl = 40;
    if (Math.floor(X) % 32 === 0 || Math.floor(Y) % 32 === 0) r = g = bl = 110;
    if (Math.floor(X) % 64 < 2 || Math.floor(Y) % 64 < 2) r = g = bl = 230;
    if ((X < 24 || X >= 616) && (Y < 24 || Y >= 456)) { r = 255; g = 0; bl = 255; }
    if (Y < 4) { r = 255; g = 0; bl = 0; }          // 上 红
    else if (Y >= 476) { r = 0; g = 255; bl = 0; }  // 下 绿
    else if (X < 4) { r = 0; g = 0; bl = 255; }     // 左 蓝
    else if (X >= 636) { r = 255; g = 255; bl = 0; }// 右 黄
    const o = 54 + (H - 1 - y) * stride + x * 3;    // BMP 自下而上存储
    b[o] = bl; b[o + 1] = g; b[o + 2] = r;
  }
  fs.writeFileSync(name, b);
}
gen(640, 480, 'TEST640.BMP');
gen(1920, 1080, 'TEST1080.BMP');
