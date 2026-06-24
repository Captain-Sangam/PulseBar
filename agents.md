# PulseBar - Agent Development Guide

This document provides comprehensive context for AI agents and developers working on the PulseBar codebase.

---

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
- **MUST** support session tokens for temporary credentials

#### Supported Configurations
```ini
# ~/.aws/credentials
[default]
aws_access_key_id = ...
aws_secret_access_key = ...
aws_session_token = ...  # Optional (for temporary credentials)

[profile-name]
aws_access_key_id = ...
aws_secret_access_key = ...

# ~/.aws/config
[default]
region = us-west-2

[profile profile-name]
region = us-east-1
```

### 2. RDS Discovery

#### API Integration
- Use AWS SDK `DescribeDBInstances` to fetch all RDS instances
- Extract and store for each instance:
  - Database identifier (DBInstanceIdentifier)
  - Engine type (MySQL, PostgreSQL, etc.)
  - Instance class (db.t3.micro, db.r5.large, etc.)
  - Allocated storage (GiB)
  - Instance status
  - DbiResourceId + Performance Insights enabled flag (for PI queries)
  - Read-replica source identifier (for replica grouping)
  - Parameter group (for max_connections lookup - future)

#### Refresh Behavior
- Auto-refresh on a configurable interval (default 15 min; see `Settings`)
- Manual refresh via menu button
- In-memory cache only (no persistence)

#### Replica Grouping
- Read replicas are nested under their source instance in the menu (when the source is in the
  same list), with a `ReplicaLag` readout in the submenu

### 3. Metrics Collection

#### CloudWatch Metrics (per instance)

| Metric       | CloudWatch Name       | Statistic | Period    | Notes                                          |
| ------------ | --------------------- | --------- | --------- | ---------------------------------------------- |
| CPU %        | `CPUUtilization`      | Average   | 300s      | Direct display                                 |
| Connections  | `DatabaseConnections` | Average   | 300s      | Activity + % calculation                       |
| Sessions     | `DBLoad`              | Average   | 300s      | Avg active sessions; `-1`/N/A when PI disabled |
| Free Storage | `FreeStorageSpace`    | Average   | **3600s** | Needs longer period for reliable data          |

**Important**: Storage metric uses a 1-hour period because CloudWatch may not report FreeStorageSpace every 5 minutes for all instances.

`DBLoad` only reports when Performance Insights is enabled on the instance; when it returns no datapoint the value is `-1` and the menu's Sessions row falls back to the raw connection count.

#### Detail dashboard (per instance, on demand)

Opened via **📊 Open Details…** in an instance's submenu. Fetches time-series over a selectable
range (1D → 300s, 7D → 3600s, 30D → 21600s period) in a single `GetMetricData` call, plus
Performance Insights breakdowns. Charts are grouped CPU / Memory / Storage:

| Group   | Charts                                                       |
| ------- | ------------------------------------------------------------ |
| CPU     | `CPUUtilization` (Percent), `DBLoad` (Count)                 |
| Memory  | `FreeableMemory` (Bytes→GB), `SwapUsage` (Bytes→MB)          |
| Storage | `FreeStorageSpace` (Bytes→GB), `ReadIOPS` + `WriteIOPS` (/s) |

Performance Insights panels (Top Queries / Users / Hosts) use `pi:DescribeDimensionKeys` with
`metric: db.load.avg`, grouped by `db.sql_tokenized`, `db.user`, and `db.host`. PI `StartTime` is
clamped to the last 7 days (an API constraint), and the panels are skipped entirely when PI is off.
The window sizes its height to fit the content (via a `ContentHeightKey` SwiftUI preference reported
to `DatabaseDetailWindowController`) so the whole dashboard shows without a scroll bar.

#### Query drill-down

Clicking a Top Query opens `QueryDetailWindowController` (its own floating window, `QueryDetailView`).
It captures the digest id (`db.sql_tokenized.id`) on the `TopItem` and drills in, all scoped by a
`db.sql_tokenized.id` filter — mirroring the RDS console's Top SQL view:

- **Load over time**: `pi:GetResourceMetrics`, `metric: db.load.avg` (period clamped to ≤ 3600s,
  the coarsest value PI accepts).
- **Individual SQL statements**: `pi:DescribeDimensionKeys` grouped by `db.sql`, returning
  `db.sql.statement` (preview) + `db.sql.id`.
- **Top users / hosts for the query**: `pi:DescribeDimensionKeys` grouped by `db.user` / `db.host`.
- **Full SQL text**: `pi:GetDimensionKeyDetails` (group `db.sql`, `db.sql.id`), resolved lazily when
  a statement row is expanded.

#### Derived Metrics

| Metric             | Formula                                                                              | Description                        |
| ------------------ | ------------------------------------------------------------------------------------ | ---------------------------------- |
| Connections Used % | `(DatabaseConnections / max_connections) × 100`                                      | Percentage of connection pool used |
| Storage Used %     | `((AllocatedStorage × 1024³) - FreeStorageSpace) / (AllocatedStorage × 1024³) × 100` | Percentage of disk space used      |

**Notes:**
- `AllocatedStorage` is in GiB, `FreeStorageSpace` is in bytes
- Storage shows `-1` (displayed as "N/A") when CloudWatch returns no data

#### Time Window
- Queries CloudWatch for the **last 1 hour** of data (not 15 minutes)
- This ensures reliable data retrieval even for less frequently reported metrics
- Uses the most recent (first) value from the response

### 4. Alerting System

#### Alert Thresholds
Trigger notification if **ANY** metric exceeds the configurable threshold (default 50%, set via
the ⚙️ Settings submenu and stored in `Settings.shared.alertThreshold`):
- CPU Utilization > threshold
- Connections Used % > threshold
- Storage Used % > threshold
- Activity (raw connections) > threshold% of max_connections

**Exception**: -1 (N/A) values are ignored in alert calculations.

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
- Clear alert state when all metrics return below the threshold

#### Notification Delivery (layered)
- **Bundled app** (`make install`): `UNUserNotificationCenter` system notifications
- **Unsigned / `swift run`**: falls back to legacy `NSUserNotification` (no entitlement needed)
- **Always**: an in-menu alert banner lists breaching instances, so alerts are visible even when
  OS notifications are blocked; alerts are also logged to console

### 5. User Interface

#### Menu Bar Integration
- App lives in macOS menu bar (no dock icon) - `LSUIElement = true`
- Icon: 📊 (chart emoji)
- Click icon to show dropdown menu

#### Menu Structure
```
Profile: {current-profile} >
  ✓ default
    production
    staging
Region: {current-region} >
    us-east-1
  ✓ us-west-2
    eu-west-1
    ap-southeast-1
    ap-northeast-1
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
- ⚪ **Gray/White**: N/A (no data available)

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
  - Missing CloudWatch data
- Continue operating if individual instance metrics fail
- Log errors without crashing

---

## Technical Specification

### Technology Stack

| Component       | Technology            | Version | Purpose                          |
| --------------- | --------------------- | ------- | -------------------------------- |
| Language        | Swift                 | 5.9+    | Native macOS development         |
| Platform        | macOS                 | 13.0+   | Menu bar app capabilities        |
| Package Manager | Swift Package Manager | -       | Dependency management            |
| AWS SDK         | aws-sdk-swift         | 0.40.0+ | Official AWS integration         |
| UI Framework    | AppKit                | -       | Native menu-bar UI               |
| Charts UI       | SwiftUI + Charts      | -       | Detail dashboard (via NSHostingView) |
| Notifications   | UserNotifications     | -       | Native notification system       |

### Dependencies

```swift
// Package.swift
.package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "0.40.0")

// Products used:
- AWSRDS (RDS API client)
- AWSCloudWatch (CloudWatch API client)
- AWSPI (Performance Insights API client)

// Implicit dependencies from AWS SDK:
- ClientRuntime
- AWSClientRuntime
- AwsCommonRuntimeKit

// System frameworks (no SPM dependency; macOS 13+):
- SwiftUI, Charts  (detail dashboard, bridged into AppKit with NSHostingView)
```

### AWS SDK Type Namespacing

**Important**: CloudWatch types must use full namespace prefix:

```swift
// Correct:
CloudWatchClientTypes.MetricDataQuery
CloudWatchClientTypes.MetricStat
CloudWatchClientTypes.Metric
CloudWatchClientTypes.Dimension

// Incorrect (will conflict with Foundation types):
MetricDataQuery  // Not found
Dimension        // Conflicts with Foundation.Dimension
```

### AWS SDK Credential API

The AWS SDK for Swift uses `StaticAWSCredentialIdentityResolver`:

```swift
// Correct (current API):
let config = try await RDSClient.RDSClientConfiguration(
    awsCredentialIdentityResolver: try StaticAWSCredentialIdentityResolver(
        AWSCredentialIdentity(
            accessKey: credentials.accessKeyId,
            secret: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken  // Optional
        )
    ),
    region: currentRegion
)

// Incorrect (old API - does not exist):
AWSCredentialsProvider.fromStatic(...)  // Does not exist
credentialsProvider: ...                 // Wrong parameter name
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
        "cloudwatch:GetMetricData",
        "pi:DescribeDimensionKeys",
        "pi:GetResourceMetrics",
        "pi:GetDimensionKeyDetails"
      ],
      "Resource": "*"
    }
  ]
}
```

> Only the first two actions are required. The `pi:*` actions power the Performance Insights panels and the query drill-down (`pi:DescribeDimensionKeys` for the Top lists + statement breakdown, `pi:GetResourceMetrics` for the per-query load chart, `pi:GetDimensionKeyDetails` for full SQL text). All are read-only and degrade gracefully when absent.

### Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│ Timer (configurable interval) / Manual Refresh              │
│ state = .loading                                            │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ AWSCredentialsReader                                        │
│ - Check if ~/.aws/credentials exists                        │
│   → If not: state = .noCredentials, STOP                    │
│ - Check if profile has credentials                          │
│   → If not: state = .invalidCredentials, STOP               │
│ - Load profile + region                                     │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ RDSMonitoringService.fetchRDSInstances()                    │
│ - Call DescribeDBInstances                                  │
│   → If auth error: state = .invalidCredentials, STOP        │
│   → If other error: state = .error, STOP                    │
│ - Parse instance metadata                                   │
│ - Store in instances array                                  │
│   → If empty: state = .noDatabases, STOP                    │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ RDSMonitoringService.fetchMetrics()                         │
│ - Time window: 1 hour ago → now                             │
│ - For each instance:                                        │
│   - Build MetricDataQuery for CPU, Connections, Storage     │
│   - Call GetMetricData                                      │
│   - Parse metric values (first = most recent)               │
│   - Calculate derived metrics                               │
│   - Handle N/A (-1) for missing data                        │
│   - Store in metricsCache                                   │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ RDSMonitoringService.checkAlerts()                          │
│ - For each instance with metrics:                           │
│   - Evaluate thresholds (> configured %, ignoring -1)       │
│   - If breached → AlertManager.sendAlert()                  │
│   - If recovered → AlertManager.clearAlert()                │
│ state = .loaded                                             │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ AlertManager                                                │
│ - Check if running as bundle (Bundle.main.bundleIdentifier) │
│ - Log alert to console (always)                             │
│ - Send UNNotification (only if bundled)                     │
│ - Check deduplication rules                                 │
│ - Update alert state tracking                               │
└────────────────────┬────────────────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────────────────┐
│ AppDelegate.updateMenu()                                    │
│ - Switch on monitoringService.state:                        │
│   - .loading → Show "Loading..."                            │
│   - .noCredentials → Show setup instructions + docs link    │
│   - .invalidCredentials → Show error + hints                │
│   - .noDatabases → Show "No RDS instances" + region         │
│   - .error → Show error message                             │
│   - .loaded → Show instances with metrics                   │
│ - Apply color coding (filter -1 for max calculation)        │
│ - Update "Last updated" timestamp                           │
└─────────────────────────────────────────────────────────────┘
```

---

## Architecture

### Project Structure

```
PulseBar/
├── Package.swift                 # SPM configuration
├── Package.resolved              # Locked dependency versions
├── Info.plist                    # macOS app metadata (LSUIElement=true)
├── Makefile                      # Build automation
├── README.md                     # User documentation
├── CONTRIBUTING.md               # Contribution guidelines
├── CODE_OF_CONDUCT.md            # Community standards
├── SECURITY.md                   # Security policy
├── LICENSE                       # MIT License
├── agents.md                     # This file
├── .gitignore                    # Git ignore rules
├── Assets/
│   └── screenshot.png            # App screenshot for README
├── Icons/
│   └── *.png                     # App icons (16px to 1024px; WebP-encoded)
├── .github/
│   ├── ISSUE_TEMPLATE/           # Bug report & feature request templates
│   ├── PULL_REQUEST_TEMPLATE.md  # PR template
│   └── workflows/
│       ├── pr-validation.yml     # CI for pull requests
│       └── release.yml           # Build on release
├── build/                        # Built app bundle (gitignored)
│   └── PulseBar.app/
└── Sources/
    ├── main.swift                          # Entry point
    ├── AppDelegate.swift                   # UI & app lifecycle
    ├── AWSCredentialsReader.swift          # Credential parsing
    ├── RDSMonitoringService.swift          # AWS API integration (RDS, CloudWatch, PI)
    ├── AlertManager.swift                  # Notification logic
    ├── Settings.swift                      # User preferences (threshold, interval)
    ├── DatabaseDetailWindowController.swift # Detail window + DetailViewModel (auto-sizes to fit)
    ├── MetricsDashboardView.swift          # SwiftUI + Charts dashboard
    ├── QueryDetailWindowController.swift   # Query drill-down window + QueryDetailViewModel
    ├── QueryDetailView.swift               # SwiftUI view for the query drill-down
    └── Models.swift                        # Data structures
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
  - Build and update NSMenu based on `MonitoringState`
  - Handle user interactions (profile/region selection, refresh)
  - Coordinate RDSMonitoringService
  - Manage 15-minute refresh timer
  - Request notification permissions (gracefully handles non-bundle)
  - Display appropriate UI for each state (loading, errors, no databases, etc.)
- **Key Methods**:
  - `applicationDidFinishLaunching()` - Setup
  - `updateMenu()` - Rebuild menu based on current state
  - `createInstanceMenuItem()` - Format instance data for display
  - `createMetricMenuItem()` - Format individual metric with color
  - `refreshData()` - Trigger data refresh
  - `startAutoRefresh()` - Setup auto-refresh timer (configurable interval)
  - `requestNotificationPermissions()` - Safe notification setup
  - `openAWSCredentialsDocs()` - Open AWS CLI docs in browser

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
  - `credentialsFileExists()` - Check if ~/.aws/credentials exists
  - `hasCredentials(profile:)` - Check if a profile has valid credentials
- **Pattern**: Singleton (`shared` instance)

#### RDSMonitoringService.swift
- **Purpose**: AWS API integration and data management
- **Responsibilities**:
  - Manage current profile/region state
  - Fetch RDS instances via SDK
  - Fetch CloudWatch metrics via SDK
  - Calculate derived metrics
  - Handle N/A values (-1)
  - Cache metrics in memory
  - Trigger alert checks
- **Key Methods**:
  - `refresh()` - Main refresh orchestrator
  - `fetchRDSInstances()` - Call RDS API
  - `fetchMetrics()` - Call CloudWatch API (1-hour window)
  - `fetchInstanceMetrics()` - Per-instance metric collection
  - `checkAlerts()` - Evaluate alert conditions
  - `createRDSClient()` - Initialize RDS SDK client
  - `createCloudWatchClient()` - Initialize CloudWatch SDK client
  - `estimateMaxConnections()` - Estimate max_connections from instance class
- **State**:
  - `currentProfile: String` - Default: "default"
  - `currentRegion: String` - Default: "us-west-2"
  - `instances: [RDSInstance]` - Current RDS instances
  - `metricsCache: [String: RDSMetrics]` - Latest metrics by instance ID
  - `lastUpdateTime: Date?` - Timestamp of last successful refresh
  - `state: MonitoringState` - Current state (loading, loaded, error states)

#### AlertManager.swift
- **Purpose**: Notification management with deduplication
- **Responsibilities**:
  - Track alert state per instance
  - Implement deduplication logic
  - Send macOS notifications via `UNUserNotificationCenter` when bundled, falling back to the
    legacy `NSUserNotification` path for unsigned/local builds
  - Always log alerts to console
  - Clear alerts when recovered
- **Key Methods**:
  - `sendAlert()` - Evaluate and send notification
  - `clearAlert()` - Remove alert state
  - `sendNotification()` - Deliver via UNUserNotificationCenter, with legacy fallback
  - `sendLegacyNotification()` - NSUserNotification fallback (no entitlement required)
  - `getAlertingMetrics()` - Convert metrics to alerting set (ignores -1)
- **Note**: `RDSMonitoringService.alertingInstances()` surfaces breaching instances in the menu
  banner so alerts remain visible even when OS notifications are blocked.
- **State**:
  - `activeAlerts: [String: AlertState]` - Current alerts by instance ID
  - `notificationsAvailable: Bool` - True if Bundle.main.bundleIdentifier != nil

#### Models.swift
- **Purpose**: Data structures and state management
- **Enums**:
  - `MonitoringState` - Current state of the monitoring service
  - `MetricRange` - 1D / 7D / 30D window for the detail dashboard (seconds + period)
  - `MetricUnit` - how a series is formatted (percent, bytes→GB/MB, count, /s)
- **Structures**:
  - `RDSInstance` - RDS instance metadata (incl. `dbiResourceId`, `performanceInsightsEnabled`)
  - `RDSMetrics` - Collected and calculated menu metrics (incl. `dbLoad`)
  - `AlertState` - Alert tracking state
  - `MetricPoint` / `MetricSeries` / `InstanceTimeSeries` - dashboard time-series
  - `TopItem` / `PerformanceInsightsData` - Performance Insights breakdowns (`TopItem.digestId`
    carries the query digest id for the drill-down)
  - `QueryDetail` / `SQLStatement` - per-query drill-down data (load over time, statements behind
    the digest, users/hosts)
- **Methods**:
  - `RDSMetrics.hasAlert()` - Check if any threshold breached (ignores -1)
  - `RDSMetrics.getAlertMessage()` - Format notification message (ignores -1)

##### MonitoringState Enum
```swift
enum MonitoringState: Equatable {
    case loading                          // Initial state or fetching data
    case loaded                           // Successfully loaded instances
    case noCredentials                    // ~/.aws/credentials not found
    case invalidCredentials(message: String)  // Auth failed or expired
    case noDatabases                      // No RDS instances in region
    case error(message: String)           // General error
}
```

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

#### N/A Value Handling
```swift
// Pattern: Use -1 to indicate "no data available"
var storageUsedPercent: Double = 0
if freeStorageSpace > 0 && allocatedStorageBytes > 0 {
    let usedStorageBytes = allocatedStorageBytes - freeStorageSpace
    storageUsedPercent = (usedStorageBytes / allocatedStorageBytes) * 100
} else if allocatedStorageBytes > 0 && freeStorageSpace == 0 {
    storageUsedPercent = -1  // N/A
}

// In UI, check for -1
if value < 0 {
    item.title = "⚪ \(label): N/A"
} else {
    // normal display with color coding
}

// In alert logic, filter out -1
let validValues = [cpu, connections, storage].filter { $0 >= 0 }
```

#### State-Based UI Updates
```swift
// Pattern: Switch on MonitoringState to render appropriate UI
switch monitoringService.state {
case .loading:
    // Show loading indicator
    
case .noCredentials:
    // Show setup instructions and link to AWS docs
    
case .invalidCredentials(let message):
    // Show error and suggest checking profile or refreshing token
    
case .noDatabases:
    // Show "No RDS instances found in {region}"
    
case .error(let message):
    // Show generic error with truncated message
    
case .loaded:
    // Render instance list with metrics
}
```

### AWS SDK Patterns

#### Client Initialization (Current API)
```swift
private func createRDSClient() async throws -> RDSClient {
    guard let credentials = AWSCredentialsReader.shared.getCredentials(profile: currentProfile) else {
        throw NSError(domain: "PulseBar", code: 1, 
            userInfo: [NSLocalizedDescriptionKey: "Failed to load AWS credentials"])
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
```

#### CloudWatch Metric Queries
```swift
// Pattern: Use CloudWatchClientTypes namespace for all types
var queries: [CloudWatchClientTypes.MetricDataQuery] = []

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
        period: 300,  // 5 minutes for CPU/connections
        stat: "Average"
    )
))

// Storage needs longer period
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
        period: 3600,  // 1 hour for storage (more reliable)
        stat: "Average"
    )
))
```

### Notification Patterns

#### Safe Permission Request
```swift
private func requestNotificationPermissions() {
    // Check if we're running as a proper app bundle
    guard Bundle.main.bundleIdentifier != nil else {
        print("⚠️ Running without app bundle - notifications disabled")
        return
    }
    
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
        if let error = error {
            print("Notification permission error: \(error)")
        }
    }
}
```

#### Safe Notification Sending
```swift
private func sendNotification(message: String) {
    // Always log to console
    print("🚨 ALERT: \(message)")
    
    // Only send system notification if running as bundled app
    guard notificationsAvailable else {
        return
    }
    
    let content = UNMutableNotificationContent()
    content.title = "PulseBar - RDS Alert"
    content.body = message
    content.sound = .default
    
    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
    )
    
    UNUserNotificationCenter.current().add(request) { error in
        if let error = error {
            print("Error sending notification: \(error)")
        }
    }
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

### Testing Checklist

1. **Credentials & States**:
   - [ ] App loads with valid credentials
   - [ ] Shows "AWS credentials not found" when ~/.aws/credentials missing
   - [ ] Shows "Invalid credentials" when credentials are expired/invalid
   - [ ] Shows "No RDS instances found" for empty regions
   - [ ] Profile switching works
   - [ ] Region switching works

2. **Data Fetching**:
   - [ ] RDS instances load correctly
   - [ ] Metrics appear for each instance
   - [ ] Storage shows actual value (not N/A or 100%)
   - [ ] Manual refresh updates data
   - [ ] Auto-refresh triggers on the configured interval

3. **UI**:
   - [ ] Menu bar icon appears
   - [ ] Menu opens on click
   - [ ] Color coding reflects metric values
   - [ ] N/A displays correctly for missing data
   - [ ] Submenus expand correctly

4. **Alerts**:
   - [ ] Notification and/or in-menu banner appears when a metric exceeds the threshold
   - [ ] No duplicate notifications for same condition
   - [ ] New notification when different metric breaches
   - [ ] Alert clears when metrics recover
   - [ ] Console shows alert even without bundle
   - [ ] Changing the threshold/interval in Settings takes effect

### Build and Release

```bash
# Development
swift build          # Debug build
swift run            # Run debug (no notifications)
make run             # Same as swift run

# Release
swift build -c release    # Release build
make build                # Same as above
# Binary at: .build/release/PulseBar

# Installation
make install         # Creates .app and copies to /Applications
make clean           # Remove build artifacts
```

### CI/CD

GitHub Actions workflows in `.github/workflows/`:

- **pr-validation.yml**: Runs on PRs and pushes to `main`
  - Builds debug and release configurations
  - Validates Package.swift
  - Runs tests (if available)

- **release.yml**: Runs when a GitHub release is published
  - Builds release binary
  - Creates .app bundle with icons
  - Uploads ZIP and checksum to release

### Known Limitations

1. **Max Connections Estimation**: Currently estimates based on instance class naming. Should query RDS parameter groups for actual `max_connections` value.

2. **Menu snapshot only**: The menu bar shows the current snapshot; historical trends live in the detail dashboard (1D/7D/30D charts), not the menu.

3. **Single Account**: No multi-account aggregation. Each profile is queried separately.

4. **Performance Insights retention**: PI panels and the query drill-down only cover the last 7 days (an API constraint); the 30D range is clamped accordingly.

5. **Notifications Require Bundle**: Must use `make install` for macOS notifications.

6. **Storage Data Availability**: CloudWatch may not report FreeStorageSpace frequently for all instances.

---

## Quick Reference

### Key Files for Common Tasks

| Task                     | Primary File(s)                              | Method(s)                                              |
| ------------------------ | -------------------------------------------- | ------------------------------------------------------ |
| Add new menu metric      | `RDSMonitoringService.swift`, `Models.swift` | `fetchInstanceMetrics()`, `RDSMetrics` struct          |
| Add/change dashboard chart | `RDSMonitoringService.swift`, `MetricsDashboardView.swift` | `fetchTimeSeries()`, `InstanceTimeSeries`, chart group |
| Change Performance Insights panels | `RDSMonitoringService.swift`, `MetricsDashboardView.swift` | `fetchPerformanceInsights()`, `TopPanel`, `TopQueriesPanel` |
| Change query drill-down   | `RDSMonitoringService.swift`, `QueryDetailWindowController.swift`, `QueryDetailView.swift` | `fetchQueryDetail()`, `fetchFullSQL()`, `QueryDetailViewModel` |
| Change menu UI layout    | `AppDelegate.swift`                          | `updateMenu()`, `createInstanceMenuItem()`             |
| Change detail window      | `DatabaseDetailWindowController.swift`       | `init`, `reload(range:)`, `present()`, `resizeToFit(contentHeight:)` |
| Modify alert logic       | `AlertManager.swift`, `Models.swift`         | `sendAlert()`, `hasAlert()`, `getAlertingMetrics()`    |
| Change settings/defaults | `Settings.swift`, `AppDelegate.swift`        | `Settings.shared`, `buildSettingsMenuItem()`           |
| Change replica grouping  | `AppDelegate.swift`, `RDSMonitoringService.swift` | `updateMenu()` (.loaded), `readReplicaSource`     |
| Add AWS profile support  | `AWSCredentialsReader.swift`                 | `getCredentials()`, `listProfiles()`                   |
| Change refresh interval  | `Settings.swift`, `AppDelegate.swift`        | `refreshIntervalMinutes`, `startAutoRefresh()`         |
| Change default region    | `RDSMonitoringService.swift`                 | `currentRegion` property                               |
| Change menu-bar icon     | `AppDelegate.swift`                          | `applicationDidFinishLaunching` (SF Symbol)            |

### Important Constants

| Constant          | Value             | Location             | Description                          |
| ----------------- | ----------------- | -------------------- | ------------------------------------ |
| Refresh interval  | 15 min (default)  | Settings             | Configurable 1–60 min                |
| CloudWatch window | 3600s (1 hour)    | RDSMonitoringService | Time range for menu metrics          |
| CPU/Conn period   | 300s (5 min)      | RDSMonitoringService | CloudWatch aggregation               |
| Storage period    | 3600s (1 hour)    | RDSMonitoringService | Longer for reliability               |
| Dashboard periods | 300/3600/21600s   | Models (MetricRange) | 1D / 7D / 30D chart aggregation      |
| PI window cap     | 7 days            | RDSMonitoringService | Performance Insights StartTime limit |
| Alert threshold   | 50% (default)     | Settings             | Configurable; applied in Models/AlertManager |
| Default region    | us-west-2         | RDSMonitoringService | Initial region                       |

---

## Troubleshooting Development Issues

### "Cannot find type 'MetricDataQuery' in scope"
Use fully qualified name: `CloudWatchClientTypes.MetricDataQuery`

### "Cannot find 'AWSCredentialsProvider' in scope"
Old API. Use `StaticAWSCredentialIdentityResolver` with `AWSCredentialIdentity`.

### "bundleProxyForCurrentProcess is nil"
Running via `swift run` without app bundle. Use `make install` for notifications.

### Storage always shows 100% or N/A
- Check CloudWatch time window (should be 1 hour)
- Check storage period (should be 3600s)
- Verify `FreeStorageSpace` is being returned in CloudWatch response

### Build takes forever
First build downloads ~200MB of AWS SDK. Subsequent builds are fast.

---

**Last Updated**: 2026-01-18  
**Version**: 1.1.0  
**Maintainer**: PulseBar Development Team
