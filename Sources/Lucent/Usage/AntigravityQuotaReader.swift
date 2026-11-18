import CoreFoundation
import Darwin
import Foundation

// Antigravity 订阅额度读取器：只走 `agy -p /usage --output-format json`（30 秒超时，后台线程执行）。
// 为什么不直连 Google `retrieveUserQuotaSummary`：实测不论 User-Agent 怎么传，Gemini 两桶恒回 100%，
// 与 agy 自报（5h / 周已用额度）对不上；`agy -p /usage --output-format json` 每次约 4 秒、不调模型，数值与 agy 界面一致，且不读任何凭据。

enum AntigravityQuotaSource: String, Sendable {
    case agyCLI = "agy-cli"
}

struct AntigravityQuotaResult: Sendable {
    var quotas: [QuotaWindow]
    var source: AntigravityQuotaSource?
    var failureReason: String?
}

final class AntigravityQuotaReader: Sendable {
    private static let cliTimeout: TimeInterval = 30

    /// 查一次当前 Antigravity 登录的四个额度桶。只调 `agy -p /usage --output-format json`，不读任何凭据。
    func fetchQuota() async -> AntigravityQuotaResult {
        #if DEBUG
        if UsageHome.debugOverride != nil {
            return AntigravityQuotaResult(quotas: [], source: nil, failureReason: nil)
        }
        #endif

        guard let bin = await Self.locateRealAgyBinary() else {
            return AntigravityQuotaResult(quotas: [], source: nil, failureReason: L("未找到 agy 命令行，无法读取额度"))
        }

        var env = ProcessInfo.processInfo.environment
        // 去掉环境变量里的第三方 Key，确保 agy 查询官方登录额度
        env.removeValue(forKey: "GEMINI_API_KEY")
        env.removeValue(forKey: "GOOGLE_GEMINI_BASE_URL")

        guard let out = await Self.runProcess(
            executable: bin,
            arguments: ["-p", "/usage", "--output-format", "json"],
            environment: env,
            timeout: Self.cliTimeout
        ) else {
            return AntigravityQuotaResult(quotas: [], source: .agyCLI, failureReason: L("无法启动 agy 读取额度"))
        }

        if out.timedOut {
            return AntigravityQuotaResult(quotas: [], source: .agyCLI, failureReason: L("Antigravity 额度查询超时"))
        }
        guard out.exitCode == 0 else {
            return AntigravityQuotaResult(quotas: [], source: .agyCLI, failureReason: L("Antigravity 没返回可识别的额度，请先运行 agy 登录"))
        }
        return Self.parseCLIResult(out.stdout)
    }

    // MARK: - JSON 解析（供 CLI 查询与 `--agy-quota-parse` 共用）

    static func parseCLIResult(_ data: Data) -> AntigravityQuotaResult {
        guard let quotas = parseCLIUsageJSON(data) else {
            return AntigravityQuotaResult(
                quotas: [],
                source: .agyCLI,
                failureReason: L("Antigravity 没返回可识别的额度，请先运行 agy 登录")
            )
        }
        return AntigravityQuotaResult(quotas: quotas, source: .agyCLI, failureReason: nil)
    }

    /// `agy -p /usage --output-format json`：`status == "SUCCESS"` 且 `command.data.groups[].buckets[]`（`id` / `remaining_fraction` / `reset_time`）
    static func parseCLIUsageJSON(_ data: Data) -> [QuotaWindow]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["status"] as? String) == "SUCCESS",
              let command = obj["command"] as? [String: Any],
              let cmdData = command["data"] as? [String: Any],
              let groups = cmdData["groups"] as? [[String: Any]]
        else { return nil }

        var rawBuckets: [(id: String?, remaining: Double?, resetTime: String?)] = []
        for group in groups {
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            for b in buckets {
                rawBuckets.append((
                    id: b["id"] as? String,
                    remaining: numericDouble(b["remaining_fraction"]),
                    resetTime: b["reset_time"] as? String
                ))
            }
        }
        return collectWindows(from: rawBuckets)
    }

    private static func collectWindows(from buckets: [(id: String?, remaining: Double?, resetTime: String?)]) -> [QuotaWindow]? {
        var ordered: [(order: Int, window: QuotaWindow)] = []
        for item in buckets {
            guard let id = item.id,
                  let mapped = mapBucket(id: id),
                  let remainingRaw = item.remaining
            else { continue }
            let remaining = min(max(remainingRaw, 0), 1)
            let reset = item.resetTime.flatMap(AntigravityUsageReader.parseTimestamp)
            ordered.append((mapped.order, QuotaWindow(
                id: id,
                kind: mapped.kind,
                usedFraction: 1.0 - remaining,
                resetsAt: reset)))
        }
        guard !ordered.isEmpty else { return nil }
        ordered.sort { $0.order < $1.order }
        return ordered.map(\.window)
    }

    private static func mapBucket(id: String) -> (order: Int, kind: QuotaWindow.Kind)? {
        switch id {
        case "gemini-5h": return (0, .geminiFiveHour)
        case "gemini-weekly": return (1, .geminiWeekly)
        case "3p-5h": return (2, .thirdPartyFiveHour)
        case "3p-weekly": return (3, .thirdPartyWeekly)
        default: return nil
        }
    }

    // MARK: - 本机 agy 定位

    private static func locateRealAgyBinary() async -> String? {
        if let direct = await findAgyInSearchDirs() {
            return direct
        }

        if let shell = nonEmpty(ProcessInfo.processInfo.environment["SHELL"]),
           let out = await runProcess(executable: shell, arguments: ["-l", "-c", "command -v agy"], timeout: 2),
           !out.timedOut, out.exitCode == 0,
           let text = String(data: out.stdout, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline).reversed() {
                let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.hasPrefix("/"), isRealAgyBinary(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func findAgyInSearchDirs() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
                var dirs = pathVar.split(separator: ":").filter { !$0.isEmpty }.map { URL(fileURLWithPath: String($0)) }
                dirs.append(home.appendingPathComponent(".local/bin"))
                dirs.append(URL(fileURLWithPath: "/opt/homebrew/bin"))
                dirs.append(URL(fileURLWithPath: "/usr/local/bin"))

                for dir in dirs {
                    let candidate = dir.appendingPathComponent("agy").path
                    if isRealAgyBinary(candidate) {
                        continuation.resume(returning: candidate)
                        return
                    }
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func isRealAgyBinary(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              fm.isExecutableFile(atPath: path)
        else { return false }
        if let fh = FileHandle(forReadingAtPath: path) {
            defer { try? fh.close() }
            let head = (try? fh.read(upToCount: 256)) ?? Data()
            if String(decoding: head, as: UTF8.self).contains("cc-switch-agy-wrapper") {
                return false
            }
        }
        return true
    }

    // MARK: - 进程与工具方法

    private struct ProcessOutput: Sendable {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async -> ProcessOutput? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                if let environment { proc.environment = environment }
                proc.standardInput = FileHandle.nullDevice

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                final class TimeoutFlag: @unchecked Sendable {
                    var value = false
                }
                let flag = TimeoutFlag()
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    guard proc.isRunning else { return }
                    flag.value = true
                    proc.terminate()
                    let pid = proc.processIdentifier
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                        if proc.isRunning { kill(pid, SIGKILL) }
                    }
                }
                timer.resume()

                let group = DispatchGroup()
                var stdoutData = Data()
                var stderrData = Data()

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                proc.waitUntilExit()
                timer.cancel()
                group.wait()

                continuation.resume(returning: ProcessOutput(
                    exitCode: proc.terminationStatus,
                    stdout: stdoutData,
                    stderr: stderrData,
                    timedOut: flag.value))
            }
        }
    }

    /// 排除 JSON bool 被桥接成 NSNumber (0/1) 的情况
    private static func numericDouble(_ raw: Any?) -> Double? {
        guard let num = raw as? NSNumber else { return nil }
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
        let v = num.doubleValue
        return v.isFinite ? v : nil
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
