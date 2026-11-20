import Foundation
import UIKit

/// 导入链路的诊断日志。**只写日志，不改变任何行为。**
///
/// 「点菜单 → 弹选择器 → 选完点打开 → 回调 → 拷贝 → 刷新」这条路上，
/// 中间几环只能在真机上观察，CI 只能编译到。日志落成「幕间」目录下的
/// 一个 txt：用「文件」App 打开就能看、能截图，不必连电脑。
///
/// 文件是 .txt，不是视频扩展名，不会被资料库扫进列表。可以随时删。
enum ImportLog {
    static var fileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("导入诊断.txt")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 每次启动写一行。版本号和构建号是判断「装的到底是哪一个包」的唯一依据——
    /// 之前几轮排查几次都卡在这个前提上。
    static func session() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        write("—— 启动 v\(version)（构建 \(build)）· iOS \(UIDevice.current.systemVersion) ——")
    }

    static func write(_ message: String) {
        let url = fileURL
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if text.isEmpty {
            text = "幕间 导入诊断日志（排障用，可随时删除）\n"
        }
        text += "[\(formatter.string(from: Date()))] \(message)\n"

        // 只留最近一段：这是排障用的，不需要长期堆积
        if text.count > 20_000 {
            text = "幕间 导入诊断日志（旧记录已截断）\n" + String(text.suffix(10_000))
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
