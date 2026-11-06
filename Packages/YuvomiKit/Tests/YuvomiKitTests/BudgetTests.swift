import Foundation
import Testing
@testable import YuvomiKit

@Suite struct BudgetParsingTests {
    @Test(arguments: [
        ("12,50", 12.5), ("12.5", 12.5), ("1 234,00 €", 1234.0), ("1.234,56", 1234.56),
        ("1,234.56", 1234.56), ("8", 8.0), ("3,999", 3999.0),
    ])
    func amountsParse(text: String, expected: Double) {
        #expect(BudgetDraft.parseAmount(text) == expected)
    }

    @Test func rejectsNonAmounts() {
        #expect(BudgetDraft.parseAmount("") == nil)
        #expect(BudgetDraft.parseAmount("abc") == nil)
        #expect(BudgetDraft.parseAmount("0") == nil)
    }
}

extension StubbedNetwork { @Suite struct BudgetTests {
    let client = YuvomiClient(
        credential: DeviceCredential(server: ServerURL("https://home.example.com")!, token: "yuv_t", deviceRowID: 1),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func entriesDecodeBookedExpectedAndTransfers() async throws {
        StubProtocol.routes = ["GET /api/v1/budget": (200, """
            {"data":[
              {"id":5,"title":"Courses","amount":-42.3,"category":"food","date":"2026-11-03","is_recurring":0,"is_pending":0,"transfer_entry_id":null,"creator_name":"Alex"},
              {"id":null,"title":"Netflix","amount":-13.49,"category":"subscriptions","date":"2026-11-20","expected":true},
              {"id":7,"title":"Épargne","amount":-100,"category":"financial_other","date":"2026-11-01","transfer_entry_id":8}
            ]}
            """)]
        let entries = try await client.budgetEntries(month: "2026-11")
        #expect(entries.map(\.isEditable) == [true, false, false])
        #expect(entries[1].isPending)
        #expect(entries[0].creatorName == "Alex")
        #expect(StubProtocol.seen.first?.url?.query() == "month=2026-11")
    }

    @Test func summaryRanksSpending() async throws {
        StubProtocol.routes = ["GET /api/v1/budget/summary": (200, """
            {"data":{"month":"2026-11","income":2500,"expenses":-640.5,"balance":1859.5,
              "byCategory":[{"category":"housing","income":0,"expenses":-500,"total":-500},
                            {"category":"Erwerbseinkommen","income":2500,"expenses":0,"total":2500},
                            {"category":"food","income":0,"expenses":-140.5,"total":-140.5}],
              "transfers":0,"pending":{"count":1,"income":0,"expenses":-13.49}}}
            """)]
        let summary = try await client.budgetSummary(month: "2026-11")
        #expect(summary.spending.map(\.category) == ["housing", "food"])
        #expect(summary.pending?.count == 1)
    }

    @Test func createSendsSignedAmount() async throws {
        StubProtocol.routes = ["POST /api/v1/budget": (201, """
            {"data":{"id":9,"title":"Boulangerie","amount":-4.2,"category":"food","date":"2026-11-05"}}
            """)]
        _ = try await client.createBudgetEntry(BudgetDraft(title: "Boulangerie", amount: -4.2, category: "food", date: "2026-11-05"))
        let body = try #require(StubProtocol.seen.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["amount"] as? Double == -4.2)
        #expect(json["category"] as? String == "food")
    }
} }
