import SwiftUI
import Charts

/// The query drill-down dashboard: the digest text, db.load over time scoped to this query,
/// the individual SQL statements behind it (each expandable to its full SQL), and the
/// users / hosts that ran it. Mirrors the RDS console's Top SQL detail view.
struct QueryDetailView: View {
    @ObservedObject var model: QueryDetailViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                digestCard

                if let detail = model.detail {
                    loadChart(detail.loadOverTime)
                    statementsSection(detail.statements)
                    HStack(alignment: .top, spacing: 16) {
                        dimensionPanel(title: "Top Users", items: detail.topUsers)
                        dimensionPanel(title: "Top Hosts", items: detail.topHosts)
                    }
                } else if let error = model.errorMessage {
                    placeholder(systemImage: "exclamationmark.triangle", text: error)
                } else {
                    placeholder(systemImage: "hourglass", text: "Loading query detail…")
                }
            }
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Query Detail").font(.title2).bold()
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

    /// The tokenized digest text, shown in full (this is the "query start" the row collapses).
    private var digestCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Digest").font(.caption).foregroundColor(.secondary)
            Text(model.digestText)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    // MARK: - Load chart

    private func loadChart(_ series: MetricSeries) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Load against this query (avg active sessions)")
                .font(.caption).foregroundColor(.secondary)
            Group {
                if series.isEmpty {
                    Text("No load data for this query in the selected range.")
                        .font(.caption).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Chart(series.points) { p in
                        AreaMark(x: .value("Time", p.timestamp), y: .value("Load", p.value))
                            .foregroundStyle(Color.accentColor.opacity(0.15))
                        LineMark(x: .value("Time", p.timestamp), y: .value("Load", p.value))
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.monotone)
                    }
                    .chartYAxisLabel("AAS", position: .trailing)
                }
            }
            .frame(height: 160)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    // MARK: - Statements

    private func statementsSection(_ statements: [SQLStatement]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Invocations (\(statements.count))").font(.headline)
            if statements.isEmpty {
                Text("No individual statements recorded for this digest.")
                    .font(.callout).foregroundColor(.secondary)
            } else {
                ForEach(statements) { statement in
                    StatementRow(statement: statement, model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    // MARK: - Dimensions

    private func dimensionPanel(title: String, items: [TopItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).bold()
            if items.isEmpty {
                Text("No data").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(items.prefix(10)) { item in
                    HStack {
                        Text(item.label).font(.caption).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Text(String(format: "%.2f", item.load))
                            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    // MARK: - Shared

    private func placeholder(systemImage: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle).foregroundColor(.secondary)
            Text(text).font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// One row in the Invocations list: a one-line preview + load, expandable to the full SQL.
/// Expanding lazily resolves the untruncated SQL text via GetDimensionKeyDetails.
private struct StatementRow: View {
    let statement: SQLStatement
    @ObservedObject var model: QueryDetailViewModel
    @State private var expanded = false

    private var statementId: String? { statement.statementId }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundColor(.secondary).frame(width: 10)
                    Text(statement.previewText)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text(String(format: "%.2f", statement.load))
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                fullSQLView
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var fullSQLView: some View {
        if let id = statementId {
            if model.loadingSQL.contains(id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading full SQL…").font(.caption2).foregroundColor(.secondary)
                }
            } else {
                Text(model.fullSQL[id] ?? statement.previewText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
            }
        } else {
            // No statement id — the preview text is all PI gave us.
            Text(statement.previewText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
        }
    }

    private func toggle() {
        expanded.toggle()
        if expanded, let id = statementId {
            model.onLoadFullSQL?(id)
        }
    }
}
