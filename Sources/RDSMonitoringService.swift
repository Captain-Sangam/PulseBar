import Foundation
import AWSRDS
import AWSCloudWatch
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
