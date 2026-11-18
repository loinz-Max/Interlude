import SwiftUI

/// 四层玻璃配方（对应原型里的 .glass / .menu）：
///   1. .ultraThinMaterial 提供真实的背景模糊
///   2. 一层渐变染色，把材质压到合适的明度
///   3. 0.75pt 渐变描边，上沿亮、下沿几乎看不见
///   4. 外投影，让整块浮起来
struct GlassStyle {
    var top: Color
    var bottom: Color
    var strokeTop: Color
    var strokeBottom: Color
    var shadowRadius: CGFloat
    var shadowY: CGFloat
    var shadowOpacity: Double
    /// 菜单 / 抽屉 / 提示这类要压在内容上的玻璃。设置里的「界面通透度」
    /// 对它们保守一档：压得太透，背后的文字会浮上来干扰阅读。
    var isPanel: Bool = false

    /// 控件：按钮、运输胶囊、进度条胶囊
    /// 染色 alpha 压得越低越透；透明之后靠描边把边界找回来，这是玻璃感的关键。
    static let control = GlassStyle(
        top: Color.white.opacity(0.095),
        bottom: Color.white.opacity(0.028),
        strokeTop: Color.white.opacity(0.30),
        strokeBottom: Color.white.opacity(0.05),
        shadowRadius: 12,
        shadowY: 4,
        shadowOpacity: 0.26
    )

    /// 菜单、抽屉、弹窗
    static let panel = GlassStyle(
        top: Color.black.opacity(0.21),
        bottom: Color.black.opacity(0.31),
        strokeTop: Color.white.opacity(0.26),
        strokeBottom: Color.white.opacity(0.04),
        shadowRadius: 28,
        shadowY: 10,
        shadowOpacity: 0.40,
        isPanel: true
    )

    /// 播放页：压在视频画面上。浅色染色在亮画面上会糊掉，这里用暗色，
    /// 白图标才有对比度。
    static let stage = GlassStyle(
        top: Color.black.opacity(0.25),
        bottom: Color.black.opacity(0.35),
        strokeTop: Color.white.opacity(0.30),
        strokeBottom: Color.white.opacity(0.05),
        shadowRadius: 12,
        shadowY: 4,
        shadowOpacity: 0.32
    )

    /// 轻提示（toast / 倍速 / 导入进度）：比特意做小，比 stage 再透一档，
    /// 投影放大、染色降低，让它像浮在画面上而不是一块贴纸。
    static let hud = GlassStyle(
        top: Color.black.opacity(0.22),
        bottom: Color.black.opacity(0.32),
        strokeTop: Color.white.opacity(0.32),
        strokeBottom: Color.white.opacity(0.06),
        shadowRadius: 18,
        shadowY: 6,
        shadowOpacity: 0.34,
        isPanel: true
    )
}

// MARK: - 通透度

/// 玻璃浓淡系数。由设置里的「界面通透度」决定，1.0 就是原始配方。
/// 材质层与染色层同乘这个数，描边不乘——透明之后靠描边把边界找回来，
/// 否则整块玻璃会散在画面里。
struct GlassTuning: Equatable {
    var control: Double = 1
    var panel: Double = 1

    static let standard = GlassTuning(control: 1, panel: 1)
}

private struct GlassTuningKey: EnvironmentKey {
    static let defaultValue = GlassTuning.standard
}

extension EnvironmentValues {
    var glassTuning: GlassTuning {
        get { self[GlassTuningKey.self] }
        set { self[GlassTuningKey.self] = newValue }
    }
}

private struct GlassFill<S: InsettableShape>: View {
    let shape: S
    let style: GlassStyle

    @Environment(\.glassTuning) private var tuning

    /// 面板类走保守档，控件与胶囊照设置满档
    private var factor: Double {
        min(max(style.isPanel ? tuning.panel : tuning.control, 0), 1)
    }

    var body: some View {
        shape
            .fill(Material.ultraThinMaterial)
            // 材质本身也一起淡化：只压染色的话，那层提亮的雾还在，看着照样「实」
            .opacity(factor)
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [style.top, style.bottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(factor)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [style.strokeTop, style.strokeBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
            .compositingGroup()
            // 越透的玻璃越不该带重投影，否则看着脏
            .shadow(
                color: .black.opacity(style.shadowOpacity * (0.7 + 0.3 * factor)),
                radius: style.shadowRadius,
                y: style.shadowY
            )
    }
}

extension View {
    /// 给任意形状套上玻璃底。用法：`.glass(Circle())` / `.glass(RoundedRectangle(cornerRadius: 20, style: .continuous))`
    func glass<S: InsettableShape>(_ shape: S, style: GlassStyle = .control) -> some View {
        background { GlassFill(shape: shape, style: style) }
    }

    func glass(cornerRadius: CGFloat, style: GlassStyle = .panel) -> some View {
        glass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), style: style)
    }
}

// MARK: - 圆形图标按钮

struct GlassIconButton: View {
    let systemName: String
    var size: CGFloat = 36
    var iconSize: CGFloat = 16
    var weight: Font.Weight = .medium
    var style: GlassStyle = .control
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: weight))
                .foregroundStyle(Palette.text)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(Circle(), style: style)
    }
}
