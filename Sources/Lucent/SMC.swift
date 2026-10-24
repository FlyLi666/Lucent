import Foundation
import IOKit

/// 与 AppleSMC 内核扩展通信的结构体，内存布局必须与 C 的 SMCKeyData_t 一致（80 字节）。
private struct SMCParam {
    struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct PLimit {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0
    }
    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0           // 对齐 C 结构体中 keyInfo 的尾部填充
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

func fourCC(_ s: String) -> UInt32 {
    s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
}

func fourCCString(_ v: UInt32) -> String {
    let b = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    return String(decoding: b, as: UTF8.self)
}

/// 极简 SMC 读取器。只用公开的 IOKit 调用，无需 root、无需私有框架。
final class SMC {
    static let typeFLT = fourCC("flt ")
    static let typeSP78 = fourCC("sp78")

    private var conn: io_connect_t = 0

    init?() {
        assert(MemoryLayout<SMCParam>.stride == 80)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    private func call(_ input: inout SMCParam) -> SMCParam? {
        var output = SMCParam()
        var outSize = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &output, &outSize)
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    func keyInfo(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        var input = SMCParam()
        input.key = key
        input.data8 = 9                         // kSMCGetKeyInfo
        guard let o = call(&input) else { return nil }
        return (o.keyInfo.dataSize, o.keyInfo.dataType)
    }

    func key(at index: Int) -> UInt32? {
        var input = SMCParam()
        input.data8 = 8                         // kSMCGetKeyFromIndex
        input.data32 = UInt32(index)
        return call(&input)?.key
    }

    private func read(_ key: UInt32, size: UInt32) -> SMCParam? {
        var input = SMCParam()
        input.key = key
        input.keyInfo.dataSize = size
        input.data8 = 5                         // kSMCReadKey
        return call(&input)
    }

    func keyCount() -> Int {
        let k = fourCC("#KEY")
        guard let info = keyInfo(k), let o = read(k, size: info.size) else { return 0 }
        let b = o.bytes
        return Int(UInt32(b.0) << 24 | UInt32(b.1) << 16 | UInt32(b.2) << 8 | UInt32(b.3))
    }

    func temperature(_ key: UInt32, type: UInt32, size: UInt32) -> Double? {
        guard let o = read(key, size: size) else { return nil }
        let b = o.bytes
        switch type {
        case SMC.typeFLT where size >= 4:      // Apple Silicon：小端 Float32
            let bits = UInt32(b.0) | UInt32(b.1) << 8 | UInt32(b.2) << 16 | UInt32(b.3) << 24
            return Double(Float(bitPattern: bits))
        case SMC.typeSP78 where size >= 2:     // Intel：有符号 8.8 定点
            return Double(Int16(bitPattern: UInt16(b.0) << 8 | UInt16(b.1))) / 256
        default:
            return nil
        }
    }
}
