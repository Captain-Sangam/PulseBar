# PulseBar - Agent Development Guide

This document provides comprehensive context for AI agents and developers working on the PulseBar codebase.

## Table of Contents

- [Product Overview](#product-overview)
- [Functional Requirements](#functional-requirements)
- [Technical Specification](#technical-specification)
- [Architecture](#architecture)
- [Coding Patterns & Standards](#coding-patterns--standards)
- [Development Guidelines](#development-guidelines)

---

## Product Overview

**PulseBar** is a macOS menu bar application that monitors AWS RDS instances in real-time, providing at-a-glance health metrics and proactive alerting.

### Target Users
- Engineers and operators managing AWS RDS databases
- Primary use case: Passive monitoring + early warning without opening AWS console

### Value Proposition
- Eliminates need to constantly check AWS Console
- Provides early warning through macOS notifications
- Aggregates multiple critical metrics in one view
- Runs quietly in background with minimal resource usage

---

## Functional Requirements

### 1. AWS Integration

#### Credential Management
- **MUST** read credentials from `~/.aws/credentials` and `~/.aws/config`
- **MUST** support multiple AWS profiles
- **MUST** support region selection
- **MUST NOT** store or persist credentials (read-only access to AWS files)

#### Supported Configurations
```ini
# ~/.aws/credentials
[default]
aws_access_key_id = ...
aws_secret_access_key = ...
aws_session_token = ...  # Optional

[profile-name]
aws_access_key_id = ...
aws_secret_access_key = ...

# ~/.aws/config
[default]
region = us-east-1

[profile profile-name]
region = us-west-2
```

### 2. RDS Discovery

#### API Integration
- Use AWS SDK `DescribeDBInstances` to fetch all RDS instances
- Extract and store for each instance:
  - Database identifier (DBInstanceIdentifier)
  - Engine type (MySQL, PostgreSQL, etc.)
  - Instance class (db.t3.micro, db.r5.large, etc.)
  - Allocated storage (GB)
  - Instance status
  - Parameter group (for max_connections lookup)

#### Refresh Behavior
- Auto-refresh every 15 minutes
- Manual refresh via menu button
- In-memory cache only (no persistence)

### 3. Metrics Collection

#### CloudWatch Metrics (per instance)

| Metric | CloudWatch Name | Statistic | Period | Usage |
|--------|----------------|-----------|--------|-------|
| CPU % | `CPUUtilization` | Average | 300s | Direct display |
| Connections | `DatabaseConnections` | Average | 300s | Activity + % calculation |
| Free Storage | `FreeStorageSpace` | Average | 300s | Storage % calculation |

#### Derived Metrics

| Metric | Formula | Description |
|--------|---------|-------------|
| Connections Used % | `(DatabaseConnections / max_connections) × 100` | Percentage of connection pool used |
| Storage Used % | `((AllocatedStorage - FreeStorageSpace) / AllocatedStorage) × 100` | Percentage of disk space used |

#### Batch Operations
- Use `GetMetricData` API for efficient batch querying
- Query all metrics for an instance in a single API call
- Time window: Last 15 minutes
- Max datapoints: 1 (most recent value)

### 4. Alerting System

#### Alert Thresholds
Trigger notification if **ANY** of these conditions are met:
- CPU Utilization > 50%
- Connections Used % > 50%
- Storage Used % > 50%
- Activity (raw connections) > 50% of max_connections

#### Notification Format
```
⚠️ RDS Alert: {instance-identifier}
CPU: {value}%
Connections: {value}%
Storage: {value}%
```

#### Deduplication Logic
- One notification per DB per refresh cycle maximum
- Track alert state per instance with:
  - Instance ID
  - Timestamp of last alert
  - Set of currently alerting metrics
- Send new notification only if:
  - Different metric(s) are now breaching (metric set changed)
  - Instance recovered and breached again (alert was cleared)
  - More than 15 minutes since last alert for same condition
- Clear alert state when all metrics return below 50%

### 5. User Interface

#### Menu Bar Integration
- App lives in macOS menu bar (no dock icon)
- Icon: 📊 (database/chart emoji)
- Click icon to show dropdown menu

#### Menu Structure
```
Profile: {current-profile} >
  - default
  - production
  - staging
Region: {current-region} >
  - us-east-1
  - us-west-2
  - eu-west-1
  - ...
─────────────────────
🔄 Refresh Now (⌘R)
─────────────────────
🟢 instance-1
  postgres - db.t3.medium
  🟢 CPU: 12.5%
  🟢 Connections: 23.1%
  🔴 Storage: 78.2%
  Activity: 14 connections
🟡 instance-2
  ...
─────────────────────
Last updated: 3:45 PM
─────────────────────
Quit (⌘Q)
```

#### Color Coding System
- 🟢 **Green**: Value < 50% (healthy)
- 🟡 **Yellow**: Value 50-75% (warning)
- 🔴 **Red**: Value > 75% (critical)

### 6. Non-Functional Requirements

#### Performance
- Handle 50+ RDS instances gracefully
- UI must remain responsive during data fetches
- Async/await for all AWS API calls
- Background refresh (non-blocking)

#### Security
- No credential storage or caching
- Read credentials on-demand from AWS config files
- Use official AWS SDK credential providers
- No network calls except to AWS APIs

#### Reliability
- Graceful error handling for:
  - Missing credentials
  - Network failures
  - AWS API errors
  - Invalid responses
- Continue operating if individual instance metrics fail
- Log errors without crashing

---

## Technical Specification

### Technology Stack

| Component | Technology | Version | Purpose |
|-----------|-----------|---------|---------|
| Language | Swift | 5.9+ | Native macOS development |
| Platform | macOS | 13.0+ | Menu bar app capabilities |
| Package Manager | Swift Package Manager | - | Dependency management |
| AWS SDK | aws-sdk-swift | 0.40.0+ | Official AWS integration |
| UI Framework | AppKit | - | Native macOS UI |
| Notifications | UserNotifications | - | Native notification system |

### Dependencies

```swift
// Package.swift
.package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "0.40.0")

// Products used:
- AWSRDS (RDS API client)
- AWSCloudWatch (CloudWatch API client)
```

### AWS IAM Permissions Required

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBInstances",
        "cloudwatch:GetMetricData"
      ],
      "Resource": "*"
    }
  ]
}
```

### Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│ Timer (15 min) / Manual Refresh                             │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ AWSCredentialsReader                                        │
│ - Read ~/.aws/credentials                                   │
│ - Read ~/.aws/config                                        │
│ - Load profile + region                                     │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ RDSMonitoringService.fetchRDSInstances()                    │
│ - Call DescribeDBInstances                                  │
│ - Parse instance metadata                                   │
│ - Store in instances array                                  │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ RDSMonitoringService.fetchMetrics()                         │
│ - For each instance:                                        │
│   - Build MetricDataQuery for CPU, Connections, Storage     │
│   - Call GetMetricData (batched)                            │
│   - Parse metric values                                     │
│   - Calculate derived metrics                               │
│   - Store in metricsCache                                   │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ RDSMonitoringService.checkAlerts()                          │
│ - For each instance with metrics:                           │
│   - Evaluate thresholds (>50%)                              │
│   - If breached → AlertManager.sendAlert()                  │
│   - If recovered → AlertManager.clearAlert()                │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ AlertManager                                                │
│ - Check deduplication rules                                 │
│ - Send UNNotification if needed                             │
│ - Update alert state tracking                               │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ AppDelegate.updateMenu()                                    │
│ - Rebuild menu with latest data                             │
│ - Apply color coding                                        │
│ - Update "Last updated" timestamp                           │
└─────────────────────────────────────────────────────────────┘
```

---

## Architecture

### Project Structure

```
PulseBar/
├── Package.swift                 # SPM configuration
├── Info.plist                    # macOS app metadata
├── Makefile                      # Build automation
├── README.md                     # User documentation
├── agents.md                     # This file
└── Sources/
    ├── main.swift               # Entry point
    ├── AppDelegate.swift        # UI & app lifecycle
    ├── AWSCredentialsReader.swift   # Credential parsing
    ├── RDSMonitoringService.swift   # AWS API integration
    ├── AlertManager.swift           # Notification logic
    └── Models.swift                 # Data structures
```

### Component Responsibilities

#### main.swift
- **Purpose**: Application entry point
- **Responsibilities**:
  - Initialize NSApplication
  - Set AppDelegate
  - Start run loop

#### AppDelegate.swift
- **Purpose**: Menu bar UI coordinator
- **Responsibilities**:
  - Create and manage NSStatusItem (menu bar icon)
  - Build and update NSMenu
  - Handle user interactions (profile/region selection, refresh)
  - Coordinate RDSMonitoringService
  - Manage 15-minute refresh timer
  - Request notification permissions
- **Key Methods**:
  - `applicationDidFinishLaunching()` - Setup
  - `updateMenu()` - Rebuild menu with current data
  - `createInstanceMenuItem()` - Format instance data for display
  - `refreshData()` - Trigger data refresh
  - `startAutoRefresh()` - Setup timer

#### AWSCredentialsReader.swift
- **Purpose**: Parse AWS configuration files
- **Responsibilities**:
  - Read `~/.aws/credentials` and `~/.aws/config`
  - Extract profiles, keys, tokens, regions
  - Provide credentials for SDK initialization
- **Key Methods**:
  - `listProfiles()` - Enumerate all available profiles
  - `getCredentials(profile:)` - Get credentials for specific profile
  - `getRegion(profile:)` - Get default region for profile
- **Pattern**: Singleton (`shared` instance)

#### RDSMonitoringService.swift
- **Purpose**: AWS API integration and data management
- **Responsibilities**:
  - Manage current profile/region state
  - Fetch RDS instances via SDK
  - Fetch CloudWatch metrics via SDK
  - Calculate derived metrics
  - Cache metrics in memory
  - Trigger alert checks
- **Key Methods**:
  - `refresh()` - Main refresh orchestrator
  - `fetchRDSInstances()` - Call RDS API
  - `fetchMetrics()` - Call CloudWatch API
  - `fetchInstanceMetrics()` - Per-instance metric collection
  - `checkAlerts()` - Evaluate alert conditions
  - `createRDSClient()` - Initialize RDS SDK client
  - `createCloudWatchClient()` - Initialize CloudWatch SDK client
- **State**:
  - `instances: [RDSInstance]` - Current RDS instances
  - `metricsCache: [String: RDSMetrics]` - Latest metrics by instance ID
  - `lastUpdateTime: Date?` - Timestamp of last successful refresh

#### AlertManager.swift
- **Purpose**: Notification management with deduplication
- **Responsibilities**:
  - Track alert state per instance
  - Implement deduplication logic
  - Send macOS notifications
  - Clear alerts when recovered
- **Key Methods**:
  - `sendAlert()` - Evaluate and send notification
  - `clearAlert()` - Remove alert state
  - `sendNotification()` - Wrapper for UNNotification
  - `getAlertingMetrics()` - Convert metrics to alerting set
- **State**:
  - `activeAlerts: [String: AlertState]` - Current alerts by instance ID

#### Models.swift
- **Purpose**: Data structures
- **Structures**:
  - `RDSInstance` - RDS instance metadata
  - `RDSMetrics` - Collected and calculated metrics
  - `AlertState` - Alert tracking state
- **Methods**:
  - `RDSMetrics.hasAlert()` - Check if any threshold breached
  - `RDSMetrics.getAlertMessage()` - Format notification message

---

## Coding Patterns & Standards

### Swift Language Patterns

#### Async/Await for Concurrency
```swift
// All AWS API calls use async/await
func refresh() async {
    do {
        try await fetchRDSInstances()
        try await fetchMetrics()
        checkAlerts()
        lastUpdateTime = Date()
    } catch {
        print("Error refreshing data: \(error)")
    }
}

// Called from main thread with Task wrapper
@objc func refreshData() {
    Task {
        await monitoringService.refresh()
        await MainActor.run {
            updateMenu()
        }
    }
}
```

#### Error Handling
```swift
// Pattern: Try-catch with logging, graceful degradation
for instance in instances {
    do {
        let metrics = try await fetchInstanceMetrics(...)
        metricsCache[instance.identifier] = metrics
    } catch {
        print("Error fetching metrics for \(instance.identifier): \(error)")
        // Continue processing other instances
    }
}
```

#### Optional Safety
```swift
// Pattern: Guard for required values, nil-coalescing for defaults
guard let keyId = accessKeyId, let secretKey = secretAccessKey else {
    return nil
}

let allocatedStorage = Int(db.allocatedStorage ?? 0)
```

#### Singleton Pattern
```swift
// Pattern: Shared instance for stateless utilities
class AWSCredentialsReader {
    static let shared = AWSCredentialsReader()
    private init() { ... }
}

// Usage:
let profiles = AWSCredentialsReader.shared.listProfiles()
```

### AWS SDK Patterns

#### Client Initialization
```swift
// Pattern: Create client with credentials provider per request
private func createRDSClient() async throws -> RDSClient {
    guard let credentials = AWSCredentialsReader.shared.getCredentials(profile: currentProfile) else {
        throw NSError(...)
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
```

#### Batched Metric Queries
```swift
// Pattern: Build array of MetricDataQuery, single GetMetricData call
var queries: [MetricDataQuery] = []

queries.append(MetricDataQuery(
    id: "cpu",
    metricStat: MetricStat(
        metric: Metric(
            dimensions: [Dimension(name: "DBInstanceIdentifier", value: instanceId)],
            metricName: "CPUUtilization",
            namespace: "AWS/RDS"
        ),
        period: 300,
        stat: "Average"
    )
))

// ... add more queries

let response = try await client.getMetricData(input: input)

// Parse by matching result.id
for result in results {
    switch result.id {
    case "cpu": cpuUtilization = values[0]
    case "connections": currentConnections = values[0]
    // ...
    }
}
```

### UI/AppKit Patterns

#### Menu Building
```swift
// Pattern: Clear and rebuild menu on updates
func updateMenu() {
    menu.removeAllItems()
    
    // Add sections in order
    menu.addItem(profileSelector)
    menu.addItem(regionSelector)
    menu.addItem(NSMenuItem.separator())
    menu.addItem(refreshButton)
    menu.addItem(NSMenuItem.separator())
    
    // Dynamic content
    for instance in instances {
        menu.addItem(createInstanceMenuItem(instance))
    }
    
    menu.addItem(NSMenuItem.separator())
    menu.addItem(lastUpdatedLabel)
    menu.addItem(NSMenuItem.separator())
    menu.addItem(quitButton)
}
```

#### Submenu Pattern
```swift
// Pattern: Create submenu for hierarchical data
let submenu = NSMenu()
submenu.addItem(NSMenuItem(title: "Details", action: nil, keyEquivalent: ""))
// ... add more items

let mainItem = NSMenuItem(title: "Instance Name", action: nil, keyEquivalent: "")
mainItem.submenu = submenu
menu.addItem(mainItem)
```

#### Status Indicator Pattern
```swift
// Pattern: Checkmark for selected item
for option in options {
    let item = NSMenuItem(title: option, action: #selector(selectOption), keyEquivalent: "")
    item.state = (option == currentSelection) ? .on : .off
    submenu.addItem(item)
}
```

### Notification Patterns

#### Permission Request
```swift
// Pattern: Request on app launch
func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
        if let error = error {
            print("Notification permission error: \(error)")
        }
    }
}
```

#### Notification Sending
```swift
// Pattern: Create content, send with unique ID
let content = UNMutableNotificationContent()
content.title = "Title"
content.body = "Body"
content.sound = .default

let request = UNNotificationRequest(
    identifier: UUID().uuidString,
    content: content,
    trigger: nil  // Immediate delivery
)

UNUserNotificationCenter.current().add(request) { error in
    // Handle error
}
```

### State Management

#### In-Memory Cache Pattern
```swift
// Pattern: Dictionary cache with instance ID keys
var metricsCache: [String: RDSMetrics] = [:]

func getMetrics(for instanceId: String) -> RDSMetrics? {
    return metricsCache[instanceId]
}

// Update atomically
metricsCache[instance.identifier] = newMetrics
```

#### Alert State Tracking
```swift
// Pattern: Track state with timestamp and details
private var activeAlerts: [String: AlertState] = [:]

// Check before sending
if let existingAlert = activeAlerts[instanceId] {
    let timeSinceLastAlert = Date().timeIntervalSince(existingAlert.timestamp)
    if currentMetrics != existingAlert.alertingMetrics || timeSinceLastAlert > 900 {
        sendNotification(message)
        updateAlertState(instanceId, metrics)
    }
} else {
    // New alert
    sendNotification(message)
    updateAlertState(instanceId, metrics)
}
```

---

## Development Guidelines

### Code Style

#### Naming Conventions
- **Classes**: PascalCase (`RDSMonitoringService`)
- **Methods**: camelCase (`fetchMetrics()`)
- **Properties**: camelCase (`currentProfile`)
- **Constants**: camelCase with `let` (`maxConnections`)
- **Private members**: Prefix with `private` keyword

#### Method Organization
```swift
// Pattern: Public interface first, private helpers last
class MyService {
    // MARK: - Public Properties
    var publicProperty: String
    
    // MARK: - Public Methods
    func publicMethod() { }
    
    // MARK: - Private Properties
    private var privateProperty: Int
    
    // MARK: - Private Methods
    private func privateHelper() { }
}
```

#### Comments
```swift
// Pattern: Comments for "why", not "what"
// Good:
// Estimate max connections based on instance class
// In production, this should query the parameter group
let maxConnections = estimateMaxConnections(instanceClass)

// Bad:
// Get max connections
let maxConnections = estimateMaxConnections(instanceClass)
```

### Testing Strategy

#### Manual Testing Checklist
1. **Credentials**:
   - [ ] App loads with valid credentials
   - [ ] App handles missing credentials gracefully
   - [ ] Profile switching works
   - [ ] Region switching works

2. **Data Fetching**:
   - [ ] RDS instances load correctly
   - [ ] Metrics appear for each instance
   - [ ] Manual refresh updates data
   - [ ] Auto-refresh triggers every 15 minutes

3. **UI**:
   - [ ] Menu bar icon appears
   - [ ] Menu opens on click
   - [ ] Color coding reflects metric values
   - [ ] Submenus expand correctly

4. **Alerts**:
   - [ ] Notification sent when metric > 50%
   - [ ] No duplicate notifications for same condition
   - [ ] New notification when different metric breaches
   - [ ] Alert clears when metrics recover

### Extension Points

#### Adding New Metrics
1. Add metric to `MetricDataQuery` array in `fetchInstanceMetrics()`
2. Add case to result parsing switch statement
3. Add field to `RDSMetrics` struct
4. Update `createInstanceMenuItem()` to display
5. Update `hasAlert()` if threshold applies
6. Update `getAlertMessage()` if should appear in notifications

#### Supporting New AWS Services
1. Add SDK dependency to `Package.swift`
2. Create new service class following `RDSMonitoringService` pattern
3. Implement client initialization with credentials
4. Add fetching methods with async/await
5. Integrate into `AppDelegate` refresh cycle

#### Customizing Alert Thresholds
Current implementation uses hardcoded 50% threshold. To make configurable:
1. Add `alertThreshold: Double` property to `RDSMonitoringService`
2. Add UI for threshold selection in `AppDelegate`
3. Update `hasAlert()` to use variable threshold
4. Persist threshold in `UserDefaults` (optional)

### Build and Release

#### Development Build
```bash
swift build          # Debug build
swift run            # Run debug build
```

#### Release Build
```bash
swift build -c release
# Binary at: .build/release/PulseBar
```

#### Installation
```bash
make install
# Creates .app bundle and copies to /Applications
```

#### Debugging
```bash
# View console logs
log stream --predicate 'processImagePath contains "PulseBar"' --level debug
```

### Known Limitations (v1)

1. **Max Connections Estimation**: Currently estimates based on instance class naming. Should query RDS parameter groups for actual `max_connections` value.

2. **No Historical Data**: Only shows current snapshot. Future: Add trending/graphs.

3. **Single Account**: No multi-account aggregation. Each profile is queried separately.

4. **No Performance Insights**: Not integrated with RDS Performance Insights API.

5. **Basic Error Handling**: Network errors logged but not shown to user. Future: Add error states in UI.

### Future Enhancements

#### High Priority
- [ ] Query parameter groups for accurate `max_connections`
- [ ] Add error indicators in UI (not just logs)
- [ ] Persist alert state across app restarts
- [ ] Add preference pane for customization

#### Medium Priority
- [ ] Historical metric graphs (last hour/day)
- [ ] Export metrics to CSV/JSON
- [ ] Custom alert thresholds per instance
- [ ] Dark mode color scheme optimization

#### Low Priority
- [ ] Performance Insights integration
- [ ] Multi-account dashboard
- [ ] Query execution monitoring
- [ ] Auto-scaling recommendations

---

## Quick Reference

### Key Files for Common Tasks

| Task | Primary File(s) | Method(s) |
|------|----------------|-----------|
| Add new metric | `RDSMonitoringService.swift`, `Models.swift` | `fetchInstanceMetrics()`, `RDSMetrics` struct |
| Change UI layout | `AppDelegate.swift` | `updateMenu()`, `createInstanceMenuItem()` |
| Modify alert logic | `AlertManager.swift` | `sendAlert()`, `getAlertingMetrics()` |
| Add AWS profile support | `AWSCredentialsReader.swift` | `getCredentials()`, `listProfiles()` |
| Change refresh interval | `AppDelegate.swift` | `startAutoRefresh()` (currently 900s) |

### Environment Variables (Optional)

```bash
# Override AWS config location
export AWS_CONFIG_FILE=~/.aws/config
export AWS_SHARED_CREDENTIALS_FILE=~/.aws/credentials

# AWS SDK debug logging
export AWS_LOG_LEVEL=debug
```

### Useful Commands

```bash
# Clean build
make clean

# Run without building
./.build/debug/PulseBar

# Check for updates to AWS SDK
swift package update

# Show dependency tree
swift package show-dependencies
```

---

## Contact & Contribution

For questions, bug reports, or feature requests, please open an issue on the repository.

When contributing, ensure:
1. Code follows Swift conventions
2. All AWS API calls use async/await
3. Error handling is graceful
4. UI updates happen on main thread
5. No credentials are logged or persisted
6. Changes are tested with multiple profiles/regions

---

**Last Updated**: 2026-01-17  
**Version**: 1.0.0  
**Maintainer**: PulseBar Development Team
