import Cocoa
import SwiftUI

/// Backing store for the detail dashboard. The window controller fills these in
/// after each fetch; `MetricsDashboardView` observes them.
@MainActor
final class DetailViewModel: ObservableObject {
    @Published var series: InstanceTimeSeries?
    @Published var pi: PerformanceInsightsData?
    @Published var activity: InstanceActivity?
    @Published var range: MetricRange = .day
    @Published var isLoading = false
    @Published var errorMessage: String?

    let instanceName: String
    let engine: String

    /// Invoked by the view when the user picks a different range.
    var onRangeChange: ((MetricRange) -> Void)?

    init(instanceName: String, engine: String) {
        self.instanceName = instanceName
        self.engine = engine
    }
}

/// A floating window hosting the SwiftUI monitoring dashboard for one RDS instance.
final class DatabaseDetailWindowController: NSWindowController, NSWindowDelegate {
    private let instance: RDSInstance
    private let service: RDSMonitoringService
    private let model: DetailViewModel

    /// Called when the window closes so the owner can drop its reference.
    var onClose: (() -> Void)?

    init(instance: RDSInstance, service: RDSMonitoringService) {
        self.instance = instance
        self.service = service
        self.model = DetailViewModel(instanceName: instance.identifier, engine: instance.engine)

        // Size the window so all three chart groups are visible without scrolling, while
        // staying within the visible screen height (minus menu bar / Dock).
        let preferredHeight: CGFloat = 980
        let availableHeight = NSScreen.main?.visibleFrame.height ?? preferredHeight
        let height = min(preferredHeight, availableHeight - 40)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(instance.identifier) — \(instance.engine)"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        window.delegate = self
        model.onRangeChange = { [weak self] newRange in
            self?.reload(range: newRange)
        }
        window.contentView = NSHostingView(rootView: MetricsDashboardView(model: model))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Fetch (or re-fetch) data for the given range and push results into the view model.
    func reload(range: MetricRange) {
        model.range = range
        model.isLoading = true
        model.errorMessage = nil

        let instance = self.instance
        let service = self.service

        Task {
            do {
                async let series = service.fetchTimeSeries(instanceId: instance.identifier, range: range)
                async let pi = service.fetchPerformanceInsights(instance: instance, range: range)
                async let activity = service.fetchInstanceActivity(instanceId: instance.identifier)
                let (loadedSeries, loadedPI, loadedActivity) = try await (series, pi, activity)
                await MainActor.run {
                    self.model.series = loadedSeries
                    self.model.pi = loadedPI
                    self.model.activity = loadedActivity
                    self.model.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.model.errorMessage = (error as NSError).localizedDescription
                    self.model.isLoading = false
                }
            }
        }
    }

    /// Show the window and kick off the initial (default-range) load.
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if model.series == nil {
            reload(range: model.range)
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
