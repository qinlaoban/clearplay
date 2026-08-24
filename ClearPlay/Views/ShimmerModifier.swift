import SwiftUI
import Accessibility

/// 骨架屏微光效果：应用内唯一允许的装饰动画（遵循 prefers-reduced-motion）
struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        Group {
            if reduceMotion {
                content.opacity(0.5)
            } else {
                content
                    .overlay {
                        GeometryReader { geo in
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.08), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * 1.6)
                            .onAppear {
                                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                                    phase = 1
                                }
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .clipped()
            }
        }
    }
}

extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}
