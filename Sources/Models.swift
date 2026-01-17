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
        return cpuUtilization > 50 || 
               connectionsUsedPercent > 50 || 
               storageUsedPercent > 50 ||
               (currentConnections / Double(maxConnections) * 100) > 50
    }
    
    func getAlertMessage(instanceName: String) -> String? {
        var alerts: [String] = []
        
        if cpuUtilization > 50 {
            alerts.append("CPU: \(String(format: "%.0f", cpuUtilization))%")
        }
        if connectionsUsedPercent > 50 {
            alerts.append("Connections: \(String(format: "%.0f", connectionsUsedPercent))%")
        }
        if storageUsedPercent > 50 {
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
