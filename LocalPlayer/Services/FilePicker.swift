import UIKit
import UniformTypeIdentifiers

/// 「从文件导入」的选择器。
///
/// 没有用 SwiftUI 的 `.fileImporter`。它的完成回调挂在呈现它的那个视图的协调器上，
/// 而这个视图会在导入菜单关闭、资料库重扫、切换文件夹时反复重建；协调器一换，
/// 已经弹出来的选择器就成了没人接线的孤儿——选完点「打开」既不报错也不回调，
/// 界面停在原地。这正是「点导入 → 选视频 → 点打开 → 没反应」的由来。
/// （前两轮改的是拷贝逻辑本身，那条路其实没走到。）
///
/// 这里改成由单例直接持有 `UIDocumentPickerViewController` 和它的委托，
/// 呈现 / 回调 / 收场都在一个不受视图重建影响的对象里完成。
final class FilePicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FilePicker()

    /// 正在进行的那一次选择；nil 表示当前没有选择器在用
    private var completion: (([URL]) -> Void)?

    private override init() { super.init() }

    /// 弹出选择器。回调在主线程；取消时回调空数组。
    func present(completion: @escaping ([URL]) -> Void) {
        guard let host = Self.topViewController() else {
            ImportLog.write("A1 呈现失败：找不到可用的宿主控制器")
            completion([])
            return
        }
        // 已经有一个呈现挂在上面时不要再叠：连点两下不该弹出两个选择器
        guard host.presentedViewController == nil else {
            ImportLog.write("A1 放弃呈现：宿主上已有呈现 \(type(of: host.presentedViewController!))")
            return
        }
        ImportLog.write("A1 准备呈现，宿主 = \(type(of: host))")

        self.completion = completion

        // asCopy: false —— 拿安全作用域 URL 自己拷，避免系统先替我们拷一份大的
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.movie, .video, .item],
            asCopy: false
        )
        picker.delegate = self
        picker.allowsMultipleSelection = true
        host.present(picker, animated: true) {
            ImportLog.write("A2 选择器已上屏")
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        ImportLog.write("B1 didPickDocumentsAt：\(urls.count) 个")
        for url in urls {
            let exists = FileManager.default.fileExists(atPath: url.path)
            ImportLog.write("     · \(url.lastPathComponent) 存在=\(exists)")
        }
        let done = completion
        completion = nil
        // 大多数系统版本会自己收回；这里再兜一次，免得停在原地让人以为没选中
        controller.presentingViewController?.dismiss(animated: true)
        done?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        ImportLog.write("B2 documentPickerWasCancelled（用户取消）")
        completion = nil
    }

    /// 从当前窗口找最上层的控制器：资料库页之上可能还压着相册选择器之类，
    /// 直接拿 root 去 present 会失败。
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
