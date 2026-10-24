#if DEBUG
import AppKit
import SwiftUI

/// 仅调试版：`Lucent --snapshots <目录>` 采样一段时间后把卡片、主窗口、顶部栏图标渲染成 PNG，用来和设计稿对照。
/// 渲染的是图层树（含 Core Animation 的丝线、辉光、扫光、点阵的静止形态），不含原生玻璃对背景的折射。
@MainActor
enum DebugSnapshots {
    static var outputDir: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(monitor: Monitor, sampler: Sampler, nav: DashboardNav, into dir: URL, after seconds: Double = 20) {
        sampler.setDashboard(open: true)
        UsageStore.shared.setVisible(true)
        MotionHostView.debugForceVisible = true
        // `--hold N`：只开主窗口概览页挂 N 秒、不截图，用来量真实占用（top -pid）
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--hold"), i + 1 < args.count, let hold = Double(args[i + 1]) {
            let n = DashboardNav()
            n.section = .overview
            _ = place(DashboardView(monitor: monitor, nav: n), size: NSSize(width: 1200, height: 760))
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { NSApp.terminate(nil) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            saveGlyphs(monitor, to: dir.appendingPathComponent("menubar.png"))

            var jobs: [(NSWindow, URL)] = []
            jobs.append((place(PopoverView(monitor: monitor, openDashboard: {}, openSettings: {}), size: nil),
                         dir.appendingPathComponent("popover.png")))
            for s in [DashSection.overview, .ai, .info, .settings] {
                let n = DashboardNav()
                n.section = s
                jobs.append((place(DashboardView(monitor: monitor, nav: n), size: NSSize(width: 1200, height: 760)),
                             dir.appendingPathComponent("window-\(s.rawValue).png")))
            }
            // 等 NSViewRepresentable 布局、图层建好再渲染
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for (w, url) in jobs { render(w, to: url) }
                lumaProbe(jobs[0].0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) { NSApp.terminate(nil) }
            }
        }
    }

    /// 放进一个屏幕外的真实窗口，让 Core Animation 图层都建出来
    private static func place<V: View>(_ view: V, size: NSSize?) -> NSWindow {
        let host = NSHostingView(rootView: view.background(Color.black))
        let s = size ?? host.fittingSize
        let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: s.width, height: s.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        win.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return win
    }

    /// 从窗口服务器取本进程窗口的真实合成结果（含动画当前帧、原生玻璃）。
    /// CGWindowListCreateImage 在新 SDK 里被标为不可用，这里只在调试版里用 dlsym 取；截自己的窗口不需要录屏权限。
    private typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let capture: CaptureFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CaptureFn.self)
    }()

    /// 调试：每 0.1 秒量一次卡片温度曲线区域的平均亮度，连量 3 秒，看过渡时会不会掉亮
    static func lumaProbe(_ win: NSWindow) {
        guard let cap = capture else { return }
        print(String(format: "PROBE_START %.3f", CACurrentMediaTime()))
        var out: [String] = []
        for i in 0..<120 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50 * i)) {
                guard let img = cap(.null, 1 << 3, UInt32(win.windowNumber), 1 << 0)?.takeRetainedValue(),
                      let crop = img.cropping(to: CGRect(x: 40, y: 290, width: 640, height: 120)),
                      let ctx = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
                var sum = 0
                // 只算比背景亮的部分（线和辉光发出的光），背景不计
                for y in 0..<crop.height { for x in 0..<crop.width { sum += max(0, Int(p[y * ctx.bytesPerRow + x]) - 60) } }
                out.append(String(format: "%.0f", Double(sum) / 1000))
                if out.count == 120 { print("LUMA " + out.joined(separator: " ")) }
            }
        }
    }

    private static func render(_ win: NSWindow, to url: URL) {
        // 连拍 3 帧（间隔 0.5 秒），用来确认动画确实在动
        for i in 0..<3 {
            let t = DispatchTime.now() + .milliseconds(500 * i)
            DispatchQueue.main.asyncAfter(deadline: t) {
                // kCGWindowListOptionIncludingWindow = 1 << 3，kCGWindowImageBoundsIgnoreFraming = 1 << 0
                guard let cap = capture, let img = cap(.null, 1 << 3, UInt32(win.windowNumber), 1 << 0)?.takeRetainedValue() else { return }
                let u = i == 0 ? url : url.deletingPathExtension().appendingPathExtension("f\(i).png")
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: u)
            }
        }
    }

    /// 三种样式 × 平时/过热，分别画在深色和浅色顶部栏底上
    private static func saveGlyphs(_ monitor: Monitor, to url: URL) {
        let s = monitor.snapshot
        let pulse = monitor.cpuHistory.values(last: 20, maxPoints: 10)
        var glyphs: [BarGlyph] = []
        for hot in [false, true] {
            for style in BarStyle.allCases {
                glyphs.append(BarGlyph(style: style, cpuTicks: Int((s.cpu.total * 20).rounded()), cpu: s.cpu.total,
                                       mem: s.mem.usedFraction, pulse: pulse,
                                       text: style == .orbit ? nil : (hot ? "91°" : Fmt.temp(s.thermal.cpuAvg)), hot: hot))
            }
        }
        let scale: CGFloat = 4, cellW: CGFloat = 80, rowH: CGFloat = 30
        let size = NSSize(width: cellW * CGFloat(glyphs.count), height: rowH * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, name) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
            let ap = NSAppearance(named: name)!
            ap.performAsCurrentDrawingAppearance {
                let y = size.height - CGFloat(row + 1) * rowH
                (name == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: size.width, height: rowH).fill()
                for (i, g) in glyphs.enumerated() {
                    let img = g.image()
                    let draw: NSImage
                    if img.isTemplate {
                        // 模板图由系统着色：深色栏白、浅色栏黑
                        draw = NSImage(size: img.size, flipped: false) { r in
                            img.draw(in: r)
                            (name == .darkAqua ? NSColor.white : NSColor.black).set()
                            r.fill(using: .sourceAtop)
                            return true
                        }
                    } else {
                        draw = img
                    }
                    draw.draw(in: NSRect(x: CGFloat(i) * cellW + 8, y: y + (rowH - img.size.height) / 2,
                                         width: img.size.width, height: img.size.height))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
