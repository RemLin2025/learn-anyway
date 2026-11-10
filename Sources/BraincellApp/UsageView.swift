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
    @State private var rows: [AIRequestRecord] = []          // newest 300 matching the history filters, never the whole log
    @State private var totals = UsageTotals()
    @State private var byProvider: [UsageService.Slice] = []
    @State private var byModel: [UsageService.Slice] = []
    @State private var byTask: [UsageService.Slice] = []
    @State private var days: [DayUsage] = []
    @State private var providers: [String] = []
    @State private var models: [String] = []
    @State private var openRequests = false
    @State private var openTokens = false
    @State private var capFilter: Capability?
    @State private var statusFilter = "all"
    @State private var providerFilter = ""
    @State private var modelFilter = ""
    @State private var picked: UUID?
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
    private var u: UsageService { cfg.gw.usage }

    var body: some View {
        AIPage(title: "Usage & Analytics", subtitle: "Requests made through Learn Anyway. Costs are estimates, not provider invoices.") {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    controls
                    primaryCards
                    if totals.requests == 0 { Notice(text: "No AI requests yet in this period. Usage appears here once a task is sent through a connected provider. Manual ChatGPT Bridge work is never counted.") }
                    historyTable
                    DisclosureGroup("Budget controls") { budgetCard.padding(.top, Theme.Space.sm) }.font(Theme.cardTitle)
                }.padding(Theme.Space.xl).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
        .task(id: "\(cfg.rev)-\(span.rawValue)-\(from)-\(to)-\(capFilter?.rawValue ?? "")-\(statusFilter)-\(providerFilter)-\(modelFilter)") { load() }
    }

    private func load() {
        let st = statusFilter == "all" ? nil : statusFilter
        rows = (try? u.page(range, capability: capFilter, status: st, provider: providerFilter.isEmpty ? nil : providerFilter, model: modelFilter.isEmpty ? nil : modelFilter)) ?? []
        totals = (try? u.totals(range)) ?? UsageTotals()
        byProvider = (try? u.slices(range, by: .provider)) ?? []; byModel = (try? u.slices(range, by: .model)) ?? []; byTask = (try? u.slices(range, by: .task)) ?? []
        days = (try? u.dailyTotals(range)) ?? []
        providers = (try? u.distinctValues(.provider)) ?? []; models = (try? u.distinctValues(.model)) ?? []
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
            Menu("Export") {
                Button("Summary CSV (totals per model)…") { export(u.summaryCSV((try? u.requests(range)) ?? []), "usage-summary.csv") }
                Button("Detailed history CSV (one row per request)…") { export(u.historyCSV((try? u.requests(range, capability: capFilter, status: statusFilter == "all" ? nil : statusFilter)) ?? []), "usage-history.csv") }
            }.menuStyle(.borderlessButton).fixedSize().help("Summary: one row per model. Detailed: one row per request. Neither contains prompts, replies or keys.")
        }
    }

    private var primaryCards: some View {
        let t = totals
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                metric("Total Requests", "\(t.requests)", open: $openRequests)
                metric("Total Tokens", t.totalTokens.formatted(), open: $openTokens)
            }
            if openRequests {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        HStack(spacing: Theme.Space.xl) { stat("Successful", "\(t.succeeded)"); stat("Failed", "\(t.failed)"); stat("Avg latency", t.requests == 0 ? "—" : (t.avgLatencyMs >= 1000 ? String(format: "%.1f s", Double(t.avgLatencyMs) / 1000) : "\(t.avgLatencyMs) ms")) }
                        breakdown("By provider", byProvider.map { ($0.key, "\($0.requests)", Double($0.requests)) })
                        breakdown("By model", byModel.map { ($0.key, "\($0.requests)", Double($0.requests)) })
                        breakdown("By task", byTask.map { (WorkflowTask.find($0.key)?.title ?? $0.key, "\($0.requests)", Double($0.requests)) })
                        if days.count > 1 { Chart(days) { BarMark(x: .value("Day", $0.day, unit: .day), y: .value("Requests", $0.requests)).foregroundStyle(Theme.accent) }.frame(height: 110) }
                    }
                }
            }
            if openTokens {
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        HStack(spacing: Theme.Space.xl) {
                            stat("Input", t.inputTokens.formatted()); stat("Output", t.outputTokens.formatted())
                            stat("Cached", t.cachedTokens == 0 ? "None reported" : t.cachedTokens.formatted())
                            stat("Estimated cost", t.unknownCostRequests == t.succeeded && t.succeeded > 0 ? "Unknown" : money(t.knownCostMicros, complete: t.costIsComplete), note: t.costIsComplete ? "Estimate, not an invoice" : "\(t.unknownCostRequests) request(s) have no price")
                        }
                        if t.unreportedTokenRequests > 0 { Text("\(t.unreportedTokenRequests) successful request(s) came back without token counts from the provider. They’re counted as unknown, not zero.").font(Theme.meta).foregroundStyle(Theme.attention) }
                        breakdown("By model", byModel.map { ($0.key, $0.tokens.formatted(), Double($0.tokens)) })
                        if days.count > 1 { Chart(days) { BarMark(x: .value("Day", $0.day, unit: .day), y: .value("Tokens", $0.tokens)).foregroundStyle(Theme.accent) }.frame(height: 110) }
                    }
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            Card(padding: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.callout).foregroundStyle(Theme.textSecondary)
                    Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                    HStack(spacing: 4) { Text(open.wrappedValue ? "Hide details" : "Details"); Image(systemName: open.wrappedValue ? "chevron.up" : "chevron.right").font(.caption2) }.font(.callout).foregroundStyle(Theme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title): \(value)").accessibilityHint(open.wrappedValue ? "Hides the breakdown" : "Shows the breakdown")
    }

    private func stat(_ t: String, _ v: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(t).font(Theme.meta).foregroundStyle(Theme.textSecondary); Text(v).font(.system(.title3, design: .rounded, weight: .semibold)).monospacedDigit(); if let note { Text(note).font(.system(size: 10)).foregroundStyle(Theme.textSecondary) } }
    }

    private func breakdown(_ title: String, _ items: [(String, String, Double)]) -> some View {
        let mx = max(items.map(\.2).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(.subheadline, design: .rounded, weight: .semibold))
            if items.isEmpty { Text("Nothing yet.").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
            ForEach(items, id: \.0) { it in
                HStack(spacing: 8) {
                    Text(it.0).font(.callout).lineLimit(1).truncationMode(.middle).frame(width: 220, alignment: .leading)
                    GeometryReader { g in RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.7)).frame(width: max(2, g.size.width * it.2 / mx)) }.frame(height: 8)
                    Text(it.1).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
                }
            }
        }
    }

    private var historyTable: some View {
        let list = rows.sorted(using: sortOrder)
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                HStack {
                    Text("Request History").font(Theme.cardTitle); Spacer()
                    Picker("Provider", selection: $providerFilter) { Text("All providers").tag(""); ForEach(providers, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 130)
                    Picker("Model", selection: $modelFilter) { Text("All models").tag(""); ForEach(models, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 150)
                    Picker("Capability", selection: $capFilter) { Text("All capabilities").tag(Capability?.none); ForEach(Capability.allCases) { Text($0.label).tag(Capability?.some($0)) } }.labelsHidden().frame(width: 170)
                    Picker("Status", selection: $statusFilter) { Text("All").tag("all"); Text("Success").tag("success"); Text("Failed").tag("failed") }.labelsHidden().frame(width: 110)
                }
                Table(list, selection: $picked, sortOrder: $sortOrder) {
                    TableColumn("Time", value: \.ts) { Text($0.ts.formatted(.dateTime.month(.abbreviated).day().hour().minute())) }.width(130)
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
                if let id = picked, let r = rows.first(where: { $0.id == id }) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Request details").font(.system(.subheadline, design: .rounded, weight: .semibold))
                        Text("\(WorkflowTask.find(r.task)?.title ?? r.task) · \(r.providerId)/\(r.modelId) · \(r.ts.formatted(date: .abbreviated, time: .standard))").font(.callout)
                        Text("Status: \(r.status)\(r.errorCategory.map { " (\($0))" } ?? "") · latency \(r.latencyMs) ms · tokens in \(r.inputTokens.map(String.init) ?? "not reported") / out \(r.outputTokens.map(String.init) ?? "not reported")\(r.cachedTokens.map { " / cached \($0)" } ?? "")").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                        Text("Cost: \(r.costMicros.map { money($0) } ?? "unknown") (\(r.costBasis == "estimated" ? "estimate from model prices" : r.costBasis)). The prompt and reply aren’t stored.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
                    }.padding(Theme.Space.md).frame(maxWidth: .infinity, alignment: .leading).background(Theme.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                }
                if list.count >= 300 { Text("Showing the newest 300 matches. Export the detailed CSV for everything.").font(Theme.meta).foregroundStyle(Theme.textSecondary) }
                Text("Request metadata only: no prompts, replies or keys are stored. Token counts come from the provider’s response; “—” means it reported none.").font(Theme.meta).foregroundStyle(Theme.textSecondary)
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

