import Cocoa
import SwiftUI

/// Backing store for the detail dashboard. The window controller fills these in
/// after each fetch; `MetricsDashboardView` observes them.
@MainActor
final class DetailViewModel: ObservableObject {
    @Published var series: InstanceTimeSeries?
    @Published var pi: PerformanceInsightsData?
    @Published var range: MetricRange = .day
    @Published var isLoading = false
    @Published var errorMessage: String?

    let instanceName: String
    let engine: String

    /// Invoked by the view when the user picks a different range.
    var onRangeChange: ((MetricRange) -> Void)?

    /// Invoked when a Top Query row is clicked, to open its drill-down window.
    var onOpenQuery: ((TopItem) -> Void)?

    /// Reports the dashboard's natural content height so the window can size to fit.
    var onContentHeight: ((CGFloat) -> Void)?

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

    /// Open query drill-down windows, keyed by digest id so each query opens at most once.
    private var queryWindows: [String: QueryDetailWindowController] = [:]

    /// Fixed content width; height is sized to fit the SwiftUI content so nothing scrolls.
    private static let contentWidth: CGFloat = 880
    private let hostingView: NSHostingView<MetricsDashboardView>

    init(instance: RDSInstance, service: RDSMonitoringService) {
        self.instance = instance
        self.service = service
        self.model = DetailViewModel(instanceName: instance.identifier, engine: instance.engine)

        // A starting height; `resizeToFitContent()` adjusts it once content lays out so the
        // whole dashboard is visible without a scroll bar.
        let availableHeight = NSScreen.main?.visibleFrame.height ?? 1000
        let height = min(1000, availableHeight - 40)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(instance.identifier) — \(instance.engine)"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        self.hostingView = NSHostingView(rootView: MetricsDashboardView(model: model))

        super.init(window: window)

        window.delegate = self
        model.onRangeChange = { [weak self] newRange in
            self?.reload(range: newRange)
        }
        model.onOpenQuery = { [weak self] item in
            self?.openQuery(item)
        }
        model.onContentHeight = { [weak self] height in
            self?.resizeToFit(contentHeight: height)
        }
        window.contentView = hostingView
    }

    /// Last height we sized to, so repeated identical preference reports don't thrash the window.
    private var lastFitHeight: CGFloat = 0

    /// Resize the window's height to the dashboard's reported content height (capped to the visible
    /// screen), so the whole dashboard shows without a scroll bar.
    private func resizeToFit(contentHeight: CGFloat) {
        guard let window = self.window, contentHeight > 1 else { return }
        let availableHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 1200
        let targetContentHeight = min(max(contentHeight, 520), availableHeight - 40)
        guard abs(targetContentHeight - lastFitHeight) > 1 else { return }
        lastFitHeight = targetContentHeight

        var frame = window.frame
        let chrome = frame.height - window.contentLayoutRect.height // title bar etc.
        let newHeight = targetContentHeight + chrome
        guard abs(newHeight - frame.height) > 1 else { return }
        // Keep the top edge fixed while growing/shrinking downward.
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: false)
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
                let (loadedSeries, loadedPI) = try await (series, pi)
                await MainActor.run {
                    self.model.series = loadedSeries
                    self.model.pi = loadedPI
                    self.model.isLoading = false
                    // The window resizes itself via the dashboard's ContentHeightKey preference.
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

    /// Open (or re-focus) the drill-down window for a Top Query row.
    private func openQuery(_ item: TopItem) {
        guard let digestId = item.digestId else {
            NSSound.beep()
            return
        }
        if let existing = queryWindows[digestId] {
            existing.present()
            return
        }
        let controller = QueryDetailWindowController(
            instance: instance,
            service: service,
            digestId: digestId,
            digestText: item.label
        )
        controller.onClose = { [weak self] in
            self?.queryWindows.removeValue(forKey: digestId)
        }
        queryWindows[digestId] = controller
        controller.present()
    }

    func windowWillClose(_ notification: Notification) {
        // Close any open child query windows along with the parent.
        for controller in queryWindows.values {
            controller.close()
        }
        queryWindows.removeAll()
        onClose?()
    }
}
