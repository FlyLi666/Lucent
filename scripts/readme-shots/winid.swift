import CoreGraphics
import Foundation
// 用法：winid <pid>  打印该进程屏幕上可见窗口：id 宽 高 层级 x y 透明度
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as! [String: CGFloat]
    print(w[kCGWindowNumber as String]!, Int(b["Width"]!), Int(b["Height"]!), w[kCGWindowLayer as String]!, Int(b["X"]!), Int(b["Y"]!), w[kCGWindowAlpha as String]!)
}
