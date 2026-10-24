import AppKit
import QuartzCore
import CoreImage
import SwiftUI

// 设计稿里的动效（丝线起伏、辉光呼吸、内存环扫光、点阵闪烁、° 闪烁）全部交给 Core Animation：
// 动画由系统渲染进程逐帧合成，本进程只在数据变化时（每秒一次）提交一次新路径。
// 只在卡片/主窗口存在时才有这些图层；窗口被遮挡、低电量模式、系统“减弱动态效果”时全部停下。

// MARK: - 开关

@MainActor
final class MotionPolicy {
    static let shared = MotionPolicy()
    static let changed = Notification.Name("LucentMotionChanged")

    private(set) var enabled: Bool

    private init() {
        enabled = Self.compute()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh), name: .NSProcessInfoPowerStateDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(refresh), name: UserDefaults.didChangeNotification, object: nil)
    }

    private static func compute() -> Bool {
        UserDefaults.standard.bool(forKey: Prefs.motion)
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @objc private func refresh() {
        // 电源通知可能来自任意线程
        DispatchQueue.main.async {
            let now = Self.compute()
            guard now != self.enabled else { return }
            self.enabled = now
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
}

/// 界面切换（侧栏、页签、分段按钮、卡片）用的短动画：只在切换那一下跑，不常驻；
/// 动效关闭 / 低电量 / 减弱动态效果时直接切，不做过渡
enum UIMotion {
    @MainActor static var on: Bool { MotionPolicy.shared.enabled }
    /// 选中块滑动、页签切换
    static let snappy = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// 内容淡入
    static let soft = Animation.easeOut(duration: 0.26)

    @MainActor static func run(_ animation: Animation = snappy, _ body: () -> Void) {
        if on { withAnimation(animation, body) } else { body() }
    }

    /// 切换分区 / 页签时新内容的出场：淡入 + 轻轻上浮；旧内容只淡出
    static var contentSwap: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)).animation(soft),
                    removal: .opacity.animation(.easeOut(duration: 0.14)))
    }
}

/// 所有动画共用一个时间原点：数据刷新时替换动画，相位保持连续，不会“跳回开头”
enum MotionClock {
    @MainActor static let epoch = CACurrentMediaTime()
}

/// 动效视图的基类：处理开关变化和窗口遮挡
class MotionHostView: NSView {
    #if DEBUG
    /// 调试截图用：屏幕外的窗口也当作可见，好拍到动画帧
    nonisolated(unsafe) static var debugForceVisible = false
    #endif

    override var isFlipped: Bool { true }
    var motionOn: Bool {
        #if DEBUG
        if Self.debugForceVisible { return MotionPolicy.shared.enabled }
        #endif
        return MotionPolicy.shared.enabled && windowVisible
    }
    private var windowVisible = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged), name: MotionPolicy.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 手动建的图层默认按 1× 光栅化，在 Retina 上细线会糊掉/淡掉：统一跟随屏幕倍率
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncScale()
    }

    func syncScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        func apply(_ l: CALayer) {
            l.contentsScale = scale
            l.mask.map(apply)
            l.sublayers?.forEach(apply)
        }
        layer.map(apply)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncScale()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let w = window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: w)
            windowVisible = w.occlusionState.contains(.visible) || !w.isVisible
        }
    }

    @objc private func occlusionChanged() {
        let v = window?.occlusionState.contains(.visible) ?? false
        guard v != windowVisible else { return }
        windowVisible = v
        // 不可见时直接冻结整棵图层树的时间，渲染进程不再为它出帧
        layer?.speed = v ? 1 : 0
        if v { rebuild() }
    }

    @objc private func motionChanged() { rebuild() }

    /// 子类按 motionOn 重新挂动画
    func rebuild() {}

    static func noActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// MARK: - 丝线

/// 设计稿的辉光呼吸：stroke-opacity 0.45 ↔ 1，六种周期错开
private let glowCycles: [(dur: Double, delay: Double)] = [(2.6, 0), (3.4, -1.1), (4.2, -2.3), (2.9, -0.6), (3.7, -1.8), (4.6, -3)]

/// 一条丝线的形状来源：常驻的 16 帧起伏序列；数据刷新后的头 0.9 秒，从上一份形状逐点变形过来
@MainActor
private final class ThreadTrack {
    let seq: [[CGPoint]]   // 起伏序列（首尾同一帧）
    let rest: [CGPoint]    // 静止形态
    var from: ThreadTrack?
    var t0: CFTimeInterval = 0

    init(_ frames: [[CGPoint]]) {
        seq = Array(frames.dropLast())
        rest = frames.last ?? []
    }

    /// t 时刻屏幕上这条线的点，算法和 Core Animation 关键帧插值一致（均分时间、逐点线性）
    func points(at t: CFTimeInterval, period: Double, animate: Bool, fade: Double) -> [CGPoint] {
        var pts = rest
        if animate, seq.count >= 2 {
            let n = seq.count - 1
            var p = (t - MotionClock.epoch).truncatingRemainder(dividingBy: period) / period
            if p < 0 { p += 1 }
            let x = p * Double(n)
            let i = min(Int(x), n - 1)
            pts = Self.lerp(seq[i], seq[i + 1], CGFloat(x - Double(i)))
        }
        if let f = from, t - t0 < fade {
            let old = Self.resample(f.points(at: t, period: period, animate: animate, fade: fade), to: pts.count)
            let s = CGFloat(min(max((t - t0) / fade, 0), 1))
            pts = Self.lerp(old, pts, s * s * s * (s * (s * 6 - 15) + 10))   // smootherstep：起止都无速度突变
        }
        return pts
    }

    /// 已经走完的过渡不再往回追溯
    func prune(_ now: CFTimeInterval, fade: Double) {
        var n: ThreadTrack? = self
        while let c = n {
            if c.from != nil, now - c.t0 >= fade { c.from = nil; return }
            n = c.from
        }
    }

    static func lerp(_ a: [CGPoint], _ b: [CGPoint], _ s: CGFloat) -> [CGPoint] {
        guard a.count == b.count else { return b }
        return zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * s, y: $0.y + ($1.y - $0.y) * s) }
    }

    /// 历史点数变化时（刚启动、补齐）按位置线性重采样，保证逐点对应
    static func resample(_ a: [CGPoint], to n: Int) -> [CGPoint] {
        guard a.count != n, a.count >= 2, n >= 2 else { return a.count == n ? a : [] }
        return (0..<n).map { j in
            let x = Double(j) / Double(n - 1) * Double(a.count - 1)
            let i = min(Int(x), a.count - 2)
            let f = CGFloat(x - Double(i))
            return CGPoint(x: a[i].x + (a[i + 1].x - a[i].x) * f, y: a[i].y + (a[i + 1].y - a[i].y) * f)
        }
    }
}

/// 同一组线条常驻：数据刷新时每条线从当前形状逐点变形到新形状（0.9 秒），端点标记跟着平移，
/// 不再是“两张图交叉淡入”。变形在本进程按刷新算一次关键帧，之后交给渲染进程合成。
final class ThreadsNSView: MotionHostView {
    private var layersData: [ThreadLayer] = []
    private var glow: CGFloat = 3.2
    private var period: Double = 5.2
    private let root = CALayer()
    private var shapes: [CAShapeLayer] = []
    private var tracks: [ThreadTrack] = []
    private var markerLayers: [[CAShapeLayer]] = []
    private var structure = ""
    private var lastKey = ""
    private var builtWidth: CGFloat = 0
    static let fade: Double = 0.9
    /// 过渡关键帧数：0.9 秒约 30 帧，帧间再由渲染进程线性插值
    private static let blendSteps = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        // 沿用相加混合叠到背景上，辉光观感和之前一致
        layerUsesCoreImageFilters = true
        root.masksToBounds = false
        root.compositingFilter = CIFilter(name: "CIAdditionCompositing")
        layer?.addSublayer(root)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.width != builtWidth else { return }
        rebuild()
    }

    func update(_ data: [ThreadLayer], glow: CGFloat, period: Double) {
        self.glow = glow
        self.period = period
        let key = data.map(\.key).joined(separator: "#")
        guard key != lastKey else { return }
        lastKey = key
        layersData = data
        guard bounds.width > 0 else { return }
        Self.structure(of: data) == structure && !shapes.isEmpty ? morph() : rebuild()
    }

    /// 线条数、标记类型变了才需要重建图层；其余只换形状
    private static func structure(of data: [ThreadLayer]) -> String {
        data.map { "\($0.strokes.count)/\($0.markers)/\($0.data.count >= 2)" }.joined(separator: "#")
    }

    /// 尺寸或动效开关变化：直接重建，不做过渡
    override func rebuild() {
        guard bounds.width > 0 else { return }
        Self.noActions {
            root.frame = bounds
            build()
        }
        builtWidth = bounds.width
        structure = Self.structure(of: layersData)
    }

    private func build() {
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        shapes = []; tracks = []; markerLayers = []
        let w = bounds.width
        let animate = motionOn
        for l in layersData {
            let frames = l.liveFramePoints(width: w)
            for (k, (color, width)) in l.strokes.enumerated() {
                let shape = Self.line()
                style(shape, color: color, width: width)
                let track = ThreadTrack(frames[k])
                shape.path = smoothPath(track.rest).cgPath   // 静止时停在“完全展开”的形态
                if animate {
                    attachMorph(shape, track)
                    let g = glowCycles[k % glowCycles.count]
                    let pulse = CAKeyframeAnimation(keyPath: "opacity")
                    pulse.values = [0.45, 1, 0.45]
                    pulse.keyTimes = [0, 0.5, 1]
                    pulse.timingFunctions = [.init(name: .easeInEaseOut), .init(name: .easeInEaseOut)]
                    pulse.duration = g.dur
                    pulse.repeatCount = .infinity
                    pulse.beginTime = MotionClock.epoch + g.delay
                    pulse.isRemovedOnCompletion = false
                    shape.add(pulse, forKey: "pulse")
                } else {
                    shape.opacity = 0.8
                }
                root.addSublayer(shape)
                shapes.append(shape)
                tracks.append(track)
            }
            let ms = markers(l, width: w, animate: animate)
            ms.forEach(root.addSublayer)
            markerLayers.append(ms)
        }
        syncScale()
    }

    private func morph() {
        let w = bounds.width
        let animate = motionOn
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var s = 0
        for (li, l) in layersData.enumerated() {
            let frames = l.liveFramePoints(width: w)
            for (k, (color, width)) in l.strokes.enumerated() {
                let shape = shapes[s], old = tracks[s]
                let track = ThreadTrack(frames[k])
                style(shape, color: color, width: width, animated: animate)
                shape.path = smoothPath(track.rest).cgPath
                if animate {
                    old.prune(now, fade: Self.fade)
                    track.from = old
                    track.t0 = now
                    attachMorph(shape, track)
                    attachBlend(shape, track, now: now)
                }
                tracks[s] = track
                s += 1
            }
            for (m, p) in zip(markerLayers[li], markerPositions(l, width: w)) {
                let from = m.presentation()?.position ?? m.position
                m.position = p
                guard animate, from != p else { continue }
                let a = CABasicAnimation(keyPath: "position")
                a.fromValue = NSValue(point: from)
                a.toValue = NSValue(point: p)
                a.duration = Self.fade
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                m.add(a, forKey: "move")
            }
        }
        CATransaction.commit()
    }

    /// 常驻起伏：所有线共用时间原点，替换后相位连续
    private func attachMorph(_ shape: CAShapeLayer, _ track: ThreadTrack) {
        guard track.seq.count >= 2 else { shape.removeAnimation(forKey: "morph"); return }
        let morph = CAKeyframeAnimation(keyPath: "path")
        morph.values = track.seq.map { smoothPath($0).cgPath }
        morph.duration = period
        morph.repeatCount = .infinity
        morph.beginTime = MotionClock.epoch
        morph.isRemovedOnCompletion = false
        shape.add(morph, forKey: "morph")
    }

    /// 过渡：后加的动画覆盖同一属性，所以这 0.9 秒画的是“旧形状 → 新起伏”的混合；
    /// 最后一帧正好等于新起伏此刻的形状，结束时无缝交回 morph
    private func attachBlend(_ shape: CAShapeLayer, _ track: ThreadTrack, now: CFTimeInterval) {
        let n = Self.blendSteps
        let blend = CAKeyframeAnimation(keyPath: "path")
        blend.values = (0...n).map { i in
            let t = now + Self.fade * Double(i) / Double(n)
            return smoothPath(track.points(at: t, period: period, animate: true, fade: Self.fade)).cgPath
        }
        blend.duration = Self.fade
        blend.beginTime = shape.convertTime(now, from: nil)
        shape.add(blend, forKey: "blend")
    }

    private func style(_ shape: CAShapeLayer, color: Color, width: CGFloat, animated: Bool = false) {
        let c = NSColor(color).cgColor
        if animated, let old = shape.strokeColor, old != c {
            for key in ["strokeColor", "shadowColor"] {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = old
                a.toValue = c
                a.duration = Self.fade
                shape.add(a, forKey: key)
            }
        }
        shape.strokeColor = c
        shape.lineWidth = width * 1.5
        shape.shadowColor = c
        shape.shadowRadius = glow
        shape.shadowOpacity = 1
    }

    private static func line() -> CAShapeLayer {
        let s = CAShapeLayer()
        s.fillColor = nil
        s.lineCap = .round
        s.lineJoin = .round
        s.shadowOffset = .zero
        return s
    }

    /// ring：起点、终点各一颗发光点 + 细圈（终点那颗呼吸，设计稿 .gd）；dot：两颗小点
    private func markers(_ l: ThreadLayer, width w: CGFloat, animate: Bool) -> [CAShapeLayer] {
        guard l.data.count >= 2 else { return [] }
        let a = l.point(0, width: w), b = l.point(l.data.count - 1, width: w)
        switch l.markers {
        case .none:
            return []
        case .dot:
            return [a, b].map { Self.dot(1.4, glow: false, at: $0) }
        case .ring:
            let end = Self.dot(2.0, glow: true, at: b)
            if animate {
                let p = CAKeyframeAnimation(keyPath: "opacity")
                p.values = [0.55, 1, 0.55]
                p.keyTimes = [0, 0.5, 1]
                p.duration = 2.6
                p.repeatCount = .infinity
                p.beginTime = MotionClock.epoch
                p.isRemovedOnCompletion = false
                end.add(p, forKey: "pulse")
            }
            return [Self.dot(1.8, glow: true, at: a), Self.ring(4.2, at: a), end, Self.ring(4.2, at: b)]
        }
    }

    /// 与 markers() 返回的图层一一对应的位置
    private func markerPositions(_ l: ThreadLayer, width w: CGFloat) -> [CGPoint] {
        guard l.data.count >= 2 else { return [] }
        let a = l.point(0, width: w), b = l.point(l.data.count - 1, width: w)
        switch l.markers {
        case .none: return []
        case .dot: return [a, b]
        case .ring: return [a, a, b, b]
        }
    }

    private static func dot(_ r: CGFloat, glow: Bool, at p: CGPoint) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        s.position = p
        s.fillColor = NSColor.white.withAlphaComponent(glow ? 1 : 0.8).cgColor
        if glow {
            s.shadowColor = NSColor.white.cgColor
            s.shadowRadius = 3
            s.shadowOpacity = 1
            s.shadowOffset = .zero
        }
        return s
    }

    private static func ring(_ r: CGFloat, at p: CGPoint) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        s.position = p
        s.fillColor = nil
        s.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
        s.lineWidth = 0.5
        return s
    }
}

struct ThreadsView: NSViewRepresentable {
    var layers: [ThreadLayer]
    var glow: CGFloat
    var period: Double

    func makeNSView(context: Context) -> ThreadsNSView { ThreadsNSView(frame: .zero) }
    func updateNSView(_ v: ThreadsNSView, context: Context) { v.update(layers, glow: glow, period: period) }
}

extension ThreadLayer {
    /// 数据没变就不重画（避免无意义的过渡）
    var key: String {
        data.map { String(format: "%.3f", $0) }.joined(separator: ",")
            + "|\(String(format: "%.2f", energy))|" + strokes.map { "\($0.0)" }.joined()
    }

    /// 状态越激烈，丝线抖动越大：平稳时几乎是一条线，满负荷/高温时上下翻腾
    var effectiveSpread: Double { Double(spread) * (0.3 + 1.7 * min(max(energy, 0), 1)) }

    /// 设计稿 wave().live()：每条线 16 帧——从两端连线“弹”成真实形状，停留，再松弛回去；各线起始相位错开
    func liveFramePoints(width w: CGFloat) -> [[[CGPoint]]] {
        let m = data.count
        guard m >= 2 else { return strokes.map { _ in [[]] } }
        var r = SeededRNG(seed)
        let y0 = base - dir * CGFloat(data[0]) * amp
        let y1 = base - dir * CGFloat(data[m - 1]) * amp
        let spread = effectiveSpread
        func H(_ t: Double) -> Double { t <= 0 ? 0 : 1 - exp(-4.5 * t) * cos(10 * t) }

        return strokes.indices.map { k in
            let jit = (r.next() - 0.5) * spread * (k == 0 ? 0.3 : 1.4)
            let ph = r.next() * 6.28
            let fr = 0.45 + r.next() * 0.35
            let wob = spread * (0.6 + r.next() * 0.5)
            let rot = Int(r.next() * 16)
            let st = 6.2832 / 16

            func frame(_ phase: Double, _ p: Double, _ rel: Double) -> [CGPoint] {
                let pts = (0..<m).map { j -> CGPoint in
                    let u = Double(j) / Double(m - 1)
                    let v = data[j], env = 0.3 + v * 1.2
                    let target = Double(base) - Double(dir) * (v * Double(amp) + (jit * env + sin(phase + Double(j) * fr) * wob * env) * sin(.pi * u))
                    let c = Double(y0) + Double(y1 - y0) * u
                    return CGPoint(x: CGFloat(u) * w, y: CGFloat(c + (target - c) * (0.6 + 0.4 * H(p - u) * rel)))
                }
                return pts
            }

            var ds: [[CGPoint]] = []
            for t in 0...9 { ds.append(frame(ph + Double(t) * st, Double(t) / 9 * 1.65, 1)) }
            ds.append(frame(ph + 10 * st, 3, 1))
            ds.append(frame(ph + 11 * st, 3, 1))
            for (i, rl) in [0.75, 0.5, 0.25, 0.08].enumerated() { ds.append(frame(ph + Double(12 + i) * st, 3, rl)) }
            var seq = Array(ds[rot...] + ds[..<rot])
            seq.append(seq[0])
            // 最后一个元素用作静止形态：完全展开的那一帧
            seq.append(frame(ph, 3, 1))
            return seq
        }
    }
}

// MARK: - 内存环扫光

/// 设计稿 .sweep：一道锥形渐变绕环旋转，只在“已用”那段的同心点阵细环上可见
final class RingSweepNSView: MotionHostView {
    var used: Double = 0
    var radius: CGFloat = 40
    var thick: CGFloat = 12
    private let glowLayer = CALayer()      // 外层：辉光（阴影取自已遮罩的内容）
    private let maskedLayer = CALayer()    // 中层：固定的点阵细环遮罩
    private let gradient = CAGradientLayer() // 内层：旋转的锥形渐变
    private let band = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        let accent = NSColor.white
        gradient.colors = [
            accent.withAlphaComponent(0).cgColor,
            accent.withAlphaComponent(0).cgColor,
            accent.withAlphaComponent(0.22).cgColor,
            accent.cgColor,
            accent.withAlphaComponent(0).cgColor,
        ]
        gradient.locations = [0, 232.0 / 360, 316.0 / 360, 358.0 / 360, 1].map { NSNumber(value: $0) }
        band.fillColor = nil
        band.strokeColor = NSColor.black.cgColor
        band.lineWidth = 0.75
        maskedLayer.mask = band
        maskedLayer.addSublayer(gradient)
        glowLayer.addSublayer(maskedLayer)
        // drop-shadow(0 0 2px white .9) drop-shadow(0 0 6px white .45) 的近似
        glowLayer.shadowColor = NSColor.white.cgColor
        glowLayer.shadowOpacity = 1
        glowLayer.shadowRadius = 3
        glowLayer.shadowOffset = .zero
        layer?.addSublayer(glowLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        rebuild()
    }

    func update(used: Double, radius: CGFloat, thick: CGFloat) {
        let changed = abs(used - self.used) > 0.002 || radius != self.radius || thick != self.thick
        self.used = used; self.radius = radius; self.thick = thick
        if changed { rebuild() }
    }

    override func rebuild() {
        guard bounds.width > 0 else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let u = min(max(used, 0), 1)
        Self.noActions {
            glowLayer.frame = bounds
            maskedLayer.frame = bounds
            band.frame = bounds
            // 旋转的层只设 bounds/position，不碰 frame（frame 在有旋转变换时会被拉伸）
            gradient.bounds = CGRect(origin: .zero, size: bounds.size)
            gradient.position = c

            // 同心细环（间距 1.6），从 12 点顺时针到已用比例；每一圈的起止点随机错开，边缘参差
            let p = CGMutablePath()
            var r = radius - thick / 2 + 0.6
            var rng = SeededRNG(13)
            while r <= radius + thick / 2 {
                let f0 = rng.next() * 0.02
                let f1 = max(u - rng.next() * rng.next() * 0.07 + 0.006, f0 + 0.01)
                let steps = max(Int((f1 - f0) * 180), 1)
                for i in 0...steps {
                    let a = -Double.pi / 2 + (f0 + (f1 - f0) * Double(i) / Double(steps)) * 2 * .pi
                    let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                r += 1.6
            }
            band.path = p

            gradient.removeAllAnimations()
            if motionOn {
                gradient.setAffineTransform(.identity)
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = 2 * Double.pi
                spin.duration = 3.2
                spin.repeatCount = .infinity
                spin.beginTime = MotionClock.epoch
                spin.isRemovedOnCompletion = false
                gradient.add(spin, forKey: "spin")
            } else {
                // 静止：亮头停在已用段末端
                gradient.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat((u * 360 - 358) * .pi / 180)))
            }
        }
    }
}

struct RingSweep: NSViewRepresentable {
    var used: Double
    var radius: CGFloat
    var thick: CGFloat

    func makeNSView(context: Context) -> RingSweepNSView { RingSweepNSView(frame: .zero) }
    func updateNSView(_ v: RingSweepNSView, context: Context) { v.update(used: used, radius: radius, thick: thick) }
}

// MARK: - 点阵闪烁

/// 设计稿 twOn / twE / twOff：每颗点各自随机周期、随机相位地闪
enum Twinkle {
    case on, e, off

    var keyTimes: [Double] {
        switch self {
        case .on: return [0, 0.06, 0.12, 0.49, 0.53, 0.59, 1]
        case .e: return [0, 0.06, 0.12, 0.55, 0.60, 0.66, 1]
        case .off: return [0, 0.04, 0.09, 1]
        }
    }

    var values: [Double] {
        switch self {
        case .on: return [0.62, 1, 0.62, 0.62, 0.95, 0.7, 0.62]
        case .e: return [0.36, 0.85, 0.36, 0.36, 0.7, 0.4, 0.36]
        case .off: return [0.07, 0.34, 0.07, 0.07]
        }
    }
}

/// 一组网格点：cols × rows，每颗点的状态由外部给出
final class DotGridNSView: MotionHostView {
    struct Spec: Equatable {
        var cols: Int
        var rows: Int
        var states: [Twinkle]       // 按行优先
        var staticOpacity: [Float]  // 动画关闭时的不透明度
        var seed: UInt32
    }

    private var spec: Spec?
    private var dots: [CALayer] = []
    private var applied: [Twinkle?] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.shadowColor = NSColor.white.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = .zero
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ s: Spec) {
        guard s != spec else { return }
        let rebuildAll = spec?.cols != s.cols || spec?.rows != s.rows
        spec = s
        if rebuildAll { build() }
        apply(force: false)
    }

    private func build() {
        guard let s = spec, let root = layer else { return }
        dots.forEach { $0.removeFromSuperlayer() }
        dots = (0..<(s.cols * s.rows)).map { i in
            let d = CALayer()
            d.frame = CGRect(x: CGFloat(i % s.cols) * 7.5, y: CGFloat(i / s.cols) * 7.5, width: 5, height: 5)
            d.cornerRadius = 2.5
            d.backgroundColor = NSColor.white.cgColor
            root.addSublayer(d)
            return d
        }
        applied = Array(repeating: nil, count: dots.count)
        syncScale()
    }

    override func rebuild() { apply(force: true) }

    private func apply(force: Bool) {
        guard let s = spec else { return }
        let animate = motionOn
        var rng = SeededRNG(s.seed)
        Self.noActions {
            for (i, d) in dots.enumerated() {
                let state = s.states[i]
                let dur = 1.4 + rng.next() * 3.6
                let delay = rng.next() * 5
                d.opacity = s.staticOpacity[i]
                guard force || applied[i] != state else { continue }
                applied[i] = state
                d.removeAllAnimations()
                guard animate else { continue }
                let a = CAKeyframeAnimation(keyPath: "opacity")
                a.values = state.values
                a.keyTimes = state.keyTimes.map { NSNumber(value: $0) }
                a.duration = dur
                a.repeatCount = .infinity
                a.beginTime = MotionClock.epoch - delay
                a.isRemovedOnCompletion = false
                d.add(a, forKey: "twinkle")
            }
        }
    }
}

struct DotGrid: NSViewRepresentable {
    var spec: DotGridNSView.Spec

    func makeNSView(context: Context) -> DotGridNSView { DotGridNSView(frame: .zero) }
    func updateNSView(_ v: DotGridNSView, context: Context) { v.update(spec) }
}

// MARK: - CPU 核心柱：水位平滑升降

/// 一根核心柱：底下一层暗点、上面一层亮点，亮点层用渐变遮罩露出「水位」以下的部分。
/// 数据刷新时只把水位从当前位置平滑推到新位置（0.9 秒），边缘一行半明半暗，整根柱子是上下浮动而不是整行跳；
/// 每颗点自己的闪烁一直跑，不会每次刷新都重启。
final class CoreColumnNSView: MotionHostView {
    struct Spec: Equatable {
        var rows: Int
        var level: Double      // 0...1
        var isP: Bool
        var seed: UInt32
    }

    static let rise: Double = 0.9
    private var spec: Spec?
    private let dim = CALayer()
    private let bright = CALayer()
    private let mask = CAGradientLayer()
    private var built = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        for l in [dim, bright] { layer?.addSublayer(l) }
        bright.shadowColor = NSColor.white.cgColor
        bright.shadowOpacity = 0.45
        bright.shadowRadius = 1.5
        bright.shadowOffset = .zero
        mask.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.white.cgColor, NSColor.white.cgColor]
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        bright.mask = mask
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Self.noActions {
            for l in [dim, bright] { l.frame = bounds }
            mask.frame = bounds
        }
    }

    func update(_ s: Spec) {
        guard s != spec else { return }
        let old = spec
        spec = s
        if !built || old?.rows != s.rows || old?.isP != s.isP { build(); built = true }
        setLevel(animated: old != nil && motionOn)
    }

    override func rebuild() {
        guard spec != nil else { return }
        build()
        setLevel(animated: false)
    }

    /// 遮罩的渐变位置：上面透明、下面不透明，交界处留一行宽的柔边（视图是翻转坐标，0 在顶）
    private func locations(_ level: Double, rows: Int) -> [NSNumber] {
        let soft = 1 / Double(rows)
        let edge = 1 - min(max(level, soft), 1)
        return [0, max(edge - soft, 0), edge, 1].map { NSNumber(value: $0) }
    }

    private func setLevel(animated: Bool) {
        guard let s = spec else { return }
        let to = locations(s.level, rows: s.rows)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            let from = (mask.presentation()?.locations ?? mask.locations) ?? to
            let a = CABasicAnimation(keyPath: "locations")
            a.fromValue = from
            a.toValue = to
            a.duration = Self.rise
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mask.add(a, forKey: "level")
        }
        mask.locations = to
        CATransaction.commit()
    }

    private func build() {
        guard let s = spec else { return }
        let animate = motionOn
        var rng = SeededRNG(s.seed)
        Self.noActions {
            for container in [dim, bright] { container.sublayers?.forEach { $0.removeFromSuperlayer() } }
            for i in 0..<(s.rows * 3) {
                let dur = 1.4 + rng.next() * 3.6
                let delay = rng.next() * 5
                let frame = CGRect(x: CGFloat(i % 3) * 7.5, y: CGFloat(i / 3) * 7.5, width: 5, height: 5)
                for (container, state) in [(dim, Twinkle.off), (bright, s.isP ? Twinkle.on : .e)] {
                    let d = CALayer()
                    d.frame = frame
                    d.cornerRadius = 2.5
                    d.backgroundColor = NSColor.white.cgColor
                    d.opacity = state == .off ? 0.08 : (s.isP ? 0.92 : 0.6)
                    if animate {
                        let a = CAKeyframeAnimation(keyPath: "opacity")
                        a.values = state.values
                        a.keyTimes = state.keyTimes.map { NSNumber(value: $0) }
                        a.duration = dur
                        a.repeatCount = .infinity
                        a.beginTime = MotionClock.epoch - delay
                        a.isRemovedOnCompletion = false
                        d.add(a, forKey: "twinkle")
                    }
                    container.addSublayer(d)
                }
            }
        }
        syncScale()
    }
}

struct CoreColumnDots: NSViewRepresentable {
    var spec: CoreColumnNSView.Spec

    func makeNSView(context: Context) -> CoreColumnNSView { CoreColumnNSView(frame: .zero) }
    func updateNSView(_ v: CoreColumnNSView, context: Context) { v.update(spec) }
}

// MARK: - ° 闪烁

/// 设计稿 .blink：1 秒一个周期，半亮半暗（steps 动画）。
/// 用 CATextLayer + 离散不透明度动画实现：由渲染进程翻转，不会每半秒唤醒 SwiftUI 重新计算界面。
final class BlinkNSView: MotionHostView {
    private let text = CATextLayer()
    private var key = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.alignmentMode = .left
        layer?.addSublayer(text)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ s: String, font: NSFont, color: NSColor) {
        let k = "\(s)|\(font.pointSize)|\(color)"
        guard k != key else { return }
        key = k
        Self.noActions {
            text.string = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            text.frame = bounds
        }
        syncScale()
        rebuild()
    }

    override func layout() {
        super.layout()
        Self.noActions { text.frame = bounds }
    }

    override func rebuild() {
        text.removeAllAnimations()
        guard motionOn else { return }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 0.12]
        a.keyTimes = [0, 0.5]
        a.calculationMode = .discrete
        a.duration = 1
        a.repeatCount = .infinity
        a.beginTime = MotionClock.epoch
        a.isRemovedOnCompletion = false
        text.add(a, forKey: "blink")
    }
}

struct BlinkingText: NSViewRepresentable {
    let text: String
    var font: NSFont
    var color: NSColor

    func makeNSView(context: Context) -> BlinkNSView { BlinkNSView(frame: .zero) }
    func updateNSView(_ v: BlinkNSView, context: Context) { v.update(text, font: font, color: color) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BlinkNSView, context: Context) -> CGSize? {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }
}

// MARK: - 数字滚动

/// 里程表式数字：每位一个 CATextLayer，只有变了的那几位做上下推入的过渡（由渲染进程执行）。
/// 之前用 SwiftUI 的 numericText 过渡，每帧都在本进程里重绘带辉光的文字，CPU 占用高达三成，所以换成这个。
final class RollingNumberNSView: MotionHostView {
    private var chars: [CATextLayer] = []
    private var text = ""
    private var font = NSFont.systemFont(ofSize: 12)
    private var color = NSColor.white
    private let holder = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(holder)
        holder.shadowOffset = .zero
        holder.shadowColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    static func width(of c: Character, _ font: NSFont) -> CGFloat {
        // 数字统一按 "0" 的宽度排，跳动时不左右晃
        let sample = c.isNumber ? "0" : String(c)
        return ceil((sample as NSString).size(withAttributes: [.font: font]).width)
    }

    static func size(_ text: String, _ font: NSFont) -> CGSize {
        CGSize(width: text.reduce(0) { $0 + width(of: $1, font) }, height: ceil(font.ascender - font.descender))
    }

    func update(_ newText: String, font: NSFont, color: NSColor, glow: Float, glowRadius: CGFloat) {
        let styleChanged = font != self.font || color != self.color
        self.font = font
        self.color = color
        Self.noActions {
            holder.shadowOpacity = glow
            holder.shadowRadius = glowRadius
        }
        let old = Array(text), new = Array(newText)
        text = newText
        if styleChanged || old.count != new.count || chars.count != new.count {
            rebuildChars(new, fade: !old.isEmpty && !styleChanged)
            return
        }
        // 只给变了的那几位做过渡：数值变大从下往上推，变小从上往下推
        let up = (Double(newText) ?? 0) >= (Double(String(old)) ?? 0)
        for (i, (a, b)) in zip(old, new).enumerated() where a != b {
            let l = chars[i]
            if motionOn {
                let t = CATransition()
                t.type = .push
                t.subtype = up ? .fromBottom : .fromTop
                t.duration = 0.45
                t.timingFunction = CAMediaTimingFunction(name: .easeOut)
                l.add(t, forKey: "roll")
            }
            Self.noActions { l.string = attributed(b) }
        }
    }

    private func attributed(_ c: Character) -> NSAttributedString {
        NSAttributedString(string: String(c), attributes: [.font: font, .foregroundColor: color])
    }

    private func rebuildChars(_ new: [Character], fade: Bool) {
        Self.noActions {
            chars.forEach { $0.superlayer?.removeFromSuperlayer() }
            var x: CGFloat = 0
            let h = ceil(font.ascender - font.descender)
            chars = new.map { c in
                let w = Self.width(of: c, font)
                // 外层裁剪框只框住数字本身的高度（Doto 字框上方有大段空白，框太高时滚动中会看到旧字残影）；
                // 推入过渡作用在里面的文字层上，旧字一滑出数字区就被裁掉
                let top = max(floor(font.ascender - font.capHeight) - 1, 0)
                let clip = CALayer()
                clip.frame = CGRect(x: x, y: top, width: w, height: min(ceil(font.capHeight) + 2, h - top))
                clip.masksToBounds = true
                let l = CATextLayer()
                l.frame = CGRect(x: 0, y: -top, width: w, height: h)
                l.alignmentMode = .center
                l.string = attributed(c)
                clip.addSublayer(l)
                x += w
                holder.addSublayer(clip)
                return l
            }
            holder.frame = CGRect(x: 0, y: 0, width: x, height: h)
        }
        syncScale()
        if fade && motionOn {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.35
            holder.add(t, forKey: "fade")
        }
    }
}

struct RollingNumber: NSViewRepresentable {
    let text: String
    let font: NSFont
    var color: NSColor = .white
    var glow: Float = 0
    var glowRadius: CGFloat = 0

    func makeNSView(context: Context) -> RollingNumberNSView { RollingNumberNSView(frame: .zero) }

    func updateNSView(_ v: RollingNumberNSView, context: Context) {
        v.update(text, font: font, color: color, glow: glow, glowRadius: glowRadius)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RollingNumberNSView, context: Context) -> CGSize? {
        RollingNumberNSView.size(text, font)
    }
}

extension View {
    /// 让 NSViewRepresentable 也能参与文字基线对齐
    func baseline(of font: NSFont) -> some View {
        alignmentGuide(.firstTextBaseline) { $0[.top] + font.ascender }
            .alignmentGuide(.lastTextBaseline) { $0[.top] + font.ascender }
    }
}

// MARK: - 原生液态玻璃

/// macOS 26 的 NSGlassEffectView；偏好里可切回旧的磨砂材质做对比
struct LiquidGlass: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tint: Double

    func makeNSView(context: Context) -> NSView {
        let g = NSGlassEffectView()
        g.style = .regular
        g.appearance = NSAppearance(named: .darkAqua)
        return g
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let g = nsView as? NSGlassEffectView else { return }
        g.cornerRadius = cornerRadius
        g.tintColor = NSColor(red: 14 / 255, green: 14 / 255, blue: 16 / 255, alpha: tint)
    }
}
