import SwiftUI

/// ClearPlay 设计令牌：沉浸式深色 + 中性白强调
/// 影视类 App 让彩色海报当主角，UI 框架退到中性；强调色用白而非系统蓝。
extension Color {
    // MARK: - 背景层级（white-opacity 体系，天然适配深色，iOS/macOS 一致）

    /// 最底层近黑背景
    static let cpBackground = Color(white: 0.04)
    /// 卡片 / 列表底色
    static let cpSurface = Color(white: 0.08)
    /// hover / 高亮 / 次级表面
    static let cpSurfaceHi = Color(white: 0.12)
    /// 浮起 / 弹层表面
    static let cpElevated = Color(white: 0.16)
    /// 列表选中高亮（中性灰，彻底去蓝）
    static let cpSelection = Color.white.opacity(0.18)

    // MARK: - 文本

    static let cpText = Color.white
    static let cpTextSubtle = Color.white.opacity(0.6)
    static let cpTextFaint = Color.white.opacity(0.38)

    // MARK: - 强调（中性白，替代系统蓝）

    /// 通用强调色：图标 / 链接
    static let cpPrimary = Color.white
    /// 行动色：仅用于"播放"类动作
    static let cpCTA = Color.white

    // MARK: - 分隔线

    static let cpDivider = Color.white.opacity(0.08)
}

/// 让 `.foregroundStyle(.cpXxx)` 简写可用
extension ShapeStyle where Self == Color {
    static var cpBackground: Color { .cpBackground }
    static var cpSurface: Color { .cpSurface }
    static var cpSurfaceHi: Color { .cpSurfaceHi }
    static var cpElevated: Color { .cpElevated }
    static var cpSelection: Color { .cpSelection }
    static var cpPrimary: Color { .cpPrimary }
    static var cpCTA: Color { .cpCTA }
    static var cpText: Color { .cpText }
    static var cpTextSubtle: Color { .cpTextSubtle }
    static var cpTextFaint: Color { .cpTextFaint }
    static var cpDivider: Color { .cpDivider }
}

/// 字体类型系统：替代散落的魔法数字（后续视图逐步迁移到此）
extension Font {
    static let cpTitle = Font.system(size: 28, weight: .bold)
    static let cpHeading = Font.system(size: 20, weight: .semibold)
    static let cpBody = Font.system(size: 13, weight: .regular)
    static let cpBodyMed = Font.system(size: 13, weight: .medium)
    static let cpSmall = Font.system(size: 12, weight: .regular)
    static let cpCaption = Font.system(size: 11, weight: .regular)
}

/// 圆角 / 间距设计常量
enum CPMetrics {
    static let radius: CGFloat = 10
    static let radiusSm: CGFloat = 8
    static let gap: CGFloat = 16
    static let pad: CGFloat = 24
}

/// 全局外观注入：前景色；交互高亮 tint 用中性灰选中色（彻底去除系统蓝），
/// 不再让任何品牌 / CTA 使用蓝色。
struct CPThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.cpText)
            .tint(.cpSelection)
    }
}

extension View {
    func cpTheme() -> some View { modifier(CPThemeModifier()) }
}
