import Foundation

/// 一次导入的进度：总共几个、搬完几个
struct ImportProgress: Equatable, Sendable {
    var done: Int
    var total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }
}

/// 导入结果。同名文件会被自动改成「名字 2」，单独计数，好在提示里说清楚。
struct ImportResult: Equatable, Sendable {
    var total = 0
    var copied = 0
    var renamed = 0
    var failed = 0
    /// 真正落地的文件。调用方靠它判断「刚打开的那个文件要不要直接播」
    var saved: [URL] = []
    /// 失败原因，只留第一条。以前失败只报「1 个失败」，用户和维护者都不知道
    /// 是文件没下载完、还是格式不支持，出了问题只能猜。
    var reason: String?

    var summary: String {
        guard copied > 0 || failed > 0 else { return "没有导入成功" }
        var parts: [String] = []
        if copied > 0 { parts.append("导入 \(copied) 个") }
        if renamed > 0 { parts.append("\(renamed) 个同名已改名") }
        if failed > 0 { parts.append("\(failed) 个失败") }
        if failed > 0, let reason, !reason.isEmpty { parts.append(reason) }
        return parts.joined(separator: "，")
    }
}

/// 待搬进资料库的一个文件
struct ImportItem: Sendable {
    var url: URL
    /// 想要的显示名；nil 时用 URL 自带的名字
    var preferredName: String?
    /// 相册导入的临时文件用 move，省掉一次完整拷贝
    var moving: Bool

    init(url: URL, preferredName: String? = nil, moving: Bool = false) {
        self.url = url
        self.preferredName = preferredName
        self.moving = moving
    }
}

enum ImportService {
    /// 搬一个文件进目标目录。
    ///
    /// 文件 I/O 全部在 detached task 里跑：以前 `copyItem` 是在主线程同步执行的，
    /// 从「文件」导入几段 4K 会把整个界面冻住几十秒，看起来像卡死。
    ///
    /// 安全作用域在进后台任务之前就握住。`fileImporter` 与「用幕间打开」给的
    /// 都是 security-scoped URL，先握再拷，避免「异步之后才申请授权」的时序问题。
    static func bring(_ item: ImportItem, into target: URL) async -> ImportResult {
        let scoped = item.url.startAccessingSecurityScopedResource()
        let result = await Task.detached(priority: .userInitiated) {
            transfer(item, into: target)
        }.value
        if scoped { item.url.stopAccessingSecurityScopedResource() }
        return result
    }

    /// 同步搬运：校验扩展名 → 取不重名的落地路径 → 拷贝 / 移动
    private static func transfer(_ item: ImportItem, into target: URL) -> ImportResult {
        let fm = FileManager.default
        let preferred = item.preferredName ?? item.url.lastPathComponent
        let ext = (preferred as NSString).pathExtension.lowercased()

        // 扩展名不在白名单里，搬进来也不会出现在资料库——以前是「静默失败」，
        // 用户只看到「没有导入成功」，不知道该改什么。这里直接说清楚。
        guard !ext.isEmpty, VideoItem.videoExtensions.contains(ext) else {
            return ImportResult(
                total: 1, copied: 0, renamed: 0, failed: 1,
                reason: "「\(preferred)」不是支持的视频格式"
            )
        }

        let destination = fm.uniqueURL(in: target, preferredName: preferred)

        do {
            if item.moving {
                try fm.moveItem(at: item.url, to: destination)
            } else {
                try copy(from: item.url, to: destination)
            }
        } catch {
            return ImportResult(
                total: 1, copied: 0, renamed: 0, failed: 1,
                reason: error.localizedDescription
            )
        }

        let renamed = destination.lastPathComponent != preferred
        return ImportResult(
            total: 1, copied: 1, renamed: renamed ? 1 : 0, failed: 0,
            saved: [destination]
        )
    }

    /// 协调读取后拷贝。
    ///
    /// 直接 `copyItem` 有两种常见失败，正好就是「从文件导入不成功」的主因：
    /// 1. iCloud 云盘 / 第三方文件提供商（Documents、坚果云…）里的文件还没下载到本地，
    ///    必须先发起协调读，由提供商把内容准备好再交给 App；
    /// 2. 文件在别的 App 的容器里，只拿到安全作用域 URL 并不够，同样要走协调读。
    /// 本地普通文件走这条路也没问题，只是多一次协调开销。
    private static func copy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        var coordinationError: NSError?
        var copyError: Error?

        NSFileCoordinator().coordinate(
            readingItemAt: source,
            options: [.withoutChanges],
            error: &coordinationError
        ) { readable in
            do {
                try fm.copyItem(at: readable, to: destination)
            } catch {
                copyError = error
            }
        }

        // 落地了才算成功：协调失败时访问块可能压根没执行，不能只看错误变量
        if fm.fileExists(atPath: destination.path) { return }
        if let copyError { throw copyError }
        if let coordinationError { throw coordinationError }
        throw CocoaError(.fileReadUnknown)
    }
}
