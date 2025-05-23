import SwiftUI

@MainActor
public struct SDSSharingProgressView<Content: View>: View {
    @Bindable var viewModel = SDSSynchronizationViewModel.shared
    
    private let content: () -> Content
    
    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
    
    public var body: some View {
        PopoverView(popoverActive: .constant(viewModel.isSavingShare), content: content) {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100)
                Text("sharing.uploadingPopover.text", bundle: .module)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
