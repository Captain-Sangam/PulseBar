import Foundation
import AWSRDS
import AWSCloudWatch
import AWSPI
import ClientRuntime
import AWSClientRuntime
import AwsCommonRuntimeKit

class RDSMonitoringService {
    var currentProfile: String = "default"
    var currentRegion: String = "us-west-2"  // Default to us-west-2 for testing
    var instances: [RDSInstance] = []
    var metricsCache: [String: RDSMetrics] = [:]
    var lastUpdateTime: Date?
    var state: MonitoringState = .loading
    
    private var alertManager = AlertManager()
    
    func refresh() async {
        state = .loading
        
        // Check if credentials file exists
        guard AWSCredentialsReader.shared.credentialsFileExists() else {
            state = .noCredentials
            print("❌ AWS credentials file not found at ~/.aws/credentials")
            return
        }
        
        // Check if profile has valid credentials
        guard AWSCredentialsReader.shared.hasCredentials(profile: currentProfile) else {
            state = .invalidCredentials(message: "Profile '\(currentProfile)' not found or missing keys")
            print("❌ No credentials found for profile: \(currentProfile)")
            return
        }
        
        do {
            // Fetch RDS instances
            try await fetchRDSInstances()
            
            // Check if we found any instances
            if instances.isEmpty {
                state = .noDatabases
                lastUpdateTime = Date()
                print("ℹ️ No RDS instances found in \(currentRegion)")
                return
            }
            
            // Fetch metrics for each instance
            try await fetchMetrics()
            
            // Check for alerts
            checkAlerts()
            
            state = .loaded
            lastUpdateTime = Date()
        } catch {
            // Check for common AWS auth errors
            let errorString = String(describing: error).lowercased()
            let errorMessage = (error as NSError).localizedDescription.lowercased()
            
            // Check both the error description and the full error string for auth-related patterns
            let isAuthError = [errorString, errorMessage].contains { msg in
                msg.contains("security token") ||
                msg.contains("expired") ||
                msg.contains("invalid") ||
                msg.contains("signature") ||
                msg.contains("credentials") ||
                msg.contains("access denied") ||
                msg.contains("not authorized") ||
                msg.contains("unknownawshttpserviceerror") ||  // Common auth failure
                msg.contains("authfailure") ||
                msg.contains("unauthorized")
            }
            
            if isAuthError {
                state = .invalidCredentials(message: "Credentials may be expired or invalid")
                print("❌ AWS authentication error: \(error)")
            } else {
                state = .error(message: (error as NSError).localizedDescription)
                print("❌ Error refreshing data: \(error)")
            }
        }
    }
    
    private func fetchRDSInstances() async throws {
        let client = try await createRDSClient()
        
        let input = DescribeDBInstancesInput()
        let response = try await client.describeDBInstances(input: input)
        
        var newInstances: [RDSInstance] = []
        
        if let dbInstances = response.dbInstances {
            for db in dbInstances {
                guard let identifier = db.dbInstanceIdentifier,
                      let engine = db.engine,
                      let instanceClass = db.dbInstanceClass,
                      let status = db.dbInstanceStatus else {
                    continue
                }
                
                let allocatedStorage = Int(db.allocatedStorage ?? 0)

                // Estimate max connections based on instance class
                // This is a simplified estimation - in production, you'd query parameter groups
                let maxConnections = estimateMaxConnections(instanceClass: instanceClass)

                let instance = RDSInstance(
                    identifier: identifier,
                    engine: engine,
                    instanceClass: instanceClass,
                    allocatedStorage: allocatedStorage,
                    maxConnections: maxConnections,
                    status: status,
                    dbiResourceId: db.dbiResourceId,
                    performanceInsightsEnabled: db.performanceInsightsEnabled ?? false,
                    readReplicaSource: db.readReplicaSourceDBInstanceIdentifier
                )
                
                newInstances.append(instance)
            }
        }
        
        instances = newInstances
    }
    
    private func fetchMetrics() async throws {
        let client = try await createCloudWatchClient()
        let now = Date()
        let startTime = now.addingTimeInterval(-3600) // 1 hour ago (ensures we get data)
        
        for instance in instances {
            do {
                let metrics = try await fetchInstanceMetrics(
                    client: client,
                    instanceId: instance.identifier,
                    startTime: startTime,
                    endTime: now,
                    allocatedStorage: instance.allocatedStorage,
                    maxConnections: instance.maxConnections
                )
                metricsCache[instance.identifier] = metrics
            } catch {
                print("Error fetching metrics for \(instance.identifier): \(error)")
            }
        }
    }
    
    private func fetchInstanceMetrics(
        client: CloudWatchClient,
        instanceId: String,
        startTime: Date,
        endTime: Date,
        allocatedStorage: Int,
        maxConnections: Int
    ) async throws -> RDSMetrics {
        // Create metric data queries
        var queries: [CloudWatchClientTypes.MetricDataQuery] = []
        
        // CPU Utilization
        queries.append(CloudWatchClientTypes.MetricDataQuery(
            id: "cpu",
            metricStat: CloudWatchClientTypes.MetricStat(
                metric: CloudWatchClientTypes.Metric(
                    dimensions: [
                        CloudWatchClientTypes.Dimension(name: "DBInstanceIdentifier", value: instanceId)
                    ],
                    metricName: "CPUUtilization",
                    namespace: "AWS/RDS"
                ),
                period: 300,
                stat: "Average"
            )
        ))
        
        // Database Connections
        queries.append(CloudWatchClientTypes.MetricDataQuery(
            id: "connections",
            metricStat: CloudWatchClientTypes.MetricStat(
                metric: CloudWatchClientTypes.Metric(
                    dimensions: [
                        CloudWatchClientTypes.Dimension(name: "DBInstanceIdentifier", value: instanceId)
                    ],
                    metricName: "DatabaseConnections",
                    namespace: "AWS/RDS"
                ),
                period: 300,
                stat: "Average"
            )
        ))
        
        // Free Storage Space (use longer period and Average - CloudWatch may not report every 5 min)
        queries.append(CloudWatchClientTypes.MetricDataQuery(
            id: "storage",
            metricStat: CloudWatchClientTypes.MetricStat(
                metric: CloudWatchClientTypes.Metric(
                    dimensions: [
                        CloudWatchClientTypes.Dimension(name: "DBInstanceIdentifier", value: instanceId)
                    ],
                    metricName: "FreeStorageSpace",
                    namespace: "AWS/RDS"
                ),
                period: 3600,  // 1 hour period - more likely to have aggregated data
                stat: "Average"
            )
        ))

        // DB Load (average active sessions) — only reports when Performance Insights is enabled.
        queries.append(CloudWatchClientTypes.MetricDataQuery(
            id: "dbload",
            metricStat: CloudWatchClientTypes.MetricStat(
                metric: CloudWatchClientTypes.Metric(
                    dimensions: [
                        CloudWatchClientTypes.Dimension(name: "DBInstanceIdentifier", value: instanceId)
                    ],
                    metricName: "DBLoad",
                    namespace: "AWS/RDS"
                ),
                period: 300,
                stat: "Average"
            )
        ))

        // Replica lag (seconds) — only reports for read replicas.
        queries.append(CloudWatchClientTypes.MetricDataQuery(
            id: "replicalag",
            metricStat: CloudWatchClientTypes.MetricStat(
                metric: CloudWatchClientTypes.Metric(
                    dimensions: [
                        CloudWatchClientTypes.Dimension(name: "DBInstanceIdentifier", value: instanceId)
                    ],
                    metricName: "ReplicaLag",
                    namespace: "AWS/RDS"
                ),
                period: 300,
                stat: "Average"
            )
        ))

        let input = GetMetricDataInput(
            endTime: endTime,
            metricDataQueries: queries,
            startTime: startTime
        )
        
        let response = try await client.getMetricData(input: input)
        
        // Parse results
        var cpuUtilization: Double = 0
        var currentConnections: Double = 0
        var freeStorageSpace: Double = 0
        var dbLoad: Double = -1  // -1 = N/A (Performance Insights disabled / no datapoint)
        var replicaLag: Double = -1  // -1 = N/A (not a replica / no datapoint)

        // Parse CloudWatch response

        if let results = response.metricDataResults {
            for result in results {
                if let values = result.values, !values.isEmpty {
                    // Use the FIRST value (most recent) - CloudWatch returns newest first
                    let value = values[0]

                    switch result.id {
                    case "cpu":
                        cpuUtilization = value
                    case "connections":
                        currentConnections = value
                    case "storage":
                        freeStorageSpace = value
                    case "dbload":
                        dbLoad = value
                    case "replicalag":
                        replicaLag = value
                    default:
                        break
                    }
                }
            }
        }
        
        
        // Calculate derived metrics
        let connectionsUsedPercent = maxConnections > 0 
            ? (currentConnections / Double(maxConnections)) * 100 
            : 0
        
        // FreeStorageSpace is in bytes, AllocatedStorage is in GiB
        let allocatedStorageBytes = Double(allocatedStorage) * 1024 * 1024 * 1024
        
        // If we didn't get free storage data, default to showing 0% used (unknown)
        var storageUsedPercent: Double = 0
        if freeStorageSpace > 0 && allocatedStorageBytes > 0 {
            let usedStorageBytes = allocatedStorageBytes - freeStorageSpace
            storageUsedPercent = (usedStorageBytes / allocatedStorageBytes) * 100
        } else if allocatedStorageBytes > 0 && freeStorageSpace == 0 {
            // No data from CloudWatch - show as unknown (-1 will display as "N/A")
            storageUsedPercent = -1
        }
        
        print("   Storage Used: \(storageUsedPercent)%")
        
        return RDSMetrics(
            cpuUtilization: cpuUtilization,
            currentConnections: currentConnections,
            connectionsUsedPercent: max(0, min(100, connectionsUsedPercent)),
            storageUsedPercent: storageUsedPercent == -1 ? -1 : max(0, min(100, storageUsedPercent)),
            freeStorageSpace: freeStorageSpace,
            dbLoad: dbLoad,
            replicaLag: replicaLag
        )
    }
    
    private func checkAlerts() {
        for instance in instances {
            guard let metrics = metricsCache[instance.identifier] else {
                continue
            }
            
            if metrics.hasAlert(maxConnections: instance.maxConnections) {
                if let message = metrics.getAlertMessage(instanceName: instance.identifier) {
                    alertManager.sendAlert(instanceId: instance.identifier, message: message, metrics: metrics)
                }
            } else {
                // Clear alert if metrics are back to normal
                alertManager.clearAlert(instanceId: instance.identifier)
            }
        }
    }
    
    func getMetrics(for instanceId: String) -> RDSMetrics? {
        return metricsCache[instanceId]
    }

    /// Instances whose metrics currently breach the alert threshold, with a short reason string.
    /// Surfaced in the menu so alerts are visible even when OS notifications are suppressed.
    func alertingInstances() -> [(instance: RDSInstance, reason: String)] {
        instances.compactMap { instance in
            guard let metrics = metricsCache[instance.identifier],
                  metrics.hasAlert(maxConnections: instance.maxConnections),
                  let message = metrics.getAlertMessage(instanceName: instance.identifier) else {
                return nil
            }
            // getAlertMessage prefixes a header line; keep just the metric lines for a compact reason.
            let reason = message
                .split(separator: "\n")
                .dropFirst()
                .joined(separator: ", ")
            return (instance, reason)
        }
    }

    func instance(for instanceId: String) -> RDSInstance? {
        return instances.first { $0.identifier == instanceId }
    }

    // MARK: - Detail dashboard time-series

    /// Fetches the six dashboard metrics as time-series for a single instance over the given range.
    /// Issues one GetMetricData call covering all metrics; empty series are returned for metrics
    /// with no datapoints (e.g. DBLoad when Performance Insights is disabled).
    func fetchTimeSeries(instanceId: String, range: MetricRange) async throws -> InstanceTimeSeries {
        let client = try await createCloudWatchClient()
        let now = Date()
        let startTime = now.addingTimeInterval(-range.seconds)
        let period = range.period

        func metricQuery(_ id: String, _ metricName: String) -> CloudWatchClientTypes.MetricDataQuery {
            CloudWatchClientTypes.MetricDataQuery(
                id: id,
                metricStat: CloudWatchClientTypes.MetricStat(
                    metric: CloudWatchClientTypes.Metric(
                        dimensions: [
                            CloudWatchClientTypes.Dimension(name: "DBInstanceIdentifier", value: instanceId)
                        ],
                        metricName: metricName,
                        namespace: "AWS/RDS"
                    ),
                    period: period,
                    stat: "Average"
                )
            )
        }

        let queries: [CloudWatchClientTypes.MetricDataQuery] = [
            metricQuery("cpu", "CPUUtilization"),
            metricQuery("dbload", "DBLoad"),
            metricQuery("memfree", "FreeableMemory"),
            metricQuery("swap", "SwapUsage"),
            metricQuery("storage", "FreeStorageSpace"),
            metricQuery("riops", "ReadIOPS"),
            metricQuery("wiops", "WriteIOPS")
        ]

        let input = GetMetricDataInput(
            endTime: now,
            // Ask CloudWatch for oldest-first so the chart X axis reads left-to-right.
            metricDataQueries: queries,
            scanBy: .timestampAscending,
            startTime: startTime
        )

        let response = try await client.getMetricData(input: input)

        // Map query id -> ascending [MetricPoint]
        var pointsById: [String: [MetricPoint]] = [:]
        if let results = response.metricDataResults {
            for result in results {
                guard let id = result.id,
                      let timestamps = result.timestamps,
                      let values = result.values else { continue }
                let paired = zip(timestamps, values).map { MetricPoint(timestamp: $0, value: $1) }
                pointsById[id] = paired.sorted { $0.timestamp < $1.timestamp }
            }
        }

        func series(_ id: String, _ name: String, _ unit: MetricUnit) -> MetricSeries {
            MetricSeries(displayName: name, unit: unit, points: pointsById[id] ?? [])
        }

        return InstanceTimeSeries(
            cpuUtilization: series("cpu", "CPU Utilization", .percent),
            dbLoad: series("dbload", "Avg Active Sessions", .count),
            freeableMemory: series("memfree", "Freeable Memory", .bytesToGB),
            swapUsage: series("swap", "Swap Usage", .bytesToMB),
            freeStorageSpace: series("storage", "Free Storage", .bytesToGB),
            readIOPS: series("riops", "Read IOPS", .countPerSec),
            writeIOPS: series("wiops", "Write IOPS", .countPerSec)
        )
    }

    // MARK: - Performance Insights

    /// Fetches Top Queries / Users / Hosts by average active sessions from Performance Insights.
    /// Returns `.disabled` without any AWS calls when PI is off or the resource id is unknown.
    func fetchPerformanceInsights(instance: RDSInstance, range: MetricRange) async throws -> PerformanceInsightsData {
        guard instance.performanceInsightsEnabled, let resourceId = instance.dbiResourceId else {
            return .disabled
        }

        let client = try await createPIClient()
        let now = Date()
        // Performance Insights only retains StartTime within the past 7 days.
        let window = min(range.seconds, 604_800)
        let startTime = now.addingTimeInterval(-window)

        func topItems(groupName: String, dimensionKey: String) async -> [TopItem] {
            let input = DescribeDimensionKeysInput(
                endTime: now,
                groupBy: PIClientTypes.DimensionGroup(group: groupName),
                identifier: resourceId,
                maxResults: 10,
                metric: "db.load.avg",
                serviceType: .rds,
                startTime: startTime
            )
            do {
                let response = try await client.describeDimensionKeys(input: input)
                let keys = response.keys ?? []
                return keys.compactMap { key -> TopItem? in
                    let label = key.dimensions?[dimensionKey]
                        ?? key.dimensions?.values.first
                        ?? "(unknown)"
                    return TopItem(label: label, load: key.total ?? 0)
                }
                .sorted { $0.load > $1.load }
            } catch {
                print("PI \(groupName) query failed: \(error)")
                return []
            }
        }

        // db.sql_tokenized groups by digest text; db.user and db.host break down by client.
        let queries = await topItems(groupName: "db.sql_tokenized", dimensionKey: "db.sql_tokenized.statement")
        let users = await topItems(groupName: "db.user", dimensionKey: "db.user.name")
        let hosts = await topItems(groupName: "db.host", dimensionKey: "db.host.name")

        return PerformanceInsightsData(enabled: true, topQueries: queries, topUsers: users, topHosts: hosts)
    }

    // MARK: - Events & alarms

    /// Fetches recent RDS events (last 7 days) and any CloudWatch alarms in ALARM state for the
    /// instance. Each source is fetched defensively so one failure doesn't sink the other.
    func fetchInstanceActivity(instanceId: String) async throws -> InstanceActivity {
        async let events = fetchRecentEvents(instanceId: instanceId)
        async let alarms = fetchActiveAlarms(instanceId: instanceId)
        return InstanceActivity(events: await events, alarms: await alarms)
    }

    private func fetchRecentEvents(instanceId: String) async -> [RDSEvent] {
        do {
            let client = try await createRDSClient()
            // DescribeEvents accepts a duration in minutes; 7 days = 10080 minutes (the max retention).
            let input = DescribeEventsInput(
                duration: 10_080,
                maxRecords: 20,
                sourceIdentifier: instanceId,
                sourceType: .dbInstance
            )
            let response = try await client.describeEvents(input: input)
            let events = (response.events ?? []).compactMap { e -> RDSEvent? in
                guard let date = e.date, let message = e.message else { return nil }
                return RDSEvent(date: date, message: message, categories: e.eventCategories ?? [])
            }
            return events.sorted { $0.date > $1.date }
        } catch {
            print("DescribeEvents failed for \(instanceId): \(error)")
            return []
        }
    }

    private func fetchActiveAlarms(instanceId: String) async -> [CloudWatchAlarmInfo] {
        do {
            let client = try await createCloudWatchClient()
            // Only metric alarms currently in ALARM state.
            let input = DescribeAlarmsInput(
                alarmTypes: [.metricalarm],
                maxRecords: 50,
                stateValue: .alarm
            )
            let response = try await client.describeAlarms(input: input)
            let alarms = (response.metricAlarms ?? []).compactMap { a -> CloudWatchAlarmInfo? in
                guard let name = a.alarmName else { return nil }
                // Keep alarms that reference this instance via a DBInstanceIdentifier dimension.
                let matchesInstance = (a.dimensions ?? []).contains {
                    $0.name == "DBInstanceIdentifier" && $0.value == instanceId
                }
                guard matchesInstance else { return nil }
                return CloudWatchAlarmInfo(
                    name: name,
                    reason: a.stateReason ?? "",
                    metricName: a.metricName
                )
            }
            return alarms
        } catch {
            print("DescribeAlarms failed for \(instanceId): \(error)")
            return []
        }
    }
    
    private func createRDSClient() async throws -> RDSClient {
        guard let credentials = AWSCredentialsReader.shared.getCredentials(profile: currentProfile) else {
            throw NSError(domain: "PulseBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load AWS credentials"])
        }
        
        let config = try await RDSClient.RDSClientConfiguration(
            awsCredentialIdentityResolver: try StaticAWSCredentialIdentityResolver(
                AWSCredentialIdentity(
                    accessKey: credentials.accessKeyId,
                    secret: credentials.secretAccessKey,
                    sessionToken: credentials.sessionToken
                )
            ),
            region: currentRegion
        )
        
        return RDSClient(config: config)
    }
    
    private func createCloudWatchClient() async throws -> CloudWatchClient {
        guard let credentials = AWSCredentialsReader.shared.getCredentials(profile: currentProfile) else {
            throw NSError(domain: "PulseBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load AWS credentials"])
        }
        
        let config = try await CloudWatchClient.CloudWatchClientConfiguration(
            awsCredentialIdentityResolver: try StaticAWSCredentialIdentityResolver(
                AWSCredentialIdentity(
                    accessKey: credentials.accessKeyId,
                    secret: credentials.secretAccessKey,
                    sessionToken: credentials.sessionToken
                )
            ),
            region: currentRegion
        )
        
        return CloudWatchClient(config: config)
    }

    private func createPIClient() async throws -> PIClient {
        guard let credentials = AWSCredentialsReader.shared.getCredentials(profile: currentProfile) else {
            throw NSError(domain: "PulseBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load AWS credentials"])
        }

        let config = try await PIClient.PIClientConfiguration(
            awsCredentialIdentityResolver: try StaticAWSCredentialIdentityResolver(
                AWSCredentialIdentity(
                    accessKey: credentials.accessKeyId,
                    secret: credentials.secretAccessKey,
                    sessionToken: credentials.sessionToken
                )
            ),
            region: currentRegion
        )

        return PIClient(config: config)
    }

    private func estimateMaxConnections(instanceClass: String) -> Int {
        // Simplified estimation based on instance class
        // In production, this should query the parameter group
        
        if instanceClass.contains("micro") {
            return 66
        } else if instanceClass.contains("small") {
            return 150
        } else if instanceClass.contains("medium") {
            return 296
        } else if instanceClass.contains("large") {
            return 648
        } else if instanceClass.contains("xlarge") {
            return 1280
        } else {
            return 500 // Default fallback
        }
    }
}
