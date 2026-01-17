# PulseBar - RDS Monitor

A macOS menu bar app for monitoring AWS RDS instances with real-time health metrics and alerts.

## Features

- 📊 **Real-time Monitoring**: Track CPU, connections, storage, and activity for all RDS instances
- ⚡ **Auto-refresh**: Updates every 15 minutes automatically
- 🔔 **Smart Alerts**: macOS notifications when metrics exceed 50% (with deduplication)
- 🎨 **Color-coded Status**: Green (<50%), Yellow (50-75%), Red (>75%)
- 🔐 **AWS Integration**: Uses your existing `~/.aws/credentials` and `~/.aws/config`
- 🌍 **Multi-region/Profile**: Switch between AWS profiles and regions easily

## Metrics Tracked

For each RDS instance:

- **CPU Utilization** (%) - from CloudWatch `CPUUtilization`
- **Connections Used** (%) - `DatabaseConnections / max_connections * 100`
- **Storage Used** (%) - `(AllocatedStorage - FreeStorageSpace) / AllocatedStorage * 100`
- **Activity** - Current number of database connections

## Requirements

- macOS 13.0 or later
- Swift 5.9+
- AWS credentials configured at `~/.aws/credentials`
- IAM permissions:
  - `rds:DescribeDBInstances`
  - `cloudwatch:GetMetricData`

## Installation

### Option 1: Download Pre-built Release

1. Go to the [Releases page](https://github.com/yourusername/PulseBar/releases)
2. Download the latest `PulseBar-vX.X.X-macOS.zip`
3. Verify checksum (optional):
   ```bash
   shasum -a 256 -c PulseBar-vX.X.X-macOS.zip.sha256
   ```
4. Unzip and move to Applications:
   ```bash
   unzip PulseBar-vX.X.X-macOS.zip
   mv PulseBar.app /Applications/
   ```

### Option 2: Build from Source

```bash
# Clone the repository
git clone <repository-url>
cd PulseBar

# Build and install
make install
```

### Option 3: Build and Run Locally

```bash
# Run in debug mode
make run

# Or build release binary
make build
```

## AWS Credentials Setup

Ensure you have AWS credentials configured:

```bash
# ~/.aws/credentials
[default]
aws_access_key_id = YOUR_ACCESS_KEY
aws_secret_access_key = YOUR_SECRET_KEY

[production]
aws_access_key_id = PROD_ACCESS_KEY
aws_secret_access_key = PROD_SECRET_KEY

# ~/.aws/config
[default]
region = us-east-1

[profile production]
region = us-west-2
```

## Usage

1. Launch PulseBar from Applications or run `make run`
2. Click the 📊 icon in your menu bar
3. Select your AWS profile and region
4. View real-time metrics for all RDS instances
5. Click on any instance to see detailed metrics

### Menu Options

- **Profile Selector**: Switch between AWS profiles
- **Region Selector**: Change AWS region
- **Refresh Now**: Manual refresh (⌘R)
- **Instance List**: Click any instance for details
- **Quit**: Exit the application (⌘Q)

## Alert Behavior

Notifications are sent when any metric exceeds 50%:

- Alerts are deduplicated (won't spam for the same condition)
- New notifications sent if:
  - Different metrics breach thresholds
  - Instance recovers and breaches again
  - 15+ minutes since last alert for same condition

Example notification:

```
⚠️ RDS Alert: production-db
CPU: 72%
Connections: 61%
```

## Architecture

```
Timer (15 min)
   ↓
Load AWS Profile/Credentials
   ↓
DescribeDBInstances (RDS API)
   ↓
GetMetricData (CloudWatch API)
   ↓
Metric Calculations
   ↓
UI Update + Alert Engine
   ↓
macOS Notification Center
```

## Project Structure

```
PulseBar/
├── Sources/
│   ├── main.swift                    # App entry point
│   ├── AppDelegate.swift             # Menu bar UI & coordination
│   ├── AWSCredentialsReader.swift    # Reads ~/.aws files
│   ├── RDSMonitoringService.swift    # AWS SDK integration
│   ├── AlertManager.swift            # Notification logic
│   └── Models.swift                  # Data structures
├── Package.swift                     # Swift Package Manager config
├── Info.plist                        # App metadata
├── Makefile                          # Build commands
└── README.md
```

## Development

### Build Commands

```bash
# Debug build and run
make run

# Release build
make build

# Clean build artifacts
make clean

# Install to /Applications
make install
```

### Dependencies

- `aws-sdk-swift` (AWSRDS, AWSCloudWatch)

Dependencies are managed via Swift Package Manager and will be automatically resolved on build.

## Limitations (v1)

- No historical graphs or trends
- Basic max_connections estimation (not querying parameter groups)
- No Performance Insights integration
- Single account only (no multi-account aggregation)
- Read-only monitoring (cannot modify RDS instances)

## Troubleshooting

### "No credentials found"

Ensure `~/.aws/credentials` exists and has valid credentials for the selected profile.

### "Permission denied"

Verify your IAM user/role has these permissions:
- `rds:DescribeDBInstances`
- `cloudwatch:GetMetricData`

### Notifications not appearing

1. Check System Settings → Notifications → PulseBar
2. Ensure notifications are enabled
3. Restart the app if needed

## License

MIT License - See LICENSE file for details

## Contributing

Contributions welcome! Please open an issue or PR.

## Roadmap

- [ ] Parameter group querying for accurate max_connections
- [ ] Historical metric graphs
- [ ] Performance Insights integration
- [ ] Multi-account support
- [ ] Custom alert thresholds
- [ ] Export metrics to CSV/JSON
- [ ] Dark mode improvements
