import AppKit

/// 菜单栏内容直接画成一张小图，而不是挂一个 SwiftUI 视图：
/// 常驻部分零 SwiftUI 开销；内容没变时连图都不重画。
/// 三种样式见 docs/design/menu.html；平时是单色模板图，超过 85° 才上色。
@MainActor
final class StatusBarRenderer {
    private weak var button: NSStatusBarButton?
    private var lastKey = ""

    init(button: NSStatusBarButton) {
        self.button = button
        button.imagePosition = .imageOnly
    }

    func invalidate() { lastKey = "" }

    func render(_ monitor: Monitor) {
        let s = monitor.snapshot
        let style = Prefs.style
        let temp = s.thermal.cpuAvg
        let hot = (temp ?? 0) >= Theme.alertTemp

        let glyph = BarGlyph(
            style: style,
            cpuTicks: Int((s.cpu.total * 20).rounded()),
            cpu: s.cpu.total,
            mem: s.mem.usedFraction,
            pulse: style == .pulse ? monitor.cpuHistory.values(last: 20, maxPoints: 10).map { ($0 * 20).rounded() / 20 } : [],
            text: style == .orbit ? nil : {
                switch Prefs.text {
                case .temp: return Fmt.temp(temp)
                case .cpu: return Fmt.percent(s.cpu.total)
                case .mem: return Fmt.percent(s.mem.usedFraction)
                case .none: return nil
                }
            }(),
            hot: hot
        )

        let key = glyph.key
        guard key != lastKey, let button else { return }
        lastKey = key
        button.image = glyph.image()
        button.setAccessibilityLabel("Lucent：CPU \(Fmt.percent(s.cpu.total))，温度 \(Fmt.temp(temp))，内存 \(Fmt.percent(s.mem.usedFraction))")
    }
}

struct BarGlyph {
    var style: BarStyle
    var cpuTicks: Int
    var cpu: Double
    var mem: Double
    var pulse: [Double]
    var text: String?
    var hot: Bool

    var key: String {
        switch style {
        case .ring: return "r\(cpuTicks)|\(text ?? "")|\(hot)"
        case .pulse: return "p\(pulse)|\(text ?? "")|\(hot)"
        case .orbit: return "o\(Int(cpu * 40))|\(Int(mem * 40))|\(hot)"
        }
    }

    private static let height: CGFloat = 22
    private static let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let gap: CGFloat = 6

    /// 过热色：深色顶部栏用亮橙，浅色顶部栏用深橙（设计稿两种底色的对照）
    private static let heatColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? Theme.nsHeat : Theme.nsHeatOnLight
    }

    func image() -> NSImage {
        let glyphW: CGFloat = style == .pulse ? 22 : 16
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .kern: 0.2]
        // 用固定宽度的占位串，数字变化时图标不左右跳
        let textW = text == nil ? 0 : ceil(("100°" as NSString).size(withAttributes: attrs).width)
        let width = glyphW + (text == nil ? 0 : Self.gap + textW)

        let img = NSImage(size: NSSize(width: width, height: Self.height), flipped: true) { _ in
            let color: NSColor = hot ? Self.heatColor : .black
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.translateBy(x: 0, y: (Self.height - 16) / 2)
            drawGlyph(ctx, color)
            ctx.restoreGState()

            if let text {
                var a = attrs
                a[.foregroundColor] = color
                let size = (text as NSString).size(withAttributes: a)
                (text as NSString).draw(at: NSPoint(x: glyphW + Self.gap, y: (Self.height - size.height) / 2), withAttributes: a)
            }
            return true
        }
        // 不过热时是模板图：系统自动适配浅色/深色/高亮顶部栏
        img.isTemplate = !hot
        return img
    }

    private func drawGlyph(_ ctx: CGContext, _ color: NSColor) {
        ctx.setLineCap(.round)
        switch style {
        case .ring:
            // 20 道刻度，每道 5% CPU，顺时针点亮；中心点
            for k in 0..<20 {
                let a = -Double.pi / 2 + Double(k) * 2 * .pi / 20
                ctx.move(to: CGPoint(x: 8 + 4.6 * cos(a), y: 8 + 4.6 * sin(a)))
                ctx.addLine(to: CGPoint(x: 8 + 7.2 * cos(a), y: 8 + 7.2 * sin(a)))
                let on = k < cpuTicks
                ctx.setStrokeColor(color.withAlphaComponent(on ? 1 : 0.3).cgColor)
                ctx.setLineWidth(on ? 1.3 : 1.1)
                ctx.strokePath()
            }
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: 6.5, y: 6.5, width: 3, height: 3))

        case .pulse:
            // 迷你脉冲线：几条细线围绕一条主线，随 CPU 起伏
            let data = pulse.count >= 2 ? pulse : [0, 0]
            let m = data.count
            func line(_ jit: Double, _ ph: Double, _ fr: Double) -> CGPath {
                let pts = (0..<m).map { j -> CGPoint in
                    let v = data[j], env = 0.3 + v * 1.2
                    return CGPoint(x: Double(j) * 22 / Double(m - 1),
                                   y: 13 - (v * 10 + jit * env + sin(ph + Double(j) * fr) * 1.6 * 0.45 * env))
                }
                return smoothPath(pts).cgPath
            }
            var rng = SeededRNG(5)
            ctx.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(0.6)
            for _ in 0..<4 {
                ctx.addPath(line((rng.next() - 0.5) * 2 * 1.6, rng.next() * 6.28, 0.4 + rng.next() * 0.9))
            }
            ctx.strokePath()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.3)
            ctx.addPath(line(0, 0, 0))
            ctx.strokePath()

        case .orbit:
            // 外圈 CPU，内圈内存
            for r in [6.4, 3.4] {
                ctx.setStrokeColor(color.withAlphaComponent(0.22).cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: CGRect(x: 8 - r, y: 8 - r, width: r * 2, height: r * 2))
            }
            for (r, f) in [(6.4, cpu), (3.4, mem)] where f > 0.005 {
                ctx.addArc(center: CGPoint(x: 8, y: 8), radius: r, startAngle: -.pi / 2,
                           endAngle: -.pi / 2 + min(f, 1) * 2 * .pi, clockwise: false)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(1.6)
                ctx.strokePath()
            }
        }
    }
}
