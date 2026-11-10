import Testing
import Foundation
import CoreGraphics
@testable import BraincellCore

@Suite struct SettingsRedesignTests {
    // MARK: Price input

    @Test func priceValidation() {
        #expect(PriceInput.parse("") == .success(nil))
        #expect(PriceInput.parse(" $3.50 ") == .success(3.5))
        #expect(PriceInput.parse("3,5") == .success(3.5))
        #expect(PriceInput.parse("abc") == .failure(.notANumber))
        #expect(PriceInput.parse("-1") == .failure(.negative))
        #expect(PriceInput.parse("nan") == .failure(.notANumber))
        #expect(PriceInput.parse("inf") == .failure(.notANumber))
        #expect(PriceInput.parse("1000000") == .failure(.tooLarge))
        #expect(PriceInput.format(nil) == "Unknown" && PriceInput.format(0) == "Free" && PriceInput.format(3) == "$3.00")
    }

    // MARK: Catalog filtering at scale

    func rows(_ n: Int) -> [ModelRow] {
        (0..<n).map { i in
            ModelRow(id: UUID(), name: "Model \(i)", modelId: "vendor/model-\(i)", provider: "OpenRouter", capability: .llm, health: i % 10 == 0 ? .ready : .untested,
                     input: i % 7 == 0 ? nil : Double(i % 50), output: i % 7 == 0 ? nil : Double(i % 50) * 2, custom: false, assignments: i % 25 == 0 ? 1 : 0, isDefault: i == 3, favorite: i % 40 == 0)
        }
    }

    @Test func filtersScopesAndSearch() {
        let all = rows(450)
        var q = ModelQuery()
        #expect(ModelCatalog.filter(all, q).count == 450)
        q.text = "model-12"; #expect(ModelCatalog.filter(all, q).allSatisfy { $0.modelId.contains("model-12") })
        q.text = ""; q.scope = .assigned; #expect(ModelCatalog.filter(all, q).count == all.filter { $0.assignments > 0 || $0.isDefault }.count)
        q.scope = .unpriced; #expect(ModelCatalog.filter(all, q).allSatisfy { !$0.priced })
        q.scope = .verified; #expect(ModelCatalog.filter(all, q).count == 45)
        q.scope = .favorites; #expect(ModelCatalog.filter(all, q).count == all.filter(\.favorite).count)
    }

    @Test func unknownPricesSortLastBothDirections() {
        var q = ModelQuery(); q.sort = .input
        for asc in [true, false] {
            q.ascending = asc
            let out = ModelCatalog.filter(rows(100), q)
            let firstUnknown = out.firstIndex { $0.input == nil }!
            #expect(out[firstUnknown...].allSatisfy { $0.input == nil })
        }
    }

    @Test func filteringFourHundredModelsIsFast() {
        let all = rows(2000); var q = ModelQuery(); q.text = "model 1"; q.sort = .output
        let t0 = Date(); for _ in 0..<20 { _ = ModelCatalog.filter(all, q) }
        #expect(Date().timeIntervalSince(t0) / 20 < 0.05)       // 2000 rows, well under a frame budget per pass
    }

    // MARK: Fit to view

    @Test func fitIncludesEverythingAtAnySize() {
        let b = CGRect(x: -56, y: -48, width: 1400, height: 900)
        for vp in [CGSize(width: 420, height: 380), CGSize(width: 900, height: 600), CGSize(width: 2560, height: 1400)] {
            let t = CanvasFit.transform(bounds: b, viewport: vp, minScale: 0.1)
            let r = CGRect(x: b.minX * t.scale + t.pan.width, y: b.minY * t.scale + t.pan.height, width: b.width * t.scale, height: b.height * t.scale)
            #expect(CGRect(origin: .zero, size: vp).insetBy(dx: -0.5, dy: -0.5).contains(r), "viewport \(vp)")
            #expect(abs(r.midX - vp.width / 2) < 0.5 && abs(r.midY - vp.height / 2) < 0.5)
        }
    }

    @Test func fitEdgeCases() {
        #expect(CanvasFit.transform(bounds: .zero, viewport: CGSize(width: 800, height: 600)).scale == 1)
        #expect(CanvasFit.transform(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), viewport: .zero).scale == 1)
        let one = CanvasFit.transform(bounds: CGRect(x: 10, y: 10, width: 200, height: 100), viewport: CGSize(width: 1000, height: 800))
        #expect(one.scale == 1)                                                           // never zooms past 1×
        let tall = CanvasFit.transform(bounds: CGRect(x: 0, y: 0, width: 100, height: 20000), viewport: CGSize(width: 800, height: 600), minScale: 0.2)
        #expect(tall.scale == 0.2)                                                        // clamped, still centred
    }

    @Test func layoutBoundsContainEveryNodeAndEdgePoint() {
        let l = WorkflowCanvasLayout.make(expanded: Set(TaskGroup.allCases))
        for n in l.nodes { #expect(l.bounds.contains(n.rect)) }
        for e in l.edges { for p in e.points { #expect(l.bounds.contains(p)) } }
    }

    // MARK: Pipelines reflect real tasks

    @Test func pipelinesAreWellFormed() {
        for p in WorkflowPipeline.all {
            let ids = Set(p.steps.map(\.id))
            #expect(ids.count == p.steps.count, "\(p.id): duplicate step ids")
            for s in p.steps { #expect(s.after.allSatisfy(ids.contains), "\(p.id)/\(s.id)") }
            for t in p.modelTaskIds { #expect(WorkflowTask.find(t) != nil) }
            #expect(p.layers.flatMap { $0 }.count == p.steps.count)
            // layers respect dependencies
            var seen = Set<String>()
            for layer in p.layers { for s in layer { #expect(s.after.allSatisfy(seen.contains)) }; layer.forEach { seen.insert($0.id) } }
        }
        #expect(WorkflowPipeline.unwiredTaskIds.contains("courseOutline"))
        #expect(!WorkflowPipeline.unwiredTaskIds.contains("quizGeneration"))
    }

    // MARK: Prices and the database

    @Test func customPriceSurvivesCatalogRefreshAndDrivesEstimates() throws {
        let db = try AppDatabase.inMemory(); let st = GatewayStore(db: db)
        let c = AIConnection(id: UUID(), providerId: "openrouter", name: "OpenRouter", baseURL: nil, enabled: true, status: .ready, lastCheckedAt: nil, createdAt: Date())
        try st.save(c)
        var m = AIModelRecord(connectionId: c.id, modelId: "x/y", displayName: "Y", capability: .llm, source: "discovered", inputPricePerM: 1, outputPricePerM: 2)
        try st.save(m)
        m.customInputPricePerM = 10; m.customOutputPricePerM = 20; try st.save(m)
        // The provider changes its price: provider columns refresh, the user's estimate stays.
        try st.merge(discovered: [AIModelRecord(connectionId: c.id, modelId: "x/y", displayName: "Y", capability: .llm, source: "discovered", inputPricePerM: 3, outputPricePerM: 6)])
        let r = try #require(try st.models(connection: c.id).first)
        #expect(r.inputPricePerM == 3 && r.outputPricePerM == 6 && r.customInputPricePerM == 10 && r.customOutputPricePerM == 20)
        #expect(r.effectiveInputPricePerM == 10 && r.hasCustomPrice && r.pricedAt != nil)
        let (micros, basis) = CostEstimator.estimate(model: r, spec: ProviderRegistry.spec("openrouter"), input: 1_000_000, output: 1_000_000)
        #expect(micros == 30_000_000 && basis == "estimated")
        // clearing the override falls back to the provider price
        var x = r; x.customInputPricePerM = nil; x.customOutputPricePerM = nil; try st.save(x)
        #expect(try st.models(connection: c.id).first?.effectiveInputPricePerM == 3)
    }

    @Test func settingsExportCarriesCustomPricesButNoSecrets() throws {
        let db = try AppDatabase.inMemory(); let st = GatewayStore(db: db)
        let c = AIConnection(id: UUID(), providerId: "openrouter", name: "OpenRouter", baseURL: nil, enabled: true, status: .ready, lastCheckedAt: nil, createdAt: Date())
        try st.save(c)
        var m = AIModelRecord(connectionId: c.id, modelId: "x/y", displayName: "Y", capability: .llm, source: "discovered", inputPricePerM: 1, outputPricePerM: 2)
        m.customInputPricePerM = 9; try st.save(m)
        let data = try JSONEncoder().encode(try GatewayConfigExport.make(st))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("customInputPricePerM") && !text.lowercased().contains("apikey") && !text.contains("sk-"))
        // import into an empty store restores the estimate
        let db2 = try AppDatabase.inMemory(); let st2 = GatewayStore(db: db2)
        try JSONDecoder().decode(GatewayConfigExport.self, from: data).apply(to: st2, secrets: InMemorySecretStore())
        #expect(try st2.models().first?.customInputPricePerM == 9)
    }

    // MARK: Usage aggregates in SQL

    @Test func sqlTotalsMatchInMemoryTotals() throws {
        let db = try AppDatabase.inMemory(); let st = GatewayStore(db: db); let u = UsageService(store: st)
        func rec(_ ok: Bool, _ i: Int?, _ o: Int?, _ cost: Int64?, _ task: String = "quizGeneration", _ days: Int = 0) -> AIRequestRecord {
            AIRequestRecord(ts: Date().addingTimeInterval(Double(-days) * 86400), connectionId: nil, providerId: "openai", modelId: "m", capability: .llm, task: task, courseId: nil, status: ok ? "success" : "failed", latencyMs: 100, inputTokens: i, outputTokens: o, cachedTokens: nil, costMicros: cost, costBasis: cost == nil ? "unknown" : "estimated", errorCategory: ok ? nil : "timeout")
        }
        try db.write { d in for r in [rec(true, 10, 5, 100), rec(true, nil, nil, nil), rec(false, nil, nil, nil), rec(true, 20, 10, 50, "answerEvaluation", 3)] { try r.insert(d) } }
        let a = try u.totals(.all), b = u.totals(try u.requests())
        #expect(a.requests == b.requests && a.succeeded == b.succeeded && a.failed == b.failed && a.inputTokens == b.inputTokens && a.outputTokens == b.outputTokens)
        #expect(a.knownCostMicros == b.knownCostMicros && a.unknownCostRequests == b.unknownCostRequests)
        #expect(a.unreportedTokenRequests == 1 && a.requests == 4 && a.failed == 1)
        #expect(try u.totals(.all, status: "failed").requests == 1)
        #expect(try u.totals(.lastDays(1)).requests == 3)
        #expect(try u.slices(.all, by: .task).first { $0.key == "quizGeneration" }?.requests == 3)
        #expect(try u.page(.all, limit: 2).count == 2)
        #expect(try u.dailyTotals(.all).map(\.requests).reduce(0, +) == 4)
    }

    @Test func resolutionsPointAtTheStoredModelRecord() throws {
        let db = try AppDatabase.inMemory(); let st = GatewayStore(db: db)
        let c = AIConnection(id: UUID(), providerId: "openrouter", name: "OpenRouter", baseURL: nil, enabled: true, status: .ready, lastCheckedAt: nil, createdAt: Date())
        try st.save(c)
        let m = AIModelRecord(connectionId: c.id, modelId: "x/y", displayName: "Y", capability: .llm, source: "discovered")
        try st.save(m); try st.setDefault(.llm, connection: c.id, model: "x/y")
        let res = try ModelRouter(store: st).resolveAll()
        let served = WorkflowTask.all.filter { res[$0.id]?.primary?.model.id == m.id }
        #expect(!served.isEmpty && served.allSatisfy { res[$0.id]?.inherited == true })
    }
}
