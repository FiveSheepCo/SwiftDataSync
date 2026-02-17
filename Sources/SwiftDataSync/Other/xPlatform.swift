import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class xPlatform {
    static func registerForNotifications() async {
        #if os(macOS)
        await NSApplication.shared.registerForRemoteNotifications()
        #else
        await UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
}
