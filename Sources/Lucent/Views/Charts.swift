import SwiftUI

// 设计稿里的图表都是 SVG + 动画；这里用 Canvas 单次绘制、不加动画，
// 数据每秒刷新一次本身就让图“活”起来，关窗即停。

/// 与设计稿 JS 相同的线性同余随机数，保证每次绘制形状稳定
struct SeededRNG {
    private var s: UInt32
    init(_ seed: UInt32) { s = seed }
    mutating func next() -> Double {
        s = s &* 1_664_525 &+ 1_013_904_223
        return Double(s) / 4_294_967_296
    }
}

/// Catmull-Rom → 三次贝塞尔，和设计稿 curve() 一致
func smoothPath(_ pts: [CGPoint]) -> Path {
    var p = Path()
    guard let first = pts.first else { return p }
    p.move(to: first)
    guard pts.count > 1 else { return p }
    for i in 0..<(pts.count - 1) {
        let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
        p.addCurve(
            to: p2,
            control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
            control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        )
    }
    return p
}

// MARK: - 丝线折线图

/// 一组“丝线”：围绕真实数据的几条抖动曲线，叠加辉光
struct ThreadLayer {
    var data: [Double]               // 0...1
    var base: CGFloat                // 0 值所在的 y（自顶向下）
    var amp: CGFloat                 // 1.0 对应的高度
    var dir: CGFloat = 1             // -1 表示向下画（上传）
    var spread: CGFloat
    var seed: UInt32
    var energy: Double = 0.5         // 0...1，状态激烈程度：决定丝线抖动幅度
    var strokes: [(Color, CGFloat)]  // 每条线的颜色和线宽，第一条最贴近真实数据
    var markers: Markers = .ring

    enum Markers { case ring, dot, none }

    func paths(width w: CGFloat) -> [Path] {
        let m = data.count
        guard m >= 2 else { return [] }
        var r = SeededRNG(seed)
        return strokes.indices.map { k in
            let jit = (r.next() - 0.5) * spread * (k == 0 ? 0.3 : 1.4)
            let ph = r.next() * 6.28
            let fr = 0.45 + r.next() * 0.35
            let wob = spread * (0.6 + r.next() * 0.5)
            _ = r.next() // 设计稿的 rot，占位保持随机序列一致
            let pts = (0..<m).map { j -> CGPoint in
                let u = Double(j) / Double(m - 1)
                let v = data[j], env = 0.3 + v * 1.2
                let y = base - dir * (CGFloat(v) * amp + CGFloat(jit * env + sin(ph + Double(j) * fr) * wob * env) * CGFloat(sin(.pi * u)))
                return CGPoint(x: CGFloat(u) * w, y: y)
            }
            return smoothPath(pts)
        }
    }

    func point(_ i: Int, width w: CGFloat) -> CGPoint {
        let v = data[i]
        return CGPoint(x: CGFloat(i) / CGFloat(max(data.count - 1, 1)) * w, y: base - dir * CGFloat(v) * amp)
    }
}

struct ThreadChart: View {
    var layers: [ThreadLayer]
    var baseline: CGFloat? = nil                 // 一条淡淡的水平基线
    var alert: (y: CGFloat, label: String)? = nil  // 告警虚线
    var glow: CGFloat = 3.2
    var period: Double = 5.2                     // 丝线起伏一个周期的秒数（设计稿 4.6~5.6）

    var body: some View {
        ZStack {
            // 静态部分：基线和告警虚线
            Canvas { ctx, size in
                if let y = baseline {
                    var p = Path(); p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y))
                    ctx.stroke(p, with: .color(.white.opacity(0.14)), lineWidth: 0.6)
                }
                if let a = alert {
                    var p = Path(); p.move(to: .init(x: 0, y: a.y)); p.addLine(to: .init(x: size.width, y: a.y))
                    ctx.stroke(p, with: .color(Theme.heat.opacity(0.5)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 4]))
                    ctx.draw(Text(a.label).font(Theme.mono(9.5)).tracking(1).foregroundStyle(Theme.tertiary),
                             at: .init(x: size.width, y: a.y - 8), anchor: .trailing)
                }
            }
            // 丝线、辉光、端点：Core Animation（见 Motion.swift）
            ThreadsView(layers: layers, glow: glow, period: period)
        }
    }
}

// MARK: - 内存环

/// 分段丝线环 + 外圈刻度（已用部分的扫光高光在 Motion.swift 的 RingSweep）
struct MemoryRing: View {
    struct Segment { var from: Double; var to: Double; var weight: Double }
    var segments: [Segment]       // 0...1，顺时针从 12 点开始
    var radius: CGFloat           // 设计稿 r
    var thick: CGFloat
    var threads = 34
    var seed: UInt32 = 7

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            // 手动取点画弧：从 12 点顺时针，从 f0 到 f1（避免 addArc 在翻转坐标系里的方向歧义）
            func arc(_ r: CGFloat, _ f0: Double, _ f1: Double) -> Path {
                var p = Path()
                let steps = max(Int((f1 - f0) * 180), 1)
                for i in 0...steps {
                    let a = -Double.pi / 2 + (f0 + (f1 - f0) * Double(i) / Double(steps)) * 2 * .pi
                    let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                return p
            }

            // 底环
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                       with: .color(.white.opacity(0.05)), lineWidth: thick)

            // 外圈 60 道刻度，每 5 道一长
            var ticks = Path()
            for k in 0..<60 {
                let a = -Double.pi / 2 + Double(k) * .pi / 30
                let r1 = radius + thick / 2 + 5, r2 = r1 + (k % 5 == 0 ? 5 : 2.5)
                ticks.move(to: CGPoint(x: c.x + r1 * cos(a), y: c.y + r1 * sin(a)))
                ticks.addLine(to: CGPoint(x: c.x + r2 * cos(a), y: c.y + r2 * sin(a)))
            }
            ctx.stroke(ticks, with: .color(.white.opacity(0.32)), lineWidth: 0.8)

            // 丝线分段（与设计稿 ring() 相同的分组规则）
            var rng = SeededRNG(seed)
            var faint = Path(), mid = Path(), bright = Path()
            for sg in segments where sg.to > sg.from {
                for _ in 0..<threads {
                    let rad = radius + CGFloat(rng.next() - 0.5) * thick
                    // 两端参差：每根丝线起止点各自错开（最多约 ±10°），不再像刀切一样齐
                    let s = sg.from - 0.006 + rng.next() * 0.03
                    let e = sg.to + 0.008 - rng.next() * rng.next() * 0.06
                    let p = rng.next()
                    let a = arc(rad, s, max(e, s))
                    if sg.weight >= 1 {
                        if p < 0.18 { bright.addPath(a) } else if p < 0.55 { mid.addPath(a) } else { faint.addPath(a) }
                    } else if sg.weight >= 0.6 {
                        if p < 0.06 { bright.addPath(a) } else if p < 0.4 { mid.addPath(a) } else { faint.addPath(a) }
                    } else {
                        if p < 0.2 { mid.addPath(a) } else { faint.addPath(a) }
                    }
                }
            }
            ctx.stroke(faint, with: .color(Theme.accent.opacity(0.16)), lineWidth: 0.5)
            ctx.stroke(mid, with: .color(Theme.accent.opacity(0.28)), lineWidth: 0.6)
            ctx.stroke(bright, with: .color(Theme.accent.opacity(0.32)), lineWidth: 0.7)

        }
    }
}

// MARK: - 点阵

/// 一列 3×rows 的点阵，从底部按负载点亮（主窗口每核占用）
struct CoreColumn: View {
    var load: Double
    var label: String
    var isP: Bool
    var index: Int
    var rows = 14

    var body: some View {
        VStack(spacing: 8) {
            // 水位按负载连续变化（不再取整到行），刷新时平滑升降
            CoreColumnDots(spec: .init(rows: rows, level: min(max(load, 0), 1), isP: isP, seed: UInt32(99 + index)))
                .frame(width: 20, height: CGFloat(rows) * 7.5 - 2.5)
            Text(label)
                .font(Theme.mono(9.5))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// 一排 10 个点，温度每 10° 亮一颗
struct DotMeter: View {
    var fraction: Double
    var count = 10
    var seed: UInt32 = 1

    var body: some View {
        let lit = Int((fraction * Double(count)).rounded())
        let states: [Twinkle] = (0..<count).map { $0 < lit ? .on : .off }
        DotGrid(spec: .init(cols: count, rows: 1, states: states,
                            staticOpacity: states.map { $0 == .off ? 0.1 : 0.9 }, seed: seed))
            .frame(width: CGFloat(count) * 7.5 - 2.5, height: 5)
    }
}

// MARK: - 数据归一化

enum Norm {
    /// 温度画到 25°~100° 的区间
    static func temp(_ v: [Double]) -> [Double] { v.map { min(max(($0 - 25) / 75, 0), 1) } }

    /// 网速用两条线共同的最大值归一化，避免夸大
    static func rates(_ down: [Double], _ up: [Double]) -> ([Double], [Double]) {
        let top = max(down.max() ?? 0, up.max() ?? 0, 50_000) * 1.15
        return (down.map { $0 / top }, up.map { $0 / top })
    }

    /// 至少两个点，图才画得出来
    static func padded(_ v: [Double]) -> [Double] {
        switch v.count {
        case 0: return [0, 0]
        case 1: return [v[0], v[0]]
        default: return v
        }
    }
}
