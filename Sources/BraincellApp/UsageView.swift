import SwiftUI
import GRDB
import Charts
import UniformTypeIdentifiers
import BraincellCore

/// Usage & Analytics. Everything here comes from the gateway's request log (metadata only: no prompts, replies or keys).
struct UsageView: View {
    @ObservedObject var cfg: AIConfig
    enum Span: String, CaseIterable, Identifiable { case today = "Today", d7 = "Last 7 Days", d30 = "Last 30 Days", d90 = "Last 90 Days", all = "All Time", custom = "Custom Range"; var id: String { rawValue } }
    @State private var span: Span = .d30
    @State private var from = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    @State private var to = Date()
    @State private var rows: [AIRequestRecord] = []
    @State private var capFilter: Capability?
    @State private var statusFilter = "all"
    @State private var sortOrder = [KeyPathComparator(\AIRequestRecord.ts, order: .reverse)]
    @State private var budget = BudgetSettings()
    @State private var budgetText = (d: "", m: "", r: "", n: "")
    @State private var todaySpend = 0.0
    @State private var courseNames: [UUID: String] = [:]

    private var range: UsageRange {
        switch span {
        case .today: .lastDays(1); case .d7: .lastDays(7); case .d30: .lastDays(30); case .d90: .lastDays(90); case .all: .all
        case .custom: UsageRange(from: Calendar.current.startOfDay(for: from), to: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)))
        }
    }
    private var filtered: [AIRequestRecord] { rows.filter { (capFilter == nil || $0.capability == capFilter) && (statusFilter == "all" || $0.status == statusFilter) } }
    private var u: UsageService { cfg.gw.usage }

    var body: some View {
        AIPage(title: "Usage & Analytics", subtitle: "Requests made through Learn Anyway. Costs are estimates, not provider invoices.") {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    controls
                    tiles
                    if rows.isEmpty { Notice(text: "No AI requests yet in this period. Usage appears here once a task is sent through a connected provider. Manual ChatGPT Bridge work is never counted.") }
                    charts
                    modelTable
                    historyTable
                    budgetCard
                }.padding(Theme.Space.xl).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
        .task(id: "\(cfg.rev)-\(span.rawValue)-\(from)-\(to)") { load() }
    }

    private func load() {
        rows = (try? u.requests(range)) ?? []
        courseNames = (try? cfg.gw.store.db.read { db in Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, name FROM courses").map { ($0["id"] as UUID, $0["name"] as String) }) }) ?? [:]
        budget = BudgetSettings.load(cfg.gw.settings)
        budgetText = (budget.daily.map { String($0) } ?? "", budget.monthly.map { String($0) } ?? "", budget.perRequest.map { String($0) } ?? "", budget.maxRequestsPerDay.map { String($0) } ?? "")
        todaySpend = (try? u.spend(since: Calendar.current.startOfDay(for: Date()))) ?? 0
    }

    private func money(_ micros: Int64, complete: Bool = true) -> String { String(format: "$%.4f", Double(micros) / 1_000_000) + (complete ? "" : "+") }

    // MARK: Controls and tiles

    private var controls: some View {
        HStack {
            Picker("Period", selection: $span) { ForEach(Span.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 170)
            if span == .custom { DatePicker("From", selection: $from, displayedComponents: .date).labelsHidden(); Text("to"); DatePicker("To", selection: $to, displayedComponents: .date).labelsHidden() }
            Spacer()
            Button("Export Summary CSV…") { export(u.summaryCSV(filtered), "usage-summary.csv") }
            Button("Export History CSV…") { export(u.historyCSV(filtered), "usage-history.csv") }
        }
    }

    private var tiles: some View {
        let t = u.totals(rows)
        let avg = t.avgLatencyMs
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Theme.Space.md)], spacing: Theme.Space.md) {
            tile("Total Requests", "\(t.requests)")
            tile("Total Tokens", t.totalTokens.formatted())
            tile("Input Tokens", t.inputTokens.formatted()); tile("Output Tokens", t.outputTokens.formatted())
            tile("Estimated Cost", t.unknownCostRequests == t.succeeded && t.succeeded > 0 ? "Cost Unknown" : money(t.knownCostMicros, complete: t.costIsComplete),
                 note: t.costIsComplete ? "Estimate only" : "\(t.unknownCostRequests) request(s) have no price")
            tile("Successful", "\(t.succeeded)"); tile("Failed", "\(t.failed)")
            tile("Avg Latency", avg >= 1000 ? String(format: "%.1f s", Double(avg) / 1000) : "\(avg) ms")
        }
    }

    private func tile(_ title: String, _ value: String, note: String? = nil) -> some View {
        Card(padding: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.meta).foregroundStyle(Theme.textSecondary)
                Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                if let note { Text(note).font(.system(size: 10)).foregroundStyle(Theme.textSecondary) }
            }
        }.accessibilityElement(children: .combine)
    }

    // MARK: Charts

    @ViewBuilder private var charts: some View {
        if !rows.isEmpty {
            let days = u.byDay(rows)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: Theme.Space.md)], spacing: Theme.Space.md) {
                chartCard("Daily Token Usage") { Chart(days) { BarMark(x: .value("Day", $0.day, unit: .day), y: .value("Tokens", $0.tokens)).foregroundStyle(Theme.accent) } }
                chartCard("Daily Estimated Spend (known costs)") { Chart(days) { BarMark(x: .value("Day", $0.day, unit: .day), y: .value("USD", Double($0.costMicros) / 1_000_000)).foregroundStyle(Theme.mastery) } }
                chartCard("Requests Over Time") { Chart(days) { LineMark(x: .value("Day", $0.day, unit: .day), y: .value("Requests", $0.requests)); PointMark(x: .value("Day", $0.day, unit: .day), y: .value("Requests", $0.requests)) }.foregroundStyle(Theme.accent) }
                groupChart("Usage by Capability", u.grouped(rows, by: .capability))
                groupChart("Usage by Provider", u.grouped(rows, by: .provider))
                groupChart("Usage by Model", u.grouped(rows, by: .model))
            }
        }
    }

    private func chartCard<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        Card { VStack(alignment: .leading, spacing: Theme.Space.sm) { Text(title).font(Theme.cardTitle); c().frame(height: 170) } }
    }
    private func groupChart(_ title: String, _ g: [UsageGroup]) -> some View {
        chartCard(title) {
            Chart(g.prefix(8)) { x in BarMark(x: .value("Requests", x.requests), y: .value("Name", x.model.isEmpty ? (title.contains("Capability") ? x.capability : x.provider) : x.model)).foregroundStyle(Theme.accent) }
        }
    }

    // MARK: Tables

    private var modelTable: some View {
        let g = u.grouped(rows, by: .model)
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Usage by Model").font(Theme.cardTitle)
                if g.isEmpty { Text("Nothing to show yet.").foregroundStyle(Theme.textSecondary) }
                else {
                    Table(g) {
                        TableColumn("Provider") { Text($0.provider) }
                        TableColumn("Model") { Text($0.model).font(.system(.callout, design: .monospaced)) }
                        TableColumn("Capability") { Text($0.capability) }
                        TableColumn("Requests") { Text("\($0.requests)").monospacedDigit() }.width(70)
                        TableColumn("Tokens") { Text($0.tokens.formatted()).monospacedDigit() }.width(90)
                        TableColumn("Est. Cost") { Text($0.unknownCost > 0 && $0.knownCostMicros == 0 ? "Cost Unknown" : money($0.knownCostMicros, complete: $0.unknownCost == 0)).monospacedDigit() }.width(110)
                        TableColumn("Errors") { Text("\($0.errors)").monospacedDigit() }.width(60)
                    }.frame(height: CGFloat(min(g.count, 8)) * 28 + 36)
                }
            }
        }
    }

    private var historyTable: some View {
        let list = filtered.sorted(using: sortOrder)
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Text("Request History").font(Theme.cardTitle); Spacer()
                    Picker("Capability", selection: $capFilter) { Text("All capabilities").tag(Capability?.none); ForEach(Capability.allCases) { Text($0.label).tag(Capability?.some($0)) } }.labelsHidden().frame(width: 170)
                    Picker("Status", selection: $statusFilter) { Text("All").tag("all"); Text("Success").tag("success"); Text("Failed").tag("failed") }.labelsHidden().frame(width: 110)
                }
                Table(list.prefix(500).map { $0 }, sortOrder: $sortOrder) {
                    TableColumn("Time", value: \.ts) { Text($0.ts.formatted(date: .abbreviated, time: .shortened)) }.width(130)
                    TableColumn("Task", value: \.task) { Text(WorkflowTask.find($0.task)?.title ?? $0.task) }
                    TableColumn("Course") { r in Text(r.courseId.flatMap { courseNames[$0] } ?? "—").foregroundStyle(Theme.textSecondary) }
                    TableColumn("Provider", value: \.providerId) { Text($0.providerId) }.width(90)
                    TableColumn("Model", value: \.modelId) { Text($0.modelId).font(.system(.caption, design: .monospaced)) }
                    TableColumn("Status", value: \.status) { r in Text(r.status == "success" ? "Success" : (r.errorCategory ?? "Failed")).foregroundStyle(r.status == "success" ? Theme.mastery : Theme.error) }.width(90)
                    TableColumn("Latency", value: \.latencyMs) { Text("\($0.latencyMs) ms").monospacedDigit() }.width(80)
                    TableColumn("In") { Text($0.inputTokens.map(String.init) ?? "—").monospacedDigit() }.width(60)
                    TableColumn("Out") { Text($0.outputTokens.map(String.init) ?? "—").monospacedDigit() }.width(60)
                    TableColumn("Cost") { r in Text(r.costMicros.map { money($0) + (r.costBasis == "local" ? " local" : "") } ?? "Unknown").monospacedDigit() }.width(90)
                }.frame(height: CGFloat(min(max(list.count, 1), 12)) * 28 + 40)
                if list.count > 500 { Text("Showing the newest 500 of \(list.count). Export CSV for everything.").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
            }
        }
    }

    // MARK: Budget

    private var budgetCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                Text("Budget Controls").font(Theme.cardTitle)
                if let d = budget.daily { VStack(alignment: .leading, spacing: 3) { MeterBar(value: todaySpend / d, tint: todaySpend / d * 100 >= Double(budget.warnPercent) ? Theme.attention : Theme.mastery); Text(String(format: "Today: $%.2f of $%.2f (known costs)", todaySpend, d)).font(Theme.meta).foregroundStyle(Theme.textSecondary) } }
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.md, verticalSpacing: Theme.Space.sm) {
                    GridRow { Text("Daily budget (USD)"); TextField("None", text: $budgetText.d).frame(width: 120) }
                    GridRow { Text("Monthly budget (USD)"); TextField("None", text: $budgetText.m).frame(width: 120) }
                    GridRow { Text("Warn per request above (USD)"); TextField("None", text: $budgetText.r).frame(width: 120) }
                    GridRow { Text("Max requests per day"); TextField("None", text: $budgetText.n).frame(width: 120) }
                    GridRow { Text("Warn at"); Stepper("\(budget.warnPercent)% of budget", value: $budget.warnPercent, in: 10...100, step: 5) }
                }
                Toggle("Block requests once a daily or monthly budget is used up", isOn: $budget.enforce)
                Text("Limits are enforced by Learn Anyway’s own request router, using only costs it can estimate. They can’t stop charges made outside the app, and requests with unknown prices aren’t counted toward a dollar budget (the request cap still applies).").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                Button("Save budget") {
                    budget.daily = Double(budgetText.d).flatMap { $0 > 0 ? $0 : nil }; budget.monthly = Double(budgetText.m).flatMap { $0 > 0 ? $0 : nil }
                    budget.perRequest = Double(budgetText.r).flatMap { $0 > 0 ? $0 : nil }; budget.maxRequestsPerDay = Int(budgetText.n).flatMap { $0 > 0 ? $0 : nil }
                    try? budget.save(cfg.gw.settings); load()
                }.buttonStyle(.primary)
            }
        }
    }

    private func export(_ csv: String, _ name: String) {
        let p = NSSavePanel(); p.nameFieldStringValue = name; p.allowedContentTypes = [.commaSeparatedText]
        p.message = "Contains request metadata only: no prompts, replies or keys."
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch { cfg.error = error.localizedDescription }
    }
}

