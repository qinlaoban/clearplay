import SwiftUI

/// ClearPlay 设计令牌：Apple TV 原生风
/// 全部使用系统语义色——跟随系统浅色/深色模式，accent 为系统强调色
extension Color {
    #if os(macOS)
    static let cpBackground = Color(nsColor: .windowBackgroundColor)
    /// 卡片/列表底色
    static let cpSurface = Color(nsColor: .underPageBackgroundColor)
    /// hover/高亮底色
    static let cpSurfaceHi = Color(nsColor: .controlBackgroundColor)
    #else
    static let cpBackground = Color(uiColor: .systemBackground)
    static let cpSurface = Color(uiColor: .secondarySystemBackground)
    static let cpSurfaceHi = Color(uiColor: .tertiarySystemBackground)
    #endif
    /// 主色 = 系统强调色（默认蓝，用户可在系统设置改）
    static let cpPrimary = Color.accentColor
    /// 行动色：仅用于"播放"类动作（原生风同样用系统强调色）
    static let cpCTA = Color.accentColor
    static let cpText = Color.primary
    static let cpTextSubtle = Color.secondary
}

/// 让 `.foregroundStyle(.cpXxx)` 简写可用
extension ShapeStyle where Self == Color {
    static var cpBackground: Color { .cpBackground }
    static var cpSurface: Color { .cpSurface }
    static var cpSurfaceHi: Color { .cpSurfaceHi }
    static var cpPrimary: Color { .cpPrimary }
    static var cpCTA: Color { .cpCTA }
    static var cpText: Color { .cpText }
    static var cpTextSubtle: Color { .cpTextSubtle }
}

/// 全局外观注入：前景色 + 强调色；不再强制暗色，跟随系统外观
struct CPThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.cpText)
            .tint(.cpPrimary)
    }
}

extension View {
    func cpTheme() -> some View { modifier(CPThemeModifier()) }
}
