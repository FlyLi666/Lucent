import AppKit
import SwiftUI

/// 设计稿（docs/design/*.html）里的颜色、字体和卡片样式。
enum Theme {
    static let text = Color(red: 242 / 255, green: 242 / 255, blue: 244 / 255)
    static let accent = Color.white
    static let heat = Color(red: 1, green: 158 / 255, blue: 79 / 255)          // #FF9E4F
    static let nsHeat = NSColor(red: 1, green: 158 / 255, blue: 79 / 255, alpha: 1)
    static let nsHeatOnLight = NSColor(red: 194 / 255, green: 65 / 255, blue: 12 / 255, alpha: 1) // #C2410C

    /// 设计稿统一用“白色 + 不透明度”表示层级
    static func dim(_ o: Double) -> Color { text.opacity(o) }
    static let secondary = dim(0.72)
    static let tertiary = dim(0.62)

    /// 超过这个温度（摄氏）才上色（设计稿：平时永远单色）；设置里可调，默认 85°
    static var alertTemp: Double {
        let v = UserDefaults.standard.double(forKey: Prefs.alertTemp)
        return v > 0 ? v : 85
    }

    // MARK: 状态可视化：越平稳越白越平，越热越红、波峰越高

    /// 温度 → 丝线颜色：≤55° 纯白，75° 橙（设计稿 heat），≥92° 红
    static func heatTint(_ t: Double?) -> Color {
        let t = t ?? 40
        func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ f: Double) -> Color {
            let f = min(max(f, 0), 1)
            return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
        }
        let white = (1.0, 1.0, 1.0), orange = (1.0, 158 / 255.0, 79 / 255.0), red = (1.0, 0.30, 0.24)
        return t < 75 ? mix(white, orange, (t - 55) / 20) : mix(orange, red, (t - 75) / 17)
    }

    /// 一组丝线的颜色：主线取当前状态色，其余线略偏白，保留层次
    static func heatStrokes(_ t: Double?, _ widths: [CGFloat]) -> [(Color, CGFloat)] {
        let tint = heatTint(t)
        return widths.enumerated().map { i, w in (i == 0 ? tint : tint.mix(with: .white, by: 0.3), w) }
    }

    /// 温度 → 激烈程度：45° 以下几乎平静，95° 满格
    static func tempEnergy(_ t: Double?) -> Double { min(max(((t ?? 40) - 45) / 50, 0), 1) }

    /// 网速 → 激烈程度：按对数，10 KB/s 以下平静，10 MB/s 满格
    static func rateEnergy(_ bps: Double) -> Double { min(max(log10(max(bps, 1) / 10_000) / 3, 0), 1) }

    // MARK: 字体

    /// 点阵数字字体 Doto，设计稿用 900 字重
    static func doto(_ size: CGFloat) -> Font { Font(dotoNS(size)) }

    static func dotoNS(_ size: CGFloat) -> NSFont {
        let key = Int(size * 10)
        if let f = dotoCache[key] { return f }
        let wght = 0x7767_6874 // 'wght'
        let desc = NSFontDescriptor(fontAttributes: [
            .family: "Doto Black",
            .variation: [wght: 900],
        ])
        let f = NSFont(descriptor: desc, size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .black)
        dotoCache[key] = f
        return f
    }

    nonisolated(unsafe) private static var dotoCache: [Int: NSFont] = [:]

    /// 小标签用的等宽字体 JetBrains Mono
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("JetBrains Mono", fixedSize: size).weight(weight)
    }

    /// 启动时注册 app 包里 Fonts 目录下的字体（只对本进程可见）
    static func registerFonts() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "woff2", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - 通用小部件

/// 等宽大写小标签，例如 "TEMP · CPU"
struct Eyebrow: View {
    let text: String
    var size: CGFloat = 10.5
    var tracking: CGFloat = 1.4

    init(_ text: String, size: CGFloat = 10.5, tracking: CGFloat = 1.4) {
        self.text = text
        self.size = size
        self.tracking = tracking
    }

    var body: some View {
        Text(text)
            .font(Theme.mono(size))
            .tracking(tracking)
            .foregroundStyle(Theme.tertiary)
    }
}

/// 点阵大数字 + 右上角单位
struct DotNumber: View {
    let value: String
    let unit: String
    var size: CGFloat
    var unitSize: CGFloat
    var unitColor: Color = Theme.dim(0.7)
    var glow: Double = 0.35

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            RollingNumber(text: value, font: Theme.dotoNS(size), color: NSColor(Theme.text),
                          glow: Float(glow), glowRadius: size * 0.17)
            // 设计稿里 "°C" 的 ° 在闪（.blink），"%" 不闪
            // CATextLayer 没有基线信息，按顶边对齐（Doto 的 ° 本来就贴着字框顶部）
            HStack(alignment: .top, spacing: 0) {
                if unit.hasPrefix("°") {
                    BlinkingText(text: "°", font: Theme.dotoNS(unitSize), color: NSColor(unitColor))
                    Text(unit.dropFirst())
                } else {
                    Text(unit)
                }
            }
            .font(Theme.doto(unitSize))
            .foregroundStyle(unitColor)
            .padding(.top, size * 0.02)
        }
        .fixedSize()
    }
}

/// 卡片里的分区块
struct Card<Content: View>: View {
    var radius: CGFloat = 18
    var padding = EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14)
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

/// 窗口/弹出卡片的深色毛玻璃底
struct GlassBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 设计稿的“液态玻璃”外壳：模糊 + 暗色 + 细边 + 顶部高光
struct GlassShell: ViewModifier {
    var radius: CGFloat
    var tint: Double
    @AppStorage(Prefs.nativeGlass) private var native = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background { GlassSurface(native: native, radius: radius, tint: tint).clipShape(shape) }
            // 细边 + 顶部高光（设计稿 inset 0 1px 0 rgba(255,255,255,0.22)）
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.13)],
                                   startPoint: .top, endPoint: .init(x: 0.5, y: 0.12)),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            )
    }
}

/// 玻璃底：原生液态玻璃（NSGlassEffectView），或旧的磨砂 + 暗色叠层
struct GlassSurface: View {
    var native: Bool
    var radius: CGFloat
    var tint: Double

    var body: some View {
        if native {
            LiquidGlass(cornerRadius: radius, tint: tint)
        } else {
            ZStack {
                GlassBackdrop()
                Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255).opacity(tint)
            }
        }
    }
}

extension View {
    func glassShell(radius: CGFloat, tint: Double = 0.55) -> some View {
        modifier(GlassShell(radius: radius, tint: tint))
    }
}

/// 一行“色条 + 名称 + 数值”，用于内存图例
struct LegendRow: View {
    enum Swatch { case solid(Double, glow: Bool), outline }
    let swatch: Swatch
    let name: String
    let value: String
    var dimmed = false
    var swatchWidth: CGFloat = 14

    var body: some View {
        HStack(spacing: 8) {
            switch swatch {
            case let .solid(o, glow):
                Capsule().fill(Theme.accent.opacity(o))
                    .frame(width: swatchWidth, height: 2)
                    .shadow(color: glow ? Theme.accent : .clear, radius: 3)
            case .outline:
                Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1)
                    .frame(width: swatchWidth, height: 2)
            }
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(dimmed ? Theme.secondary : Theme.text)
    }
}
