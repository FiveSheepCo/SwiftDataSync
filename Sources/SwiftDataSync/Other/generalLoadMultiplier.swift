import Foundation
import Network
#if os(iOS)
import UIKit
#endif

/// How much longer than usual routine synchronizations wait, e.g. on battery or a cellular connection.
@MainActor
func generalLoadMultiplier(networkMonitor: NWPathMonitor?) -> TimeInterval {
    var multiplier: TimeInterval = 1
    
    #if os(macOS)
    let isUnplugged:Bool = false // TODO(later): This
    let batteryLevel: TimeInterval = 1
    #else
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    
    let batteryLevel: TimeInterval = TimeInterval(device.batteryLevel)
    let isUnplugged:Bool = device.batteryState == .unplugged
    #endif
    multiplier *= isUnplugged ? 1/max(0.01, sqrt(batteryLevel)) : 1
    multiplier *= ProcessInfo.processInfo.isLowPowerModeEnabled ? 3 : 1
    multiplier *= networkMonitor?.currentPath.usesInterfaceType(.cellular) == true ? 3 : 1
    
    return multiplier
}
