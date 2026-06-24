import Cocoa
import SwiftUI
import Charts

/// Backing store for the query drill-down window. The controller fills these in after each
/// fetch; `QueryDetailView` observes them.
@MainActor
final class QueryDetailViewModel: ObservableObject {
    @Published var detail: QueryDetail?
    @Published var range: MetricRange = .day
    @Published var isLoading = false
    @Published var errorMessage: String?

    /// The currently expanded statement's full SQL, keyed by statement id.
    @Published var fullSQL: [String: String] = [:]
    /// Statement ids whose full SQL is being fetched (to show a spinner).
    @Published var loadingSQL: Set<String> = []

    let digestText: String

    var onRangeChange: ((MetricRange) -> Void)?
    /// Asks the controller to resolve the full SQL for a statement id.
    var onLoadFullSQL: ((String) -> Void)?

    init(digestText: String) {
        self.digestText = digestText
    }
}

/// A floating window showing the per-query drill-down: load over time, the individual SQL
/// statements behind the digest, and the users / hosts that ran it. Opened from a Top Queries row.
final class QueryDetailWindowController: NSWindowController, NSWindowDelegate {
    private let instance: RDSInstance
    private let service: RDSMonitoringService
    private let digestId: String
    private let model: QueryDetailViewModel

    /// Called when the window closes so the owner can drop its reference.
    var onClose: (() -> Void)?

    init(instance: RDSInstance, service: RDSMonitoringService, digestId: String, digestText: String) {
        self.instance = instance
        self.service = service
        self.digestId = digestId
        self.model = QueryDetailViewModel(digestText: digestText)

        let preferredHeight: CGFloat = 760
        let availableHeight = NSScreen.main?.visibleFrame.height ?? preferredHeight
        let height = min(preferredHeight, availableHeight - 40)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Query — \(instance.identifier)"
        window.level = .floating
        window.isReleasedWhenClosed = false
        // Cascade so multiple query windows don't stack exactly on top of each other.
        window.center()

        super.init(window: window)

        window.delegate = self
        model.onRangeChange = { [weak self] newRange in
            self?.reload(range: newRange)
        }
        model.onLoadFullSQL = { [weak self] statementId in
            self?.loadFullSQL(statementId: statementId)
        }
        window.contentView = NSHostingView(rootView: QueryDetailView(model: model))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload(range: MetricRange) {
        model.range = range
        model.isLoading = true
        model.errorMessage = nil

        let instance = self.instance
        let service = self.service
        let digestId = self.digestId
        let digestText = self.model.digestText

        Task {
            do {
                let detail = try await service.fetchQueryDetail(
                    instance: instance, digestId: digestId, digestText: digestText, range: range
                )
                await MainActor.run {
                    self.model.detail = detail
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

    private func loadFullSQL(statementId: String) {
        // Already resolved or in flight — nothing to do.
        guard model.fullSQL[statementId] == nil, !model.loadingSQL.contains(statementId) else { return }
        model.loadingSQL.insert(statementId)

        let instance = self.instance
        let service = self.service

        Task {
            do {
                let sql = try await service.fetchFullSQL(instance: instance, statementId: statementId)
                await MainActor.run {
                    self.model.fullSQL[statementId] = sql
                    self.model.loadingSQL.remove(statementId)
                }
            } catch {
                await MainActor.run {
                    // Fall back to the preview text already shown; surface the reason inline.
                    self.model.fullSQL[statementId] = "⚠️ \((error as NSError).localizedDescription)"
                    self.model.loadingSQL.remove(statementId)
                }
            }
        }
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if model.detail == nil {
            reload(range: model.range)
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
