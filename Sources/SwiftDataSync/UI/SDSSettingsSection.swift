import Foundation
import SwiftUI
import CloudKit

/// A section you can incorperate into your settings to show the state of sync and have a force sync button.
@MainActor
public struct SDSSettingsSection: View {
    var model = SDSSynchronizationViewModel.shared
    
    public init() {}
    
    public var body: some View {
        Section(header: Text("settings.sync", bundle: .module), footer: _Footer()) {
            Button {
                model.forceSync()
            } label: {
                Text("settings.sync.forceSyncButtonTitle", bundle: .module)
            }
            .foregroundColor(.accentColor)
            .disabled(model.forceSyncDisabled)
        }
    }
}

@MainActor
private struct _Footer: View {
    var model = SDSSynchronizationViewModel.shared
    
    var latestDateString: String? {
        guard let date = model.lastCompletionDate else {
            return nil
        }
        
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            switch model.state {
                case .waitingForSetup, .waitingForContainerDetection:
                    Text("sync.state.waitingForApp", bundle: .module)
                case .waitingForNetwork:
                    Text("sync.state.waitingForNetwork", bundle: .module)
                case .notLoggedIntoIcloud:
                    Text("sync.state.notLoggedIntoIcloud", bundle: .module)
                case .bootstrapping:
                    Text("sync.state.bootstrapping", bundle: .module)
                case .uploading, .downloading:
                    Text("sync.state.synchronizing", bundle: .module)
                case .idle:
                    Text("sync.state.lastSyncDate \(latestDateString ?? "never")", bundle: .module)
                case .error(let error):
                    NoticeView(kind: .problem, text: "sync.state.error \(String(describing: error))")
                case .processingSaveEvent:
                    Text("sync.state.processing", bundle: .module)
                case .savingShare:
                    Text("sync.state.savingShare", bundle: .module)
            }
            Text("sync.updatesToSend \(model.updatesToSend)")
        }
    }
}
