import SwiftUI
import Charts

/// The detail dashboard: a range picker, six charts grouped CPU / Memory / Storage,
/// and Top Queries / Users / Hosts panels from Performance Insights.
struct MetricsDashboardView: View {
    @ObservedObject var model: DetailViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let series = model.series {
                    chartGroup(title: "CPU", charts: [
                        AnyView(LineChart(series: series.cpuUtilization)),
                        AnyView(sessionsChart(series.dbLoad))
                    ])
                    chartGroup(title: "Memory", charts: [
                        AnyView(LineChart(series: series.freeableMemory)),
                        AnyView(LineChart(series: series.swapUsage))
                    ])
                    chartGroup(title: "Storage", charts: [
                        AnyView(LineChart(series: series.freeStorageSpace)),
                        AnyView(iopsChart(read: series.readIOPS, write: series.writeIOPS))
                    ])

                    performanceInsightsSection
                } else if model.errorMessage != nil {
                    placeholder(systemImage: "exclamationmark.triangle", text: model.errorMessage ?? "Error")
                } else {
                    placeholder(systemImage: "hourglass", text: "Loading metrics…")
                }
            }
            .padding(20)
            // Report the natural content height so the window can size itself to fit (no scroll bar).
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
        }
        .frame(minWidth: 760, minHeight: 520)
        .onPreferenceChange(ContentHeightKey.self) { height in
            model.onContentHeight?(height)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.instanceName).font(.title2).bold()
                Text(model.engine).font(.subheadline).foregroundColor(.secondary)
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small).padding(.trailing, 8)
            }
            Picker("", selection: Binding(
                get: { model.range },
                set: { model.onRangeChange?($0) }
            )) {
                ForEach(MetricRange.allCases) { r in
                    Text(r.title).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .labelsHidden()
        }
    }

    // MARK: - Chart group

    private func chartGroup(title: String, charts: [AnyView]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack(spacing: 16) {
                ForEach(Array(charts.enumerated()), id: \.offset) { _, chart in
                    chart.frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// DBLoad chart, with an explanatory placeholder when Performance Insights is off.
    private func sessionsChart(_ series: MetricSeries) -> some View {
        Group {
            if series.isEmpty {
                ChartCard(title: series.displayName) {
                    VStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundColor(.secondary)
                        Text("No data\nEnable Performance Insights")
                            .multilineTextAlignment(.center)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                LineChart(series: series)
            }
        }
    }

    /// Read + Write IOPS overlaid on a single chart with a legend.
    private func iopsChart(read: MetricSeries, write: MetricSeries) -> some View {
        ChartCard(title: "IOPS (read / write)") {
            if read.isEmpty && write.isEmpty {
                noData
            } else {
                Chart {
                    ForEach(read.points) { p in
                        LineMark(x: .value("Time", p.timestamp), y: .value("Read", p.value))
                            .foregroundStyle(by: .value("Series", "Read"))
                    }
                    ForEach(write.points) { p in
                        LineMark(x: .value("Time", p.timestamp), y: .value("Write", p.value))
                            .foregroundStyle(by: .value("Series", "Write"))
                    }
                }
                .chartLegend(position: .top)
                .chartYAxisLabel(read.unit.axisLabel, position: .trailing)
            }
        }
    }

    // MARK: - Performance Insights panels

    @ViewBuilder
    private var performanceInsightsSection: some View {
        if let pi = model.pi {
            VStack(alignment: .leading, spacing: 8) {
                Text("Performance Insights").font(.headline)
                if pi.enabled {
                    HStack(alignment: .top, spacing: 16) {
                        TopQueriesPanel(items: pi.topQueries) { item in
                            model.onOpenQuery?(item)
                        }
                        TopPanel(title: "Top Users", items: pi.topUsers)
                        TopPanel(title: "Top Hosts", items: pi.topHosts)
                    }
                } else {
                    Text("Enable Performance Insights on this instance to see top queries, users, and hosts.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Shared bits

    private var noData: some View {
        Text("No data").font(.caption).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(systemImage: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle).foregroundColor(.secondary)
            Text(text).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

/// A single-series line chart in a titled card, with Y-axis values converted to the series' display unit.
private struct LineChart: View {
    let series: MetricSeries

    var body: some View {
        ChartCard(title: series.displayName) {
            if series.isEmpty {
                Text("No data").font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(series.points) { p in
                    LineMark(
                        x: .value("Time", p.timestamp),
                        y: .value(series.displayName, series.unit.axisValue(p.value))
                    )
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                }
                .chartYAxisLabel(series.unit.axisLabel, position: .trailing)
            }
        }
    }
}

/// Consistent framing for every chart cell.
private struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            content
                .frame(height: 130)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }
}

/// Carries the dashboard's natural content height up to the window controller so it can
/// size the window to fit (avoiding a scroll bar).
struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The Top Queries panel. Unlike Top Users / Hosts, each row shows the *start* of the query
/// (leading text, not middle-truncated) alongside its load, and is clickable to open the
/// query's drill-down window — matching the RDS console's Top SQL flow.
private struct TopQueriesPanel: View {
    let items: [TopItem]
    let onSelect: (TopItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Top Queries").font(.subheadline).bold()
                .padding(.bottom, 8)
            if items.isEmpty {
                Text("No data").font(.caption).foregroundColor(.secondary)
            } else {
                let rows = Array(items.prefix(10).enumerated())
                ForEach(rows, id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().opacity(0.4)
                    }
                    Button { onSelect(item) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            // Show the query start; truncate the tail so the leading text is readable.
                            // PI sometimes returns a digest with no statement text (engine-internal
                            // queries) — show a placeholder rather than a blank line + floating number.
                            Text(displayLabel(item.label))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .primary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            Text(String(format: "%.2f", item.load))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.label)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    private func displayLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no statement text)" : trimmed
    }
}

/// A ranked list of TopItems (queries / users / hosts) by average active sessions.
private struct TopPanel: View {
    let title: String
    let items: [TopItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).bold()
            if items.isEmpty {
                Text("No data").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(items.prefix(10)) { item in
                    HStack {
                        Text(item.label)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.2f", item.load))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }
}
