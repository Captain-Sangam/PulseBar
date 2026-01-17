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
  - Parameter group (for max_connections lookup - future)

#### Refresh Behavior
- Auto-refresh every 15 minutes (900 seconds)
- Manual refresh via menu button
- In-memory cache only (no persistence)

### 3. Metrics Collection

#### CloudWatch Metrics (per instance)

| Metric | CloudWatch Name | Statistic | Period | Notes |
|--------|----------------|-----------|--------|-------|
| CPU % | `CPUUtilization` | Average | 300s | Direct display |
| Connections | `DatabaseConnections` | Average | 300s | Activity + % calculation |
| Free Storage | `FreeStorageSpace` | Average | **3600s** | Needs longer period for reliable data |

**Important**: Storage metric uses a 1-hour period because CloudWatch may not report FreeStorageSpace every 5 minutes for all instances.

#### Derived Metrics

| Metric | Formula | Description |
|--------|---------|-------------|
| Connections Used % | `(DatabaseConnections / max_connections) × 100` | Percentage of connection pool used |
| Storage Used % | `((AllocatedStorage × 1024³) - FreeStorageSpace) / (AllocatedStorage × 1024³) × 100` | Percentage of disk space used |

**Notes:**
- `AllocatedStorage` is in GiB, `FreeStorageSpace` is in bytes
- Storage shows `-1` (displayed as "N/A") when CloudWatch returns no data

#### Time Window
- Queries CloudWatch for the **last 1 hour** of data (not 15 minutes)
- This ensures reliable data retrieval even for less frequently reported metrics
- Uses the most recent (first) value from the response

### 4. Alerting System

#### Alert Thresholds
Trigger notification if **ANY** of these conditions are met:
- CPU Utilization > 50%
- Connections Used % > 50%
- Storage Used % > 50%
- Activity (raw connections) > 50% of max_connections

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
- Clear alert state when all metrics return below 50%

#### Notification Requirements
- **Only works when running as app bundle** (via `make install`)
- Running via `swift run` disables notifications (no bundle identifier)
- Alerts are always logged to console regardless of bundle status

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

// Implicit dependencies from AWS SDK:
- ClientRuntime
- AWSClientRuntime
- AwsCommonRuntimeKit
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
│   - Evaluate thresholds (>50%, ignoring -1)                 │
│   - If breached → AlertManager.sendAlert()                  │
│   - If recovered → AlertManager.clearAlert()                │
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
│ - Rebuild menu with latest data                             │
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
├── agents.md                     # This file
├── .gitignore                    # Git ignore rules
├── .github/
│   ├── PULL_REQUEST_TEMPLATE.md  # PR template
│   └── workflows/
│       ├── pr-validation.yml     # CI for pull requests
│       ├── release.yml           # Build on release
│       └── README.md             # Workflow documentation
├── build/                        # Built app bundle (gitignored)
│   └── PulseBar.app/
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
  - Request notification permissions (gracefully handles non-bundle)
- **Key Methods**:
  - `applicationDidFinishLaunching()` - Setup
  - `updateMenu()` - Rebuild menu with current data
  - `createInstanceMenuItem()` - Format instance data for display
  - `createMetricMenuItem()` - Format individual metric with color
  - `refreshData()` - Trigger data refresh
  - `startAutoRefresh()` - Setup 900s timer
  - `requestNotificationPermissions()` - Safe notification setup

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

#### AlertManager.swift
- **Purpose**: Notification management with deduplication
- **Responsibilities**:
  - Track alert state per instance
  - Implement deduplication logic
  - Check for bundle availability
  - Send macOS notifications (when bundled)
  - Always log alerts to console
  - Clear alerts when recovered
- **Key Methods**:
  - `sendAlert()` - Evaluate and send notification
  - `clearAlert()` - Remove alert state
  - `sendNotification()` - Wrapper for UNNotification
  - `getAlertingMetrics()` - Convert metrics to alerting set (ignores -1)
- **State**:
  - `activeAlerts: [String: AlertState]` - Current alerts by instance ID
  - `notificationsAvailable: Bool` - True if Bundle.main.bundleIdentifier != nil

#### Models.swift
- **Purpose**: Data structures
- **Structures**:
  - `RDSInstance` - RDS instance metadata
  - `RDSMetrics` - Collected and calculated metrics
  - `AlertState` - Alert tracking state
- **Methods**:
  - `RDSMetrics.hasAlert()` - Check if any threshold breached (ignores -1)
  - `RDSMetrics.getAlertMessage()` - Format notification message (ignores -1)

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

1. **Credentials**:
   - [ ] App loads with valid credentials
   - [ ] App handles missing credentials gracefully
   - [ ] Profile switching works
   - [ ] Region switching works

2. **Data Fetching**:
   - [ ] RDS instances load correctly
   - [ ] Metrics appear for each instance
   - [ ] Storage shows actual value (not N/A or 100%)
   - [ ] Manual refresh updates data
   - [ ] Auto-refresh triggers every 15 minutes

3. **UI**:
   - [ ] Menu bar icon appears
   - [ ] Menu opens on click
   - [ ] Color coding reflects metric values
   - [ ] N/A displays correctly for missing data
   - [ ] Submenus expand correctly

4. **Alerts** (requires `make install`):
   - [ ] Notification sent when metric > 50%
   - [ ] No duplicate notifications for same condition
   - [ ] New notification when different metric breaches
   - [ ] Alert clears when metrics recover
   - [ ] Console shows alert even without bundle

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

- **pr-validation.yml**: Runs on PRs to main/develop
  - Builds debug and release
  - Validates Package.swift
  - Checks for hardcoded credentials

- **release.yml**: Runs on GitHub release creation
  - Builds release binary
  - Creates .app bundle
  - Uploads ZIP to release
  - Includes SHA256 checksum

### Known Limitations

1. **Max Connections Estimation**: Currently estimates based on instance class naming. Should query RDS parameter groups for actual `max_connections` value.

2. **No Historical Data**: Only shows current snapshot. Future: Add trending/graphs.

3. **Single Account**: No multi-account aggregation. Each profile is queried separately.

4. **No Performance Insights**: Not integrated with RDS Performance Insights API.

5. **Notifications Require Bundle**: Must use `make install` for macOS notifications.

6. **Storage Data Availability**: CloudWatch may not report FreeStorageSpace frequently for all instances.

---

## Quick Reference

### Key Files for Common Tasks

| Task | Primary File(s) | Method(s) |
|------|----------------|-----------|
| Add new metric | `RDSMonitoringService.swift`, `Models.swift` | `fetchInstanceMetrics()`, `RDSMetrics` struct |
| Change UI layout | `AppDelegate.swift` | `updateMenu()`, `createInstanceMenuItem()` |
| Modify alert logic | `AlertManager.swift`, `Models.swift` | `sendAlert()`, `hasAlert()`, `getAlertingMetrics()` |
| Add AWS profile support | `AWSCredentialsReader.swift` | `getCredentials()`, `listProfiles()` |
| Change refresh interval | `AppDelegate.swift` | `startAutoRefresh()` (currently 900s) |
| Change default region | `RDSMonitoringService.swift` | `currentRegion` property |
| Adjust time window | `RDSMonitoringService.swift` | `fetchMetrics()` - `startTime` calculation |

### Important Constants

| Constant | Value | Location | Description |
|----------|-------|----------|-------------|
| Refresh interval | 900s (15 min) | AppDelegate | Auto-refresh timer |
| CloudWatch window | 3600s (1 hour) | RDSMonitoringService | Time range for metrics |
| CPU/Conn period | 300s (5 min) | RDSMonitoringService | CloudWatch aggregation |
| Storage period | 3600s (1 hour) | RDSMonitoringService | Longer for reliability |
| Alert threshold | 50% | Models.swift | All metrics |
| Default region | us-west-2 | RDSMonitoringService | Initial region |

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

**Last Updated**: 2026-01-17  
**Version**: 1.0.0  
**Maintainer**: PulseBar Development Team
