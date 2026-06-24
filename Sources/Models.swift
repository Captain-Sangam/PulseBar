import Foundation

/// Represents the current state of the monitoring service
enum MonitoringState: Equatable {
    /// Initial state or currently fetching data
    case loading
    
    /// Successfully loaded instances (may be empty)
    case loaded
    
    /// AWS credentials file (~/.aws/credentials) not found
    case noCredentials
    
    /// Credentials exist but are invalid, expired, or lack permissions
    case invalidCredentials(message: String)
    
    /// Connected successfully but no RDS instances found in the selected region
    case noDatabases
    
    /// A general error occurred
    case error(message: String)
}

struct RDSInstance {
    let identifier: String
    let engine: String
    let instanceClass: String
    let allocatedStorage: Int
    let maxConnections: Int
    let status: String

    /// DbiResourceId (e.g. "db-ABCD…") — Performance Insights APIs key on this, not the identifier.
    let dbiResourceId: String?

    /// Whether Performance Insights is enabled for this instance.
    let performanceInsightsEnabled: Bool

    /// If this instance is a read replica, the identifier of its source (primary) instance.
    let readReplicaSource: String?

    /// True when this instance is a read replica of another instance.
    var isReadReplica: Bool { readReplicaSource != nil }
}

struct RDSMetrics {
    let cpuUtilization: Double
    let currentConnections: Double
    let connectionsUsedPercent: Double
    let storageUsedPercent: Double
    let freeStorageSpace: Double

    /// Average active sessions (CloudWatch `DBLoad`). `-1` when Performance Insights is disabled
    /// or no datapoint is available — callers fall back to `currentConnections`.
    let dbLoad: Double

    /// Read-replica lag in seconds (CloudWatch `ReplicaLag`). `-1` for non-replicas / no data.
    let replicaLag: Double

    func hasAlert(maxConnections: Int) -> Bool {
        // Ignore -1 (N/A) values in alert checks. Threshold is user-configurable (default 50%).
        let threshold = Settings.shared.alertThreshold
        let cpuAlert = cpuUtilization >= 0 && cpuUtilization > threshold
        let connAlert = connectionsUsedPercent >= 0 && connectionsUsedPercent > threshold
        let storageAlert = storageUsedPercent >= 0 && storageUsedPercent > threshold
        let activityAlert = maxConnections > 0 && (currentConnections / Double(maxConnections) * 100) > threshold

        return cpuAlert || connAlert || storageAlert || activityAlert
    }

    func getAlertMessage(instanceName: String) -> String? {
        let threshold = Settings.shared.alertThreshold
        var alerts: [String] = []

        if cpuUtilization >= 0 && cpuUtilization > threshold {
            alerts.append("CPU: \(String(format: "%.0f", cpuUtilization))%")
        }
        if connectionsUsedPercent >= 0 && connectionsUsedPercent > threshold {
            alerts.append("Connections: \(String(format: "%.0f", connectionsUsedPercent))%")
        }
        if storageUsedPercent >= 0 && storageUsedPercent > threshold {
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

// MARK: - Detail dashboard time-series

/// A selectable time window for the detail dashboard. The period is chosen so each
/// series stays well under CloudWatch GetMetricData's 1440-datapoint-per-query cap.
enum MetricRange: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    /// Short label for the segmented picker.
    var title: String {
        switch self {
        case .day: return "1D"
        case .week: return "7D"
        case .month: return "30D"
        }
    }

    /// Length of the window in seconds.
    var seconds: TimeInterval {
        switch self {
        case .day: return 86_400        // 24h
        case .week: return 604_800      // 7d
        case .month: return 2_592_000   // 30d
        }
    }

    /// CloudWatch aggregation period in seconds.
    var period: Int {
        switch self {
        case .day: return 300       // 5 min  → ~288 points
        case .week: return 3_600    // 1 hr   → ~168 points
        case .month: return 21_600  // 6 hr   → ~120 points
        }
    }
}

/// A single (timestamp, value) sample. `Identifiable` so it can back a SwiftUI Chart.
struct MetricPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

/// How a metric's values should be rendered.
enum MetricUnit {
    case percent
    case bytesToGB
    case bytesToMB
    case count
    case countPerSec

    /// Format a raw CloudWatch value for axis labels and tooltips.
    func format(_ v: Double) -> String {
        switch self {
        case .percent:
            return String(format: "%.1f%%", v)
        case .bytesToGB:
            return String(format: "%.1f GB", v / 1_073_741_824)
        case .bytesToMB:
            return String(format: "%.0f MB", v / 1_048_576)
        case .count:
            return String(format: "%.2f", v)
        case .countPerSec:
            return String(format: "%.0f/s", v)
        }
    }

    /// Convert a raw value into the unit the chart's Y axis is drawn in.
    func axisValue(_ v: Double) -> Double {
        switch self {
        case .bytesToGB: return v / 1_073_741_824
        case .bytesToMB: return v / 1_048_576
        default: return v
        }
    }

    /// Short label for the chart's Y axis (the unit the axis values are drawn in).
    var axisLabel: String {
        switch self {
        case .percent: return "%"
        case .bytesToGB: return "GB"
        case .bytesToMB: return "MB"
        case .count: return "count"
        case .countPerSec: return "ops/sec"
        }
    }
}

/// One named, ordered (ascending-by-time) series for a single chart line.
struct MetricSeries {
    let displayName: String
    let unit: MetricUnit
    let points: [MetricPoint]

    var isEmpty: Bool { points.isEmpty }
}

/// All series needed to render the six detail-dashboard charts for one instance.
struct InstanceTimeSeries {
    let cpuUtilization: MetricSeries
    let dbLoad: MetricSeries
    let freeableMemory: MetricSeries
    let swapUsage: MetricSeries
    let freeStorageSpace: MetricSeries
    let readIOPS: MetricSeries
    let writeIOPS: MetricSeries
}

// MARK: - Performance Insights

/// A single ranked row in a "Top …" panel (query text / user / host) with its average active sessions.
struct TopItem: Identifiable {
    let id = UUID()
    let label: String
    let load: Double
    /// For Top Queries rows, the Performance Insights tokenized-digest id (db.sql_tokenized.id).
    /// Used to drill into the individual SQL statements and load-over-time for this query.
    /// nil for users / hosts (and queries where PI didn't return an id).
    var digestId: String? = nil
}

// MARK: - Query drill-down (Top SQL → invocations)

/// The per-query drill-down shown when a Top Query is opened in its own window:
/// load over time for the digest, the individual SQL statements behind it, and the
/// users / hosts that ran it. Mirrors the RDS console's Top SQL detail view.
struct QueryDetail {
    /// The tokenized digest text (the query with literals replaced by `?`).
    let digestText: String
    /// db.load.avg over time, filtered to this query digest.
    let loadOverTime: MetricSeries
    /// Individual full SQL statements that rolled up into this digest, ranked by load.
    let statements: [SQLStatement]
    /// Users that ran this query, ranked by load.
    let topUsers: [TopItem]
    /// Hosts that ran this query, ranked by load.
    let topHosts: [TopItem]
}

/// One concrete SQL statement behind a digest. `fullText` is fetched lazily when the row is opened.
struct SQLStatement: Identifiable {
    let id = UUID()
    /// db.sql.id — the Performance Insights hash of the full statement, used to fetch its full text.
    let statementId: String?
    /// The (possibly truncated) statement text returned alongside the dimension key.
    let previewText: String
    let load: Double
}

/// Performance Insights breakdowns shown beneath the charts.
struct PerformanceInsightsData {
    let enabled: Bool
    let topQueries: [TopItem]
    let topUsers: [TopItem]
    let topHosts: [TopItem]

    static let disabled = PerformanceInsightsData(enabled: false, topQueries: [], topUsers: [], topHosts: [])
}
