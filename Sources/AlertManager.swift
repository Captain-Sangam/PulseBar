import Foundation
import AppKit
import UserNotifications

class AlertManager {
    private var activeAlerts: [String: AlertState] = [:]
    private var notificationsAvailable: Bool
    
    init() {
        // Check if we're running as a proper app bundle
        // UNUserNotificationCenter requires a valid bundle identifier
        notificationsAvailable = Bundle.main.bundleIdentifier != nil
    }
    
    func sendAlert(instanceId: String, message: String, metrics: RDSMetrics) {
        let currentMetrics = getAlertingMetrics(metrics: metrics)
        
        // Check if we already have an alert for this instance
        if let existingAlert = activeAlerts[instanceId] {
            // Only send notification if:
            // 1. Different metrics are alerting
            // 2. Or it's been more than 15 minutes since last alert
            let timeSinceLastAlert = Date().timeIntervalSince(existingAlert.timestamp)
            
            if currentMetrics != existingAlert.alertingMetrics || timeSinceLastAlert > 900 {
                sendNotification(message: message)
                updateAlertState(instanceId: instanceId, metrics: currentMetrics)
            }
        } else {
            // New alert
            sendNotification(message: message)
            updateAlertState(instanceId: instanceId, metrics: currentMetrics)
        }
    }
    
    func clearAlert(instanceId: String) {
        activeAlerts.removeValue(forKey: instanceId)
    }
    
    private func updateAlertState(instanceId: String, metrics: Set<String>) {
        activeAlerts[instanceId] = AlertState(
            instanceId: instanceId,
            timestamp: Date(),
            alertingMetrics: metrics
        )
    }
    
    private func getAlertingMetrics(metrics: RDSMetrics) -> Set<String> {
        var alerting = Set<String>()
        let threshold = Settings.shared.alertThreshold

        // Ignore -1 (N/A) values
        if metrics.cpuUtilization >= 0 && metrics.cpuUtilization > threshold {
            alerting.insert("cpu")
        }
        if metrics.connectionsUsedPercent >= 0 && metrics.connectionsUsedPercent > threshold {
            alerting.insert("connections")
        }
        if metrics.storageUsedPercent >= 0 && metrics.storageUsedPercent > threshold {
            alerting.insert("storage")
        }

        return alerting
    }
    
    private func sendNotification(message: String) {
        // Always log the alert to console.
        print("🚨 ALERT: \(message)")

        // Preferred path: UNUserNotificationCenter, which requires a code-signed app bundle
        // with a valid bundle identifier. When that's unavailable (e.g. `swift run`, or an
        // unsigned local build), fall back to NSUserNotification so alerts still surface.
        if notificationsAvailable {
            let content = UNMutableNotificationContent()
            content.title = "PulseBar - RDS Alert"
            content.body = message
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil // Send immediately
            )

            UNUserNotificationCenter.current().add(request) { [weak self] error in
                if let error = error {
                    print("UNUserNotificationCenter failed (\(error)); falling back.")
                    self?.sendLegacyNotification(message: message)
                }
            }
        } else {
            sendLegacyNotification(message: message)
        }
    }

    /// Fallback delivery via the older NSUserNotification API, which works without a
    /// notification entitlement or code signature — so alerts appear even for local builds.
    private func sendLegacyNotification(message: String) {
        let notification = NSUserNotification()
        notification.title = "PulseBar - RDS Alert"
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
}
