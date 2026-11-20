import Foundation
import Combine

/// 「用幕间打开」的入口缓冲。
///
/// 在「文件」App（或其它 App 的「用其他应用打开」）里选幕间时，系统会走
/// document open 流程，最终落到 SwiftUI 的 `onOpenURL`。这里只做一件事：
/// 把 URL 先存下来。冷启动时 URL 可能比资料库视图先到，直接导入会丢；
/// 存下来之后由 `LibraryView` 在视图起来后取走。
@MainActor
final class OpenInbox: ObservableObject {
    static let shared = OpenInbox()

    @Published private(set) var pending: [URL] = []

    private init() {}

    func receive(_ url: URL) {
        // 只认文件 URL：外链（http / mailto）不是我们要导入的东西
        guard url.isFileURL else { return }
        // 同一个文件可能被系统送两次（冷启动时 scene 的连接选项与 openURLContexts
        // 各来一次），排一次队就够了，否则会导入出「名字 (2)」
        guard !pending.contains(url) else { return }
        pending.append(url)
        // 连点很多次也别无限堆积，留最近的一批就够
        if pending.count > 16 {
            pending.removeFirst(pending.count - 16)
        }
    }

    /// 取走排队中的文件。取走即清空，重复调用不会重复导入。
    func take() -> [URL] {
        guard !pending.isEmpty else { return [] }
        let urls = pending
        pending.removeAll()
        return urls
    }
}
