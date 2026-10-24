import AppKit
import ServiceManagement
import SwiftUI

// 主窗口的「设置」页：左下角齿轮进来。按用途分组，每组一张卡，每行「名称 + 一句说明 | 控件」。
// 改动立即生效：顶部栏下一次采样、卡片和窗口下一次刷新就会用新设置。

struct SettingsPage: View {
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    MenuBarGroup()
                    CardGroup()
                    UnitsGroup()
                }
                VStack(spacing: 14) {
                    AppearanceGroup()
                    AIGroup()
                    GeneralGroup()
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - 共用排版

/// 一组设置：小标题 + 一张卡，行之间细分隔线
struct SettingsGroup<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                Eyebrow(title)
            }
            .padding(.leading, 4)
            VStack(spacing: 0) {
                _VariadicView.Tree(DividedRows()) { content }
            }
            .padding(.horizontal, 16)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 在每一行之间插分隔线
private struct DividedRows: _VariadicView_MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            }
        }
    }
}

/// 一行：左边名称和说明，右边控件
struct SettingRow<Control: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 11)
    }
}

/// 一行里放一大块内容（列表之类），标题在上
struct SettingBlock<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 设置里统一用的分段选择（和主窗口的时间范围选择器一个样子，小一号）
struct SettingSegments<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { value, title in
                let on = value == selection
                Button { UIMotion.run { selection = value } } label: {
                    Text(title)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? .white : Theme.dim(0.8))
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.16))
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .fixedSize()
    }
}

private struct SettingSwitch: View {
    @Binding var on: Bool
    var body: some View {
        Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden().controlSize(.small)
    }
}

// MARK: - 顶部栏

private struct MenuBarGroup: View {
    @AppStorage(Prefs.barStyle) private var barStyle = BarStyle.ring.rawValue
    @AppStorage(Prefs.barText) private var barText = BarText.temp.rawValue
    @AppStorage(Prefs.alertTemp) private var alertTemp = 85.0

    var body: some View {
        let style = BarStyle(rawValue: barStyle) ?? .ring
        SettingsGroup(title: "顶部栏", icon: "menubar.rectangle") {
            SettingRow(title: "图标样式", note: style.subtitle) {
                SettingSegments(items: BarStyle.allCases.map { ($0.rawValue, $0.title) }, selection: $barStyle)
            }
            SettingRow(title: "图标旁显示", note: style == .orbit ? "双轨样式没有字位，这一项不生效" : "顶部栏图标右边的那几个字") {
                SettingSegments(items: BarText.allCases.map { ($0.rawValue, $0.title) }, selection: $barText)
                    .opacity(style == .orbit ? 0.4 : 1)
                    .disabled(style == .orbit)
            }
            SettingRow(title: "警戒温度", note: "超过它，图标和温度曲线变热色") {
                SettingSegments(items: [75.0, 80, 85, 90, 95].map { ($0, Fmt.temp($0)) }, selection: $alertTemp)
            }
        }
    }
}

// MARK: - 卡片

private struct CardGroup: View {
    @AppStorage(Prefs.cardTemp) private var showTemp = true
    @AppStorage(Prefs.cardCPU) private var showCPU = true
    @AppStorage(Prefs.cardMem) private var showMem = true
    @AppStorage(Prefs.cardNet) private var showNet = true
    @AppStorage(Prefs.cardBottomTab) private var bottomTab = "top"

    var body: some View {
        SettingsGroup(title: "卡片", icon: "rectangle.portrait") {
            SettingBlock(title: "显示哪些模块", note: "左键点顶部栏图标弹出的卡片；关掉的模块不显示，卡片随之变矮") {
                HStack(spacing: 8) {
                    ModuleChip(title: "温度", icon: "thermometer.medium", on: $showTemp)
                    ModuleChip(title: "CPU", icon: "cpu", on: $showCPU)
                    ModuleChip(title: "内存", icon: "memorychip", on: $showMem)
                    ModuleChip(title: "网络", icon: "arrow.up.arrow.down", on: $showNet)
                }
            }
            SettingRow(title: "底部列表", note: "卡片最下面默认显示哪一个") {
                SettingSegments(items: [("top", "进程 TOP"), ("ai", "AI 用量")], selection: $bottomTab)
            }
        }
    }
}

/// 可开关的模块小块：开着亮，关着暗
private struct ModuleChip: View {
    let title: String
    let icon: String
    @Binding var on: Bool

    var body: some View {
        Button { UIMotion.run { on.toggle() } } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14))
                    .scaleEffect(on ? 1 : 0.88)
                Text(title).font(.system(size: 11.5, weight: on ? .semibold : .regular))
            }
            .foregroundStyle(on ? .white : Theme.dim(0.45))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(.white.opacity(on ? 0.12 : 0.03), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(on ? 0.22 : 0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "点一下在卡片里隐藏" : "点一下在卡片里显示")
    }
}

// MARK: - 单位

private struct UnitsGroup: View {
    @AppStorage(Prefs.tempUnit) private var tempUnit = "c"
    @AppStorage(Prefs.rateUnit) private var rateUnit = "bytes"

    var body: some View {
        SettingsGroup(title: "单位", icon: "ruler") {
            SettingRow(title: "温度") {
                SettingSegments(items: [("c", "摄氏 °C"), ("f", "华氏 °F")], selection: $tempUnit)
            }
            SettingRow(title: "网速", note: rateUnit == "bits" ? "按比特，和宽带套餐的 Mbps 一致" : "按字节，和下载软件显示的一致") {
                SettingSegments(items: [("bytes", "MB/s"), ("bits", "Mbps")], selection: $rateUnit)
            }
        }
    }
}

// MARK: - 外观与性能

private struct AppearanceGroup: View {
    @AppStorage(Prefs.motion) private var motion = true
    @AppStorage(Prefs.nativeGlass) private var nativeGlass = true
    @AppStorage(Prefs.interval) private var interval = 2.0

    var body: some View {
        SettingsGroup(title: "外观与性能", icon: "sparkles.rectangle.stack") {
            SettingRow(title: "动效", note: "丝线起伏、扫光、点阵闪烁；低电量模式和系统「减弱动态效果」打开时自动停") {
                SettingSwitch(on: $motion)
            }
            SettingRow(title: "原生液态玻璃", note: "关掉改用磨砂材质") {
                SettingSwitch(on: $nativeGlass)
            }
            SettingRow(title: "后台刷新", note: "只有顶部栏常驻时按这个间隔；卡片或窗口打开时固定每秒刷新") {
                SettingSegments(items: [(1.0, "1 秒"), (2.0, "2 秒"), (5.0, "5 秒")], selection: $interval)
            }
        }
    }
}

// MARK: - AI 用量

private struct AIGroup: View {
    var body: some View {
        SettingsGroup(title: "AI 用量", icon: "sparkles") {
            SettingBlock(title: "显示哪些工具") {
                UsageToolToggles()
            }
            SettingBlock(title: "账号") {
                UsageAccountSettings(store: UsageStore.shared)
            }
        }
    }
}

// MARK: - 通用

private struct GeneralGroup: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsGroup(title: "通用", icon: "gearshape") {
            SettingRow(title: "登录时启动", note: loginError) {
                SettingSwitch(on: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
            }
            SettingRow(title: "版本") {
                Text(Self.version).font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "开发版"
        let b = info?["CFBundleVersion"] as? String
        return b.map { "\(v)（\($0)）" } ?? v
    }
}
