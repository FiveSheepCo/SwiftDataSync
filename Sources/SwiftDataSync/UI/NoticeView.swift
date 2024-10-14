import SwiftUI

public struct NoticeView: View {
    
    public enum Kind {
        case problem
        case warning
        
        var imageName: String {
            switch self {
            case .problem:
                return "exclamationmark.circle.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
            }
        }
        
        var imageColor: Color {
            switch self {
            case .problem:
                return .red
            case .warning:
                return .yellow
            }
        }
    }
    
    let kind : Kind
    
    let text: LocalizedStringKey
    let buttonConfiguration: (text: LocalizedStringKey, action: SimpleBlock)?
    
    public init(
        kind: NoticeView.Kind,
        text: LocalizedStringKey,
        buttonConfiguration: (text: LocalizedStringKey, action: SimpleBlock)? = nil
    ) {
        self.kind = kind
        self.text = text
        self.buttonConfiguration = buttonConfiguration
    }
    
    public var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: kind.imageName)
                    .foregroundColor(kind.imageColor)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(text, bundle: .module)
                if buttonConfiguration != nil {
                    Button(action: {
                        self.buttonConfiguration!.action()
                    }) {
                        Text(buttonConfiguration!.text, bundle: .module)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }
}
