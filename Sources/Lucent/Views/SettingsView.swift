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
        SettingsGroup(title: L10n.t("Menu bar"), icon: "menubar.rectangle") {
            SettingRow(title: L10n.t("Glyph"), note: style.subtitle) {
                SettingSegments(items: BarStyle.allCases.map { ($0.rawValue, $0.title) }, selection: $barStyle)
            }
            SettingRow(title: L10n.t("Glyph text"), note: style == .orbit ? L10n.t("Dual orbit has no text slot, so this does nothing") : L10n.t("The characters to the right of the glyph")) {
                SettingSegments(items: BarText.allCases.map { ($0.rawValue, $0.title) }, selection: $barText)
                    .opacity(style == .orbit ? 0.4 : 1)
                    .disabled(style == .orbit)
            }
            SettingRow(title: L10n.t("Alert temperature"), note: L10n.t("Above this, the glyph and temperature chart switch to heat color")) {
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
        SettingsGroup(title: L10n.t("Card"), icon: "rectangle.portrait") {
            SettingBlock(title: L10n.t("Modules"), note: L10n.t("Left-click the menu bar glyph. Hidden modules shrink the card.")) {
                HStack(spacing: 8) {
                    ModuleChip(title: L10n.t("Temperature"), icon: "thermometer.medium", on: $showTemp)
                    ModuleChip(title: "CPU", icon: "cpu", on: $showCPU)
                    ModuleChip(title: L10n.t("Memory"), icon: "memorychip", on: $showMem)
                    ModuleChip(title: L10n.t("Network"), icon: "arrow.up.arrow.down", on: $showNet)
                }
            }
            SettingRow(title: L10n.t("Bottom list"), note: L10n.t("Default tab at the bottom of the card")) {
                SettingSegments(items: [("top", L10n.t("Top processes")), ("ai", L10n.t("AI usage"))], selection: $bottomTab)
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
        .help(on ? L10n.t("Click to hide on the card") : L10n.t("Click to show on the card"))
    }
}

// MARK: - 单位

private struct UnitsGroup: View {
    @AppStorage(Prefs.tempUnit) private var tempUnit = "c"
    @AppStorage(Prefs.rateUnit) private var rateUnit = "bytes"

    var body: some View {
        SettingsGroup(title: L10n.t("Units"), icon: "ruler") {
            SettingRow(title: L10n.t("Temperature")) {
                SettingSegments(items: [("c", L10n.t("Celsius °C")), ("f", L10n.t("Fahrenheit °F"))], selection: $tempUnit)
            }
            SettingRow(title: L10n.t("Network rate"), note: rateUnit == "bits" ? L10n.t("Bits, matching typical broadband Mbps") : L10n.t("Bytes, matching download-manager speeds")) {
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
        SettingsGroup(title: L10n.t("Look & performance"), icon: "sparkles.rectangle.stack") {
            SettingRow(title: L10n.t("Motion"), note: L10n.t("Silk threads, sweeps, and blinking dots. Stops in Low Power Mode or Reduce Motion.")) {
                SettingSwitch(on: $motion)
            }
            SettingRow(title: L10n.t("Native Liquid Glass"), note: L10n.t("Off uses a frosted material instead")) {
                SettingSwitch(on: $nativeGlass)
            }
            SettingRow(title: L10n.t("Background refresh"), note: L10n.t("Used while only the menu bar is visible. The card and window refresh once a second.")) {
                SettingSegments(items: [(1.0, L10n.t("%d s", 1)), (2.0, L10n.t("%d s", 2)), (5.0, L10n.t("%d s", 5))], selection: $interval)
            }
        }
    }
}

// MARK: - AI 用量

private struct AIGroup: View {
    var body: some View {
        SettingsGroup(title: L10n.t("AI usage"), icon: "sparkles") {
            SettingBlock(title: L10n.t("Tools to show")) {
                UsageToolToggles()
            }
            SettingBlock(title: L10n.t("Accounts")) {
                UsageAccountSettings(store: UsageStore.shared)
            }
        }
    }
}

// MARK: - 通用

private struct GeneralGroup: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage(Prefs.language) private var language = L10n.Language.system.rawValue

    var body: some View {
        SettingsGroup(title: L10n.t("General"), icon: "gearshape") {
            SettingRow(title: L10n.t("Language"), note: L10n.t("Follows the system language unless you override it.")) {
                SettingSegments(items: L10n.Language.allCases.map { ($0.rawValue, $0.pickerTitle) }, selection: $language)
            }
            SettingRow(title: L10n.t("Launch at login"), note: loginError) {
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
            SettingRow(title: L10n.t("Version")) {
                Text(Self.version).font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? L10n.t("Dev")
        let b = info?["CFBundleVersion"] as? String
        return b.map { L10n.t("%@ (%@)", v, $0) } ?? v
    }
}
