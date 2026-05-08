import Foundation

/// Protocol for receiving clipboard monitoring events and providing configuration
protocol ClipboardMonitorDelegate: AnyObject {
    /// Returns the configured sensitive clear hours
    func sensitiveClearHoursForMonitor() -> Int
}
