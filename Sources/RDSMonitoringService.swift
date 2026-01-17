import Foundation
import AWSRDS
import AWSCloudWatch
import ClientRuntime
import AWSClientRuntime

class RDSMonitoringService {
    var currentProfile: String = "default"
    var currentRegion: String = "us-east-1"
    var instances: [RDSInstance] = []
    var metricsCache: [String: RDSMetrics] = [:]
    var lastUpdateTime: Date?
    
    private var alertManager = AlertManager()
    
    func refresh() async {
        do {
            // Fetch RDS instances
            try await fetchRDSInstances()
            
            // Fetch metrics for each instance
            try await fetchMetrics()
            
            // Check for alerts
            checkAlerts()
            
            lastUpdateTime = Date()
        } catch {
            print("Error refreshing data: \(error)")
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
                    status: status
                )
                
                newInstances.append(instance)
            }
        }
        
        instances = newInstances
    }
    
    private func fetchMetrics() async throws {
        let client = try await createCloudWatchClient()
        let now = Date()
        let startTime = now.addingTimeInterval(-900) // 15 minutes ago
        
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
        var queries: [MetricDataQuery] = []
        
        // CPU Utilization
        queries.append(MetricDataQuery(
            id: "cpu",
            metricStat: MetricStat(
                metric: Metric(
                    dimensions: [
                        Dimension(name: "DBInstanceIdentifier", value: instanceId)
                    ],
                    metricName: "CPUUtilization",
                    namespace: "AWS/RDS"
                ),
                period: 300,
                stat: "Average"
            )
        ))
        
        // Database Connections
        queries.append(MetricDataQuery(
            id: "connections",
            metricStat: MetricStat(
                metric: Metric(
                    dimensions: [
                        Dimension(name: "DBInstanceIdentifier", value: instanceId)
                    ],
                    metricName: "DatabaseConnections",
                    namespace: "AWS/RDS"
                ),
                period: 300,
                stat: "Average"
            )
        ))
        
        // Free Storage Space
        queries.append(MetricDataQuery(
            id: "storage",
            metricStat: MetricStat(
                metric: Metric(
                    dimensions: [
                        Dimension(name: "DBInstanceIdentifier", value: instanceId)
                    ],
                    metricName: "FreeStorageSpace",
                    namespace: "AWS/RDS"
                ),
                period: 300,
                stat: "Average"
            )
        ))
        
        let input = GetMetricDataInput(
            endTime: endTime,
            maxDatapoints: 1,
            metricDataQueries: queries,
            startTime: startTime
        )
        
        let response = try await client.getMetricData(input: input)
        
        // Parse results
        var cpuUtilization: Double = 0
        var currentConnections: Double = 0
        var freeStorageSpace: Double = 0
        
        if let results = response.metricDataResults {
            for result in results {
                if let values = result.values, !values.isEmpty {
                    let value = values[0]
                    
                    switch result.id {
                    case "cpu":
                        cpuUtilization = value
                    case "connections":
                        currentConnections = value
                    case "storage":
                        freeStorageSpace = value
                    default:
                        break
                    }
                }
            }
        }
        
        // Calculate derived metrics
        let connectionsUsedPercent = (currentConnections / Double(maxConnections)) * 100
        let allocatedStorageBytes = Double(allocatedStorage) * 1024 * 1024 * 1024 // GB to bytes
        let usedStorageBytes = allocatedStorageBytes - freeStorageSpace
        let storageUsedPercent = (usedStorageBytes / allocatedStorageBytes) * 100
        
        return RDSMetrics(
            cpuUtilization: cpuUtilization,
            currentConnections: currentConnections,
            connectionsUsedPercent: max(0, min(100, connectionsUsedPercent)),
            storageUsedPercent: max(0, min(100, storageUsedPercent)),
            freeStorageSpace: freeStorageSpace
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
    
    private func createRDSClient() async throws -> RDSClient {
        guard let credentials = AWSCredentialsReader.shared.getCredentials(profile: currentProfile) else {
            throw NSError(domain: "PulseBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load AWS credentials"])
        }
        
        let credentialsProvider = try AWSCredentialsProvider.fromStatic(
            AWSClientRuntime.AWSCredentials(
                accessKey: credentials.accessKeyId,
                secret: credentials.secretAccessKey,
                sessionToken: credentials.sessionToken
            )
        )
        
        let config = try await RDSClient.RDSClientConfiguration(
            credentialsProvider: credentialsProvider,
            region: currentRegion
        )
        
        return RDSClient(config: config)
    }
    
    private func createCloudWatchClient() async throws -> CloudWatchClient {
        guard let credentials = AWSCredentialsReader.shared.getCredentials(profile: currentProfile) else {
            throw NSError(domain: "PulseBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load AWS credentials"])
        }
        
        let credentialsProvider = try AWSCredentialsProvider.fromStatic(
            AWSClientRuntime.AWSCredentials(
                accessKey: credentials.accessKeyId,
                secret: credentials.secretAccessKey,
                sessionToken: credentials.sessionToken
            )
        )
        
        let config = try await CloudWatchClient.CloudWatchClientConfiguration(
            credentialsProvider: credentialsProvider,
            region: currentRegion
        )
        
        return CloudWatchClient(config: config)
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
