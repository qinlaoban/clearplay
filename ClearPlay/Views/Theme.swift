import SwiftUI

/// ClearPlay 设计令牌（见 docs/UI_DESIGN.md）：暗色沉浸影院风
extension Color {
    static let cpBackground = Color(red: 0x0F/255, green: 0x0F/255, blue: 0x23/255)
    static let cpSurface = Color(red: 0x1A/255, green: 0x19/255, blue: 0x30/255)
    static let cpSurfaceHi = Color(red: 0x23/255, green: 0x22/255, blue: 0x44/255)
    static let cpPrimary = Color(red: 0x43/255, green: 0x38/255, blue: 0xCA/255)
    /// 行动色：仅用于"播放"类动作
    static let cpCTA = Color(red: 0x22/255, green: 0xC5/255, blue: 0x5E/255)
    static let cpText = Color(red: 0xF8/255, green: 0xFA/255, blue: 0xFC/255)
    static let cpTextSubtle = Color(red: 0x94/255, green: 0xA3/255, blue: 0xB8/255)
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

/// 全局外观注入：暗色背景 + 前景色
struct CPThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.cpText)
            .tint(.cpPrimary)
            .preferredColorScheme(.dark)
    }
}

extension View {
    func cpTheme() -> some View { modifier(CPThemeModifier()) }
}
