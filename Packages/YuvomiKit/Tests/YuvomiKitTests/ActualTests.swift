import Foundation
import Testing
@testable import YuvomiKit

@Test func actualMonthRangeKnowsMonthLengths() {
    #expect(ActualClient.range("2026-02") == ("2026-02-01", "2026-02-28"))
    #expect(ActualClient.range("2028-02") == ("2028-02-01", "2028-02-29"))
    #expect(ActualClient.range("2026-11") == ("2026-11-01", "2026-11-30"))
}

extension StubbedNetwork { @Suite struct ActualTests {
    let client = ActualClient(
        config: ActualConfig(server: ServerURL("https://actual-api.example.com")!, apiKey: "k3y",
                             budgetID: "grp-1", budgetName: "Foyer", encryptionPassword: "secret"),
        session: StubProtocol.session()
    )

    init() {
        StubProtocol.routes = [:]
        StubProtocol.seen = []
    }

    @Test func monthDecodesGroupsAndSendsHeaders() async throws {
        StubProtocol.routes = ["GET /v1/budgets/grp-1/months/2026-11": (200, """
            {"data":{"month":"2026-11","incomeAvailable":0,"toBudget":12000,"totalBudgeted":-180000,
              "totalIncome":250000,"totalSpent":-64050,"totalBalance":115950,
              "categoryGroups":[
                {"id":"g1","name":"Courant","is_income":false,"hidden":false,"budgeted":60000,"spent":-45000,"balance":15000,
                 "categories":[{"id":"c1","name":"Alimentation","is_income":false,"hidden":false,"group_id":"g1","budgeted":40000,"spent":-42000,"balance":-2000,"carryover":false}]},
                {"id":"g2","name":"Revenus","is_income":true,"hidden":false,"categories":[]}
              ]}}
            """)]
        let month = try await client.month("2026-11")
        #expect(month.expenseGroups.map(\.name) == ["Courant"])
        #expect(month.categoriesByID["c1"]?.balance == -2000)
        #expect(month.categoriesByID["c1"]?.progress == 1.05)
        let request = try #require(StubProtocol.seen.first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k3y")
        #expect(request.value(forHTTPHeaderField: "budget-encryption-password") == "secret")
    }

    @Test func transactionsMergeAccountsNewestFirst() async throws {
        StubProtocol.routes = [
            "GET /v1/budgets/grp-1/accounts/a1/transactions": (200, """
                {"data":[{"id":"t1","account":"a1","date":"2026-11-02","amount":-1250,"payee":"p1","category":"c1","is_parent":false,"cleared":true,"transfer_id":null,"subtransactions":[]}]}
                """),
            "GET /v1/budgets/grp-1/accounts/a2/transactions": (200, """
                {"data":[{"id":"t2","account":"a2","date":"2026-11-04","amount":-500,"payee":"p2","category":null,"transfer_id":"t9","cleared":false}]}
                """),
        ]
        let all = try await client.transactions(month: "2026-11", accounts: [ActualAccount(id: "a1", name: "Courant"),
                                                                           ActualAccount(id: "a2", name: "Livret")])
        #expect(all.map(\.id) == ["t2", "t1"])
        #expect(all.first?.isTransfer == true)
        let query = StubProtocol.seen.compactMap { $0.url?.query() }.first { $0.contains("since_date") }
        #expect(query == "since_date=2026-11-01&until_date=2026-11-30")
    }

    @Test func creatingSendsCentsAndPayeeName() async throws {
        StubProtocol.routes = ["POST /v1/budgets/grp-1/accounts/a1/transactions": (200, #"{"message":"ok"}"#)]
        try await client.addTransaction(account: "a1", ActualTransactionDraft(
            date: "2026-11-06", amount: ActualTransactionDraft.cents(-4.2), payeeName: "Boulangerie", category: "c1"))
        let body = try #require(StubProtocol.seen.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let transaction = try #require(json["transaction"] as? [String: Any])
        #expect(json["learnCategories"] as? Bool == true)
        #expect(transaction["amount"] as? Int == -420)
        #expect(transaction["payee_name"] as? String == "Boulangerie")
        #expect(transaction["account"] as? String == "a1")
    }

    @Test func rejectedKeyIsReadable() async {
        StubProtocol.routes = ["GET /v1/budgets": (403, #"{"error":"Forbidden"}"#)]
        await #expect(throws: ActualError.rejectedKey) {
            _ = try await ActualClient.budgets(server: ServerURL("https://actual-api.example.com")!, apiKey: "bad",
                                               session: StubProtocol.session())
        }
    }
} }
