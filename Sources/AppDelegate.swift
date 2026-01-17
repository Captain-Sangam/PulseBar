import Cocoa
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var monitoringService: RDSMonitoringService!
    var refreshTimer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions (only works in bundled app)
        requestNotificationPermissions()
        
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // Try to load icon from bundle resources
            if let iconPath = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
               let icon = NSImage(contentsOfFile: iconPath) {
                icon.isTemplate = true  // Adapts to light/dark mode
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            } else {
                // Fallback to emoji when running outside bundle (swift run)
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
        
        menu.addItem(NSMenuItem.separator())
        
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
            for instance in monitoringService.instances {
                let metrics = monitoringService.getMetrics(for: instance.identifier)
                let menuItem = createInstanceMenuItem(instance: instance, metrics: metrics)
                menu.addItem(menuItem)
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
    
    func createInstanceMenuItem(instance: RDSInstance, metrics: RDSMetrics?) -> NSMenuItem {
        let item = NSMenuItem()
        
        // Instance name as title
        item.title = instance.identifier
        
        // Create submenu with details
        let submenu = NSMenu()
        
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
            
            // Activity (raw connections)
            let activityItem = NSMenuItem(title: "Activity: \(Int(metrics.currentConnections)) connections", action: nil, keyEquivalent: "")
            activityItem.isEnabled = false
            submenu.addItem(activityItem)
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
        
        // Handle N/A case (value = -1)
        if value < 0 {
            item.title = "⚪ \(label): N/A"
            item.isEnabled = false
            return item
        }
        
        item.title = "\(label): \(String(format: "%.1f", value))\(unit)"
        item.isEnabled = false
        
        // Color code
        if value > 75 {
            item.title = "🔴 " + item.title
        } else if value > 50 {
            item.title = "🟡 " + item.title
        } else {
            item.title = "🟢 " + item.title
        }
        
        return item
    }
    
    @objc func toggleMenu() {
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
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
        // Refresh every 15 minutes (900 seconds)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
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
