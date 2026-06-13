# Changelog

All notable changes to PulseBar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Detail dashboard**: click **📊 Open Details…** on any database to open a floating window
  with six time-series charts grouped by type — CPU (`CPUUtilization`, `DBLoad`),
  Memory (`FreeableMemory`, `SwapUsage`), and Storage (`FreeStorageSpace`, Read/Write IOPS) —
  with a **1D / 7D / 30D** range toggle (defaults to 1D).
- **Sessions metric** in the per-database menu, using Performance Insights `DBLoad`
  (average active sessions), falling back to the raw connection count when PI is disabled.
- **Performance Insights panels**: Top Queries, Top Users, and Top Hosts by average active
  sessions, shown in the detail dashboard (requires `pi:DescribeDimensionKeys`).
- **In-menu alert banner** listing instances that breach thresholds, so alerts are visible
  even when system notifications are suppressed.
- **Configurable settings** (⚙️ Settings submenu): alert threshold (default 50%) and auto-refresh
  interval (1–60 min), persisted in UserDefaults.
- **Read-replica grouping**: replicas are nested under their primary in the menu, with `ReplicaLag`.
- **Events & Alarms panel** in the detail window: recent RDS events (`DescribeEvents`) and active
  CloudWatch alarms (`DescribeAlarms`, ALARM state).
- **Open in AWS Console**: per-database deep link to the RDS console.
- GitHub issue templates (bug report, feature request) and this changelog.

### Changed

- The menu-bar icon is now drawn from an SF Symbol (`chart.bar.xaxis`) at runtime instead of a
  bundled image. It adapts to light/dark mode and renders in every run mode.
- Notifications now fall back to a legacy delivery path when `UNUserNotificationCenter` is
  unavailable (e.g. unsigned local builds).
- Added the `AWSPI` (Performance Insights) dependency.

### Fixed

- **Missing menu-bar icon**: the bundled icon files were WebP-encoded with a `.png` extension
  (which `NSImage(contentsOfFile:)` cannot decode) and the `Makefile`/CI referenced a
  wrong-case `icons/` directory. The icon is now an SF Symbol; the Dock icon is re-encoded to
  real PNG via `sips` at build time, and the path case is corrected.

## [1.0.0]

### Added

- Initial release: menu-bar monitoring of RDS instances (CPU, connections, storage, activity)
  via CloudWatch, with 15-minute auto-refresh, threshold alerts, color-coded status, and
  multi-profile/region support.
