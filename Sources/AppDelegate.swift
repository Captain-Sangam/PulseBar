import Cocoa
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var monitoringService: RDSMonitoringService!
    var refreshTimer: Timer?
    var detailWindows: [String: DatabaseDetailWindowController] = [:]
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions (only works in bundled app)
        requestNotificationPermissions()
        
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // Use an SF Symbol template image. This renders crisply at every scale, adapts to
            // light/dark automatically, and works in every run mode (no bundled asset needed) —
            // avoiding both the WebP-decode failure and the icon-path issues of the old approach.
            if let icon = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "PulseBar") {
                icon.isTemplate = true
                button.image = icon
            } else {
                // Last-resort fallback for very old systems without the symbol.
                button.title = "📊"
            }
            button.action = #selector(toggleMenu)
            button.target = self
        }
        
        // Initialize monitoring service
        monitoringService = RDSMonitoringService()
        
        // Create menu
        setupMenu()
        
        // Start auto-refresh timer (15 minutes)
        startAutoRefresh()
        
        // Initial refresh
        refreshData()
    }
    
    func setupMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false
        updateMenu()
    }
    
    func updateMenu() {
        menu.removeAllItems()
        
        // Profile selector
        let profileMenu = NSMenu()
        let profiles = AWSCredentialsReader.shared.listProfiles()
        for profile in profiles {
            let item = NSMenuItem(title: profile, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.state = (profile == monitoringService.currentProfile) ? .on : .off
            profileMenu.addItem(item)
        }
        let profileItem = NSMenuItem(title: "Profile: \(monitoringService.currentProfile)", action: nil, keyEquivalent: "")
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)
        
        // Region selector
        let regionMenu = NSMenu()
        let regions = ["us-east-1", "us-west-2", "eu-west-1", "ap-southeast-1", "ap-northeast-1"]
        for region in regions {
            let item = NSMenuItem(title: region, action: #selector(selectRegion(_:)), keyEquivalent: "")
            item.target = self
            item.state = (region == monitoringService.currentRegion) ? .on : .off
            regionMenu.addItem(item)
        }
        let regionItem = NSMenuItem(title: "Region: \(monitoringService.currentRegion)", action: nil, keyEquivalent: "")
        regionItem.submenu = regionMenu
        menu.addItem(regionItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Refresh button
        let refreshItem = NSMenuItem(title: "🔄 Refresh Now", action: #selector(refreshData), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        // Settings submenu (alert threshold + refresh interval)
        menu.addItem(buildSettingsMenuItem())

        menu.addItem(NSMenuItem.separator())

        // Alert banner — a guaranteed-visible signal that surfaces breaching instances even
        // when OS notifications are suppressed (unsigned build, denied permission, etc.).
        if monitoringService.state == .loaded {
            let alerting = monitoringService.alertingInstances()
            if !alerting.isEmpty {
                let header = NSMenuItem(title: "🚨 \(alerting.count) instance\(alerting.count == 1 ? "" : "s") need attention", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                for entry in alerting {
                    let line = NSMenuItem(title: "   \(entry.instance.identifier): \(entry.reason)", action: nil, keyEquivalent: "")
                    line.isEnabled = false
                    menu.addItem(line)
                }
                menu.addItem(NSMenuItem.separator())
            }
        }

        // Display based on current state
        switch monitoringService.state {
        case .loading:
            let item = NSMenuItem(title: "⏳ Loading...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            
        case .noCredentials:
            let item = NSMenuItem(title: "⚠️ AWS credentials not found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            
            let helpItem = NSMenuItem(title: "   Configure ~/.aws/credentials", action: nil, keyEquivalent: "")
            helpItem.isEnabled = false
            menu.addItem(helpItem)
            
            let docsItem = NSMenuItem(title: "📖 Open AWS CLI Docs", action: #selector(openAWSCredentialsDocs), keyEquivalent: "")
            docsItem.target = self
            menu.addItem(docsItem)
            
        case .invalidCredentials(let message):
            let item = NSMenuItem(title: "🔐 Invalid credentials", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            
            // Wrap message across multiple lines
            for line in wrapText(message, maxLength: 40) {
                let lineItem = NSMenuItem(title: "   \(line)", action: nil, keyEquivalent: "")
                lineItem.isEnabled = false
                menu.addItem(lineItem)
            }
            
            let hintItem = NSMenuItem(title: "   Check profile or refresh token", action: nil, keyEquivalent: "")
            hintItem.isEnabled = false
            menu.addItem(hintItem)
            
        case .noDatabases:
            let item = NSMenuItem(title: "📭 No RDS instances found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            
            let hintItem = NSMenuItem(title: "   in \(monitoringService.currentRegion)", action: nil, keyEquivalent: "")
            hintItem.isEnabled = false
            menu.addItem(hintItem)
            
        case .error(let message):
            let item = NSMenuItem(title: "❌ Error occurred", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            
            // Wrap message across multiple lines
            for line in wrapText(message, maxLength: 40) {
                let lineItem = NSMenuItem(title: "   \(line)", action: nil, keyEquivalent: "")
                lineItem.isEnabled = false
                menu.addItem(lineItem)
            }
            
        case .loaded:
            // Group read replicas under their source instance. Replicas whose source isn't in
            // the list (e.g. cross-region) are shown as top-level instances.
            let instances = monitoringService.instances
            let identifiers = Set(instances.map { $0.identifier })
            let replicasBySource = Dictionary(grouping: instances.filter {
                if let src = $0.readReplicaSource { return identifiers.contains(src) }
                return false
            }, by: { $0.readReplicaSource! })

            for instance in instances {
                // Skip replicas here; they're rendered nested under their primary below.
                if let src = instance.readReplicaSource, identifiers.contains(src) { continue }

                let metrics = monitoringService.getMetrics(for: instance.identifier)
                menu.addItem(createInstanceMenuItem(instance: instance, metrics: metrics))

                // Nested replicas, indented under the primary.
                for replica in replicasBySource[instance.identifier] ?? [] {
                    let replicaMetrics = monitoringService.getMetrics(for: replica.identifier)
                    menu.addItem(createInstanceMenuItem(instance: replica, metrics: replicaMetrics, isReplica: true))
                }
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Last updated
        if let lastUpdate = monitoringService.lastUpdateTime {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let timeStr = formatter.string(from: lastUpdate)
            let item = NSMenuItem(title: "Last updated: \(timeStr)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    func createInstanceMenuItem(instance: RDSInstance, metrics: RDSMetrics?, isReplica: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()

        // Instance name as title. Replicas are indented and tagged so the hierarchy reads clearly.
        item.title = isReplica ? "    ↳ \(instance.identifier)  (replica)" : instance.identifier

        // Create submenu with details
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        // Open the full monitoring dashboard. This is the actionable row (the parent item
        // owns a submenu, so its own action would not fire reliably).
        let detailItem = NSMenuItem(title: "📊 Open Details…", action: #selector(openDetail(_:)), keyEquivalent: "")
        detailItem.target = self
        detailItem.representedObject = instance.identifier
        submenu.addItem(detailItem)

        // Open this instance in the AWS RDS console.
        let consoleItem = NSMenuItem(title: "🔗 Open in AWS Console", action: #selector(openInConsole(_:)), keyEquivalent: "")
        consoleItem.target = self
        consoleItem.representedObject = instance.identifier
        submenu.addItem(consoleItem)

        submenu.addItem(NSMenuItem.separator())

        // Engine and class info
        let infoItem = NSMenuItem(title: "\(instance.engine) - \(instance.instanceClass)", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        submenu.addItem(infoItem)

        submenu.addItem(NSMenuItem.separator())
        
        if let metrics = metrics {
            // CPU
            let cpuItem = createMetricMenuItem(label: "CPU", value: metrics.cpuUtilization, unit: "%")
            submenu.addItem(cpuItem)
            
            // Connections
            let connItem = createMetricMenuItem(label: "Connections", value: metrics.connectionsUsedPercent, unit: "%")
            submenu.addItem(connItem)

            // Storage
            let storageItem = createMetricMenuItem(label: "Storage", value: metrics.storageUsedPercent, unit: "%")
            submenu.addItem(storageItem)

            // Informational readouts (no health status) grouped under their own header.
            submenu.addItem(NSMenuItem.separator())
            let detailsHeader = NSMenuItem(title: "Details", action: nil, keyEquivalent: "")
            detailsHeader.isEnabled = false
            submenu.addItem(detailsHeader)

            // Sessions — average active sessions (DBLoad). Falls back to raw connection count
            // when Performance Insights is disabled (dbLoad < 0).
            let sessionsTitle: String
            if metrics.dbLoad >= 0 {
                sessionsTitle = "Sessions: \(String(format: "%.2f", metrics.dbLoad)) avg active"
            } else {
                sessionsTitle = "Sessions: \(Int(metrics.currentConnections)) connections"
            }
            submenu.addItem(detailReadout(sessionsTitle))

            // Activity (raw connections)
            submenu.addItem(detailReadout("Activity: \(Int(metrics.currentConnections)) connections"))

            // Replica lag — shown only for read replicas reporting lag data.
            if isReplica && metrics.replicaLag >= 0 {
                submenu.addItem(detailReadout("Replica lag: \(String(format: "%.1f", metrics.replicaLag))s"))
            }
        } else {
            let loadingItem = NSMenuItem(title: "Loading metrics...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            submenu.addItem(loadingItem)
        }
        
        item.submenu = submenu
        
        // Color-code the main item
        if let metrics = metrics {
            // Filter out -1 (N/A) values when determining max
            let validValues = [metrics.cpuUtilization, metrics.connectionsUsedPercent, metrics.storageUsedPercent]
                .filter { $0 >= 0 }
            let maxValue = validValues.max() ?? 0
            
            if maxValue > 75 {
                item.title = "🔴 " + item.title
            } else if maxValue > 50 {
                item.title = "🟡 " + item.title
            } else {
                item.title = "🟢 " + item.title
            }
        }
        
        return item
    }
    
    func createMetricMenuItem(label: String, value: Double, unit: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false

        // Handle N/A case (value = -1). Use a neutral gray dot so the row still aligns.
        if value < 0 {
            item.title = "\(label): N/A"
            item.image = statusDot(color: .systemGray)
            return item
        }

        item.title = "\(label): \(String(format: "%.1f", value))\(unit)"

        // Color code via a leading dot image (consistent width keeps every row aligned).
        let color: NSColor
        if value > 75 {
            color = .systemRed
        } else if value > 50 {
            color = .systemYellow
        } else {
            color = .systemGreen
        }
        item.image = statusDot(color: color)

        return item
    }

    /// An informational, non-status submenu row (e.g. Sessions, Activity). Indented slightly so it
    /// reads as a nested readout under the "Details" header rather than a health metric.
    private func detailReadout(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "   \(title)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A small filled circle used as a menu item's leading image. Using an image (rather than an
    /// emoji prefix) gives every metric row the same indent, so labels line up.
    private func statusDot(color: NSColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 8, height: 8)).fill()
        image.unlockFocus()
        return image
    }
    
    @objc func toggleMenu() {
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
    }
    
    func buildSettingsMenuItem() -> NSMenuItem {
        let settingsMenu = NSMenu()

        // Alert threshold
        let thresholdHeader = NSMenuItem(title: "Alert threshold", action: nil, keyEquivalent: "")
        thresholdHeader.isEnabled = false
        settingsMenu.addItem(thresholdHeader)
        for option in Settings.thresholdOptions {
            let item = NSMenuItem(title: "   \(Int(option))%", action: #selector(selectThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option
            item.state = (option == Settings.shared.alertThreshold) ? .on : .off
            settingsMenu.addItem(item)
        }

        settingsMenu.addItem(NSMenuItem.separator())

        // Refresh interval
        let intervalHeader = NSMenuItem(title: "Refresh interval", action: nil, keyEquivalent: "")
        intervalHeader.isEnabled = false
        settingsMenu.addItem(intervalHeader)
        for minutes in Settings.intervalOptions {
            let label = minutes == 1 ? "   1 minute" : "   \(minutes) minutes"
            let item = NSMenuItem(title: label, action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            item.state = (minutes == Settings.shared.refreshIntervalMinutes) ? .on : .off
            settingsMenu.addItem(item)
        }

        let settingsItem = NSMenuItem(title: "⚙️ Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        return settingsItem
    }

    @objc func selectThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Settings.shared.alertThreshold = value
        updateMenu()  // refresh checkmarks + alert banner
    }

    @objc func selectInterval(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        Settings.shared.refreshIntervalMinutes = minutes
        startAutoRefresh()  // restart timer with new interval
        updateMenu()
    }

    @objc func openDetail(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let instance = monitoringService.instance(for: identifier) else {
            return
        }

        // Reuse an existing window for this instance if one is open; otherwise create it.
        if let existing = detailWindows[identifier] {
            existing.present()
            return
        }

        let controller = DatabaseDetailWindowController(instance: instance, service: monitoringService)
        controller.onClose = { [weak self] in
            self?.detailWindows.removeValue(forKey: identifier)
        }
        detailWindows[identifier] = controller
        controller.present()
    }

    @objc func openInConsole(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        let region = monitoringService.currentRegion
        // RDS console deep link to the instance's detail page.
        let urlString = "https://\(region).console.aws.amazon.com/rds/home?region=\(region)#database:id=\(identifier);is-cluster=false"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func selectProfile(_ sender: NSMenuItem) {
        monitoringService.currentProfile = sender.title
        refreshData()
    }
    
    @objc func selectRegion(_ sender: NSMenuItem) {
        monitoringService.currentRegion = sender.title
        refreshData()
    }
    
    @objc func refreshData() {
        Task {
            await monitoringService.refresh()
            await MainActor.run {
                updateMenu()
            }
        }
    }
    
    func startAutoRefresh() {
        // Refresh on the user-configured interval (default 15 minutes).
        refreshTimer?.invalidate()
        let interval = Settings.shared.refreshIntervalSeconds
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }
    
    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    @objc func openAWSCredentialsDocs() {
        if let url = URL(string: "https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Wraps text into multiple lines, breaking at word boundaries
    private func wrapText(_ text: String, maxLength: Int) -> [String] {
        let words = text.split(separator: " ")
        var lines: [String] = []
        var currentLine = ""
        
        for word in words {
            if currentLine.isEmpty {
                currentLine = String(word)
            } else if currentLine.count + 1 + word.count <= maxLength {
                currentLine += " " + word
            } else {
                lines.append(currentLine)
                currentLine = String(word)
            }
        }
        
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        
        return lines.isEmpty ? [text] : lines
    }
    
    private func requestNotificationPermissions() {
        // Check if we're running as a proper app bundle
        // UNUserNotificationCenter requires a valid bundle identifier
        guard Bundle.main.bundleIdentifier != nil else {
            print("⚠️ Running without app bundle - notifications disabled")
            print("   To enable notifications, run: make install && open /Applications/PulseBar.app")
            return
        }
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            } else if granted {
                print("✓ Notification permissions granted")
            } else {
                print("⚠️ Notification permissions denied")
            }
        }
    }
}
