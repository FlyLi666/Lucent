// 生成 Lucent 的程序图标：swift scripts/make-icon.swift <输出.png>
// 1024×1024，按 macOS 图标网格画满 824×824 的圆角方块（系统就不会再套一层灰底）。
// 造型取自顶部栏「刻度环」：深色玻璃底，一圈刻度（亮起的部分 = CPU），环里几根暖色丝线（温度曲线）。
// 改完重新跑 scripts/make-icon.sh 生成 Resources/AppIcon.icns。

import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
let center = CGPoint(x: 512, y: 512)

// 底：石墨色竖向渐变，外加轻微投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0, 0, 0, 0.45))
ctx.addPath(shape)
ctx.setFillColor(color(0.09, 0.09, 0.1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0.21, 0.21, 0.235), color(0.075, 0.075, 0.085)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// 中心一团很淡的暖光，像屏幕里透出来的温度
let glow = CGGradient(colorsSpace: cs, colors: [color(1, 0.62, 0.31, 0.22), color(1, 0.62, 0.31, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 330, options: [])

// 玻璃高光：上半部一层白色渐隐
let sheen = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.13), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// 刻度环：48 根，从 12 点顺时针亮 34 根
let ticks = 48, lit = 34
ctx.setLineCap(.round)
for i in 0..<ticks {
    let a = .pi / 2 - Double(i) / Double(ticks) * 2 * .pi
    let r0 = 268.0, r1 = i % 4 == 0 ? 322.0 : 308.0
    let p0 = CGPoint(x: 512 + cos(a) * r0, y: 512 + sin(a) * r0)
    let p1 = CGPoint(x: 512 + cos(a) * r1, y: 512 + sin(a) * r1)
    ctx.saveGState()
    if i < lit {
        ctx.setShadow(offset: .zero, blur: 14, color: color(1, 1, 1, 0.55))
        ctx.setStrokeColor(color(0.97, 0.97, 0.98, 0.95))
    } else {
        ctx.setStrokeColor(color(1, 1, 1, 0.16))
    }
    ctx.setLineWidth(i % 4 == 0 ? 14 : 10)
    ctx.move(to: p0)
    ctx.addLine(to: p1)
    ctx.strokePath()
    ctx.restoreGState()
}

// 丝线：几根围绕同一条起伏的曲线，两端收拢，暖橙到白
func thread(_ phase: Double, _ amp: Double, _ jitter: Double) -> CGPath {
    let p = CGMutablePath()
    let x0 = 330.0, x1 = 694.0
    for j in 0...80 {
        let u = Double(j) / 80
        let x = x0 + (x1 - x0) * u
        let env = sin(.pi * u)
        let y = 500 + env * (amp * sin(u * 2 * .pi * 1.25 + phase) + jitter * sin(u * 9 + phase * 2)) + 40 * (u - 0.5)
        j == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    return p
}
let strands: [(Double, Double, Double, Double, Double)] = [
    (0.0, 78, 6, 9, 1.0), (0.5, 64, 10, 6, 0.7), (-0.6, 88, 8, 6, 0.6), (1.1, 52, 12, 5, 0.5),
]
for (phase, amp, jit, width, alpha) in strands {
    let path = thread(phase, amp, jit)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let warm = CGGradient(colorsSpace: cs, colors: [color(1, 0.62, 0.31, alpha), color(1, 0.86, 0.72, alpha),
                                                     color(1, 0.62, 0.31, alpha)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(warm, start: CGPoint(x: 330, y: 0), end: CGPoint(x: 694, y: 0), options: [])
    ctx.restoreGState()
    // 辉光
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: color(1, 0.6, 0.3, 0.5 * alpha))
    ctx.addPath(path)
    ctx.setLineWidth(width * 0.5)
    ctx.setStrokeColor(color(1, 0.7, 0.45, 0.35 * alpha))
    ctx.strokePath()
    ctx.restoreGState()
}

// 丝线两端的发光点
for x in [330.0, 694.0] {
    let y = 500 + 40 * ((x - 330) / 364 - 0.5)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: color(1, 1, 1, 0.8))
    ctx.setFillColor(color(1, 1, 1))
    ctx.fillEllipse(in: CGRect(x: x - 13, y: y - 13, width: 26, height: 26))
    ctx.restoreGState()
}

// 边缘一圈细高光
ctx.addPath(shape)
ctx.setStrokeColor(color(1, 1, 1, 0.16))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("✓ \(out)")
