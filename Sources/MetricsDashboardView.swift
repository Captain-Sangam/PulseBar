import SwiftUI
import Charts

/// The detail dashboard: a range picker, six charts grouped CPU / Memory / Storage,
/// and Top Queries / Users / Hosts panels from Performance Insights.
struct MetricsDashboardView: View {
    @ObservedObject var model: DetailViewModel

    var body: some View {
        ScrollView {
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
                    activitySection
                } else if model.errorMessage != nil {
                    placeholder(systemImage: "exclamationmark.triangle", text: model.errorMessage ?? "Error")
                } else {
                    placeholder(systemImage: "hourglass", text: "Loading metrics…")
                }
            }
            .padding(20)
        }
        .frame(minWidth: 760, minHeight: 520)
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
                        TopPanel(title: "Top Queries", items: pi.topQueries)
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

    // MARK: - Events & alarms

    @ViewBuilder
    private var activitySection: some View {
        if let activity = model.activity {
            VStack(alignment: .leading, spacing: 8) {
                Text("Events & Alarms").font(.headline)

                // Active CloudWatch alarms (in ALARM state).
                if !activity.alarms.isEmpty {
                    ForEach(activity.alarms) { alarm in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "bell.fill").foregroundColor(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alarm.name).font(.caption).bold()
                                if !alarm.reason.isEmpty {
                                    Text(alarm.reason).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                // Recent RDS events.
                if activity.events.isEmpty && activity.alarms.isEmpty {
                    Text("No recent events or active alarms.")
                        .font(.callout).foregroundColor(.secondary).padding(.vertical, 4)
                } else {
                    ForEach(activity.events.prefix(10)) { event in
                        HStack(alignment: .top, spacing: 6) {
                            Text(Self.eventDateFormatter.string(from: event.date))
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 96, alignment: .leading)
                            Text(event.message).font(.caption)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }

    private static let eventDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

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
