import Foundation

struct RDSInstance {
    let identifier: String
    let engine: String
    let instanceClass: String
    let allocatedStorage: Int
    let maxConnections: Int
    let status: String
}

struct RDSMetrics {
    let cpuUtilization: Double
    let currentConnections: Double
    let connectionsUsedPercent: Double
    let storageUsedPercent: Double
    let freeStorageSpace: Double
    
    func hasAlert(maxConnections: Int) -> Bool {
        // Ignore -1 (N/A) values in alert checks
        let cpuAlert = cpuUtilization >= 0 && cpuUtilization > 50
        let connAlert = connectionsUsedPercent >= 0 && connectionsUsedPercent > 50
        let storageAlert = storageUsedPercent >= 0 && storageUsedPercent > 50
        let activityAlert = maxConnections > 0 && (currentConnections / Double(maxConnections) * 100) > 50
        
        return cpuAlert || connAlert || storageAlert || activityAlert
    }
    
    func getAlertMessage(instanceName: String) -> String? {
        var alerts: [String] = []
        
        if cpuUtilization >= 0 && cpuUtilization > 50 {
            alerts.append("CPU: \(String(format: "%.0f", cpuUtilization))%")
        }
        if connectionsUsedPercent >= 0 && connectionsUsedPercent > 50 {
            alerts.append("Connections: \(String(format: "%.0f", connectionsUsedPercent))%")
        }
        if storageUsedPercent >= 0 && storageUsedPercent > 50 {
            alerts.append("Storage: \(String(format: "%.0f", storageUsedPercent))%")
        }
        
        if alerts.isEmpty {
            return nil
        }
        
        return "⚠️ RDS Alert: \(instanceName)\n\(alerts.joined(separator: "\n"))"
    }
}

struct AlertState {
    let instanceId: String
    let timestamp: Date
    let alertingMetrics: Set<String>
}
