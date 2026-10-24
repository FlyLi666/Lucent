import Foundation
import Darwin

// Claude 同一条 message.id 会随着流式补全重复出现，后面那次的 output 更大。
// 这里按 id 记下「上次已经加进聚合里的那一份」，下次见到就先减后加。
// 二进制 sidecar，不塞进 JSON 缓存，避免几万条记录把解码内存顶上去。

final class ClaudePriorStore {
    struct Rec: Sendable {
        var time: Double
        var input: Int64
        var output: Int64
        var cacheRead: Int64
        var write5m: Int64
        var write1h: Int64
        var cost: Double
        var savings: Double
        var durationMs: Int32
        var main: Bool
        var model: String
        var project: String?
        var sessionID: String?

        var tokens: TokenCountsCodable {
            TokenCountsCodable(input: input, output: output, cacheRead: cacheRead, cacheWrite: write5m + write1h)
        }
    }

    private(set) var byID: [String: Rec] = [:]
    /// 30 天窗口滑走之后，记录本身可以丢，但主链 id 还得留着，免得 sidechain 回放被当成新请求
    private(set) var settledMainIDs: Set<String> = []

    func rec(_ id: String) -> Rec? { byID[id] }

    func containsMain(_ id: String) -> Bool {
        if settledMainIDs.contains(id) { return true }
        return byID[id]?.main == true
    }

    func set(_ id: String, _ rec: Rec) {
        byID[id] = rec
        if rec.main { settledMainIDs.remove(id) }
    }

    /// 只在这一轮已经把文件读完时调用。更老的记录从字典里拿掉，主链 id 留在 settled。
    func prune(olderThan cutoff: Date) {
        let t = cutoff.timeIntervalSince1970
        var drop: [String] = []
        for (id, rec) in byID where rec.time < t {
            if rec.main { settledMainIDs.insert(id) }
            drop.append(id)
        }
        for id in drop { byID.removeValue(forKey: id) }
    }

    func save(to url: URL) {
        var strings: [String] = []
        var index: [String: UInt32] = [:]
        func intern(_ s: String) -> UInt32 {
            if let existing = index[s] { return existing }
            let idx = UInt32(strings.count)
            index[s] = idx
            strings.append(s)
            return idx
        }
        func internOpt(_ s: String?) -> UInt32 {
            guard let s else { return UInt32.max }
            return intern(s)
        }

        var records: [(idIdx: UInt32, modelIdx: UInt32, projectIdx: UInt32, sessionIdx: UInt32, rec: Rec)] = []
        records.reserveCapacity(byID.count)
        for (id, rec) in byID {
            records.append((intern(id), intern(rec.model), internOpt(rec.project), internOpt(rec.sessionID), rec))
        }
        let settledIdx = settledMainIDs.map { intern($0) }

        var data = Data()
        data.reserveCapacity(strings.count * 24 + records.count * 96 + 64)
        appendU32(0x4C43_5052, to: &data) // "LCPR"
        appendU32(1, to: &data)
        appendU32(UInt32(strings.count), to: &data)
        for s in strings {
            let bytes = Array(s.utf8)
            appendU32(UInt32(bytes.count), to: &data)
            data.append(contentsOf: bytes)
        }
        appendU32(UInt32(records.count), to: &data)
        for item in records {
            let rec = item.rec
            appendU32(item.idIdx, to: &data)
            appendU32(item.modelIdx, to: &data)
            appendU32(item.projectIdx, to: &data)
            appendU32(item.sessionIdx, to: &data)
            appendU64(rec.time.bitPattern, to: &data)
            appendI64(rec.input, to: &data)
            appendI64(rec.output, to: &data)
            appendI64(rec.cacheRead, to: &data)
            appendI64(rec.write5m, to: &data)
            appendI64(rec.write1h, to: &data)
            appendU64(rec.cost.bitPattern, to: &data)
            appendU64(rec.savings.bitPattern, to: &data)
            appendI32(rec.durationMs, to: &data)
            data.append(rec.main ? 1 : 0)
        }
        appendU32(UInt32(settledIdx.count), to: &data)
        for idx in settledIdx { appendU32(idx, to: &data) }

        UsageCacheLocation.ensureDir()
        // 直接原子写到目标路径。目录不存在时写会失败，调用方若仍把 JSON 游标存下去，
        // 下一轮会拿着空的去重表从游标后面接着加，同一条 id 就被算两次。
        try? data.write(to: url, options: .atomic)
    }

    /// 文件不存在或内容坏了都返回 nil。调用方决定是当「还没扫过」还是整份重扫。
    static func load(from url: URL) -> ClaudePriorStore? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        var offset = 0
        guard readU32(data, &offset) == 0x4C43_5052, readU32(data, &offset) == 1 else { return nil }
        guard let stringCount = readU32(data, &offset), stringCount < 5_000_000 else { return nil }
        var strings: [String] = []
        strings.reserveCapacity(Int(stringCount))
        for _ in 0..<stringCount {
            guard let len = readU32(data, &offset), len < 10_000_000, offset + Int(len) <= data.count else { return nil }
            let slice = data[offset..<(offset + Int(len))]
            strings.append(String(decoding: slice, as: UTF8.self))
            offset += Int(len)
        }
        func str(_ idx: UInt32) -> String? {
            guard idx != UInt32.max, Int(idx) < strings.count else { return nil }
            return strings[Int(idx)]
        }
        guard let recordCount = readU32(data, &offset), recordCount < 5_000_000 else { return nil }
        let store = ClaudePriorStore()
        store.byID.reserveCapacity(Int(recordCount))
        for _ in 0..<recordCount {
            guard let idIdx = readU32(data, &offset),
                  let modelIdx = readU32(data, &offset),
                  let projectIdx = readU32(data, &offset),
                  let sessionIdx = readU32(data, &offset),
                  let timeBits = readU64(data, &offset),
                  let input = readI64(data, &offset),
                  let output = readI64(data, &offset),
                  let cacheRead = readI64(data, &offset),
                  let write5m = readI64(data, &offset),
                  let write1h = readI64(data, &offset),
                  let costBits = readU64(data, &offset),
                  let savingsBits = readU64(data, &offset),
                  let durationMs = readI32(data, &offset),
                  offset < data.count,
                  let id = str(idIdx),
                  let model = str(modelIdx)
            else { return nil }
            let main = data[data.index(data.startIndex, offsetBy: offset)] == 1
            offset += 1
            store.byID[id] = Rec(
                time: Double(bitPattern: timeBits),
                input: input, output: output, cacheRead: cacheRead, write5m: write5m, write1h: write1h,
                cost: Double(bitPattern: costBits), savings: Double(bitPattern: savingsBits),
                durationMs: durationMs, main: main, model: model,
                project: str(projectIdx), sessionID: str(sessionIdx))
        }
        if let settledCount = readU32(data, &offset), settledCount < 5_000_000 {
            for _ in 0..<settledCount {
                guard let idx = readU32(data, &offset), let id = str(idx) else { break }
                store.settledMainIDs.insert(id)
            }
        }
        return store
    }

}

private func appendU32(_ v: UInt32, to data: inout Data) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}
private func appendU64(_ v: UInt64, to data: inout Data) {
    var le = v.littleEndian
    withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
}
private func appendI64(_ v: Int64, to data: inout Data) {
    appendU64(UInt64(bitPattern: v), to: &data)
}
private func appendI32(_ v: Int32, to data: inout Data) {
    appendU32(UInt32(bitPattern: v), to: &data)
}
private func readU32(_ data: Data, _ offset: inout Int) -> UInt32? {
    guard offset + 4 <= data.count else { return nil }
    let v: UInt32 = data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return 0 }
        var tmp = UInt32(0)
        memcpy(&tmp, base.advanced(by: offset), 4)
        return UInt32(littleEndian: tmp)
    }
    offset += 4
    return v
}
private func readU64(_ data: Data, _ offset: inout Int) -> UInt64? {
    guard offset + 8 <= data.count else { return nil }
    let v: UInt64 = data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return 0 }
        var tmp = UInt64(0)
        memcpy(&tmp, base.advanced(by: offset), 8)
        return UInt64(littleEndian: tmp)
    }
    offset += 8
    return v
}
private func readI64(_ data: Data, _ offset: inout Int) -> Int64? {
    guard let v = readU64(data, &offset) else { return nil }
    return Int64(bitPattern: v)
}
private func readI32(_ data: Data, _ offset: inout Int) -> Int32? {
    guard let v = readU32(data, &offset) else { return nil }
    return Int32(bitPattern: v)
}
