import SwiftUI

struct PopoverView<Content: View, Popover: View>: View {
    @Binding var popoverActive: Bool
    var content: () -> Content
    var popover: () -> Popover
    
    init(
        popoverActive: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder popover: @escaping () -> Popover
    ) {
        self._popoverActive = popoverActive
        self.content = content
        self.popover = popover
    }
    
    var body: some View {
        Group {
            if popoverActive {
                ZStack(alignment: .center) {
                    content()
                        .allowsHitTesting(false)
                        .opacity(0.6)
                        .zIndex(1)
                    popover()
                        .padding(.all, 50)
                        #if os(iOS)
                        .background(Blur(style: .regular))
                        #endif
                        .cornerRadius(10)
                        .shadow(radius: 25)
                        .opacity(0.9)
                        .transition(.opacity)
                        .zIndex(3)
                }
            } else {
                content()
            }
        }
    }
}

#if os(iOS)
struct Blur: UIViewRepresentable {
    let style: UIBlurEffect.Style
    
    init(style: UIBlurEffect.Style) {
        self.style = style
    }

    func makeUIView(context: Context) -> UIVisualEffectView {
        return UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
#endif
