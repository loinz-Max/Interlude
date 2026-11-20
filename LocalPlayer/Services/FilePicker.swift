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
            completion([])
            return
        }
        // 已经有一个呈现挂在上面时不要再叠：连点两下不该弹出两个选择器
        guard host.presentedViewController == nil else { return }

        self.completion = completion

        // asCopy 必须为 true。
        //
        // 用 false（原地打开）时，系统需要为选中的文件签发一条沙盒扩展；签不出来
        // 就会把"点打开"当成"取消"——真机上表现为 documentPickerWasCancelled 而不是
        // didPickDocumentsAt，界面看起来就是"选了没反应"。日志里已经实测到这一点
        // （点「打开」→ 回调 B2 取消）。
        //
        // asCopy: true 由系统先把文件复制到我们的 tmp 目录，拿到的是自己容器里的
        // 普通文件，不需要任何权限协商。
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.movie, .video],
            asCopy: true
        )
        picker.delegate = self
        // 多选必须在 present 之前设好。真机上在 present 之后再设，
        // 选择器里不会出现「选择」这一步，只能一个一个文件挑。
        picker.allowsMultipleSelection = true
        host.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let done = completion
        completion = nil
        // 大多数系统版本会自己收回；这里再兜一次，免得停在原地让人以为没选中
        controller.presentingViewController?.dismiss(animated: true)
        done?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
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
