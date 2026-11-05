import Testing
@testable import YuvomiKit

@Test func dictationSplitsIntoItems() {
    #expect(ShoppingEntry.parse("du lait et des œufs") == [.init(name: "Lait"), .init(name: "Œufs")])
    #expect(ShoppingEntry.parse("2 baguettes, de la farine, puis l'huile d'olive.") == [
        .init(name: "Baguettes", quantity: "2"), .init(name: "Farine"), .init(name: "Huile d'olive"),
    ])
}

@Test func keepsWordsThatOnlyLookLikeArticles() {
    #expect(ShoppingEntry.parse("Lessive") == [.init(name: "Lessive")])
    #expect(ShoppingEntry.parse("Desserts") == [.init(name: "Desserts")])
    #expect(ShoppingEntry.parse("  ,  ").isEmpty)
}
