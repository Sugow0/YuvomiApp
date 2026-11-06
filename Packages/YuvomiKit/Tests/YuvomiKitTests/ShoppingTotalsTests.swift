import Foundation
import Testing
@testable import YuvomiKit

private func entry(_ name: String, _ quantity: String?, _ category: String? = nil) -> RecipeIngredient {
    RecipeIngredient(name: name, quantity: quantity, category: category)
}

@Test func sameIngredientAddsUpAcrossRecipes() {
    let totals = ShoppingTotals.combine([entry("Œufs", "3"), entry("œufs ", "2"), entry("Farine", "200 g")])
    #expect(totals == [
        ShoppingTotal(name: "Œufs", quantity: "5", category: nil),
        ShoppingTotal(name: "Farine", quantity: "200 g", category: nil),
    ])
}

@Test func compatibleUnitsAreConverted() {
    let totals = ShoppingTotals.combine([entry("Riz", "500 g"), entry("riz", "1 kg"), entry("Lait", "25 cl"), entry("Lait", "1 l")])
    #expect(totals.map(\.quantity) == ["1,5 kg", "1,25 l"])
}

@Test func fractionsAndDecimalsAreRead() {
    let totals = ShoppingTotals.combine([entry("Beurre", "1/2 plaquette"), entry("Beurre", "1,5 plaquette"), entry("Citron", "½"), entry("Citron", "1")])
    #expect(totals.map(\.quantity) == ["2 plaquette", "1,5"])
}

@Test func unlikeAmountsAreListedSideBySide() {
    let totals = ShoppingTotals.combine([
        entry("Sel", "1 pincée"), entry("Sel", nil), entry("Sel", "au goût"), entry("Sel", "2 pincées"),
        entry("Tomates", "2"), entry("Tomates", "400 g"),
    ])
    #expect(totals.map(\.quantity) == ["3 pincée + au goût", "2 + 400 g"])
}

@Test func noAmountAnywhereStaysEmptyAndCategoryIsKept() {
    let totals = ShoppingTotals.combine([entry("Persil", nil, "Fruits & légumes"), entry("persil", "", nil)])
    #expect(totals == [ShoppingTotal(name: "Persil", quantity: nil, category: "Fruits & légumes")])
}

@Test func moreOfAnOpenItemAddsToItsAmount() {
    #expect(ShoppingTotals.adding("3", to: "5") == "8")
    #expect(ShoppingTotals.adding("500 g", to: "1 kg") == "1,5 kg")
    #expect(ShoppingTotals.adding(nil, to: "2") == "2")
    #expect(ShoppingTotals.adding("2", to: nil) == "2")
    #expect(ShoppingTotals.adding(nil, to: nil) == nil)
    #expect(ShoppingTotals.adding("3", to: "2 + 400 g") == "5 + 400 g")
}

@Test func removingARecipeTakesItsAmountBackOff() {
    #expect(ShoppingTotals.removing("3", from: "8") == .keep("5"))
    #expect(ShoppingTotals.removing("500 g", from: "1,5 kg") == .keep("1 kg"))
    #expect(ShoppingTotals.removing("200 g", from: "200 g") == .remove)
    #expect(ShoppingTotals.removing("4", from: "3") == .remove)
    #expect(ShoppingTotals.removing("2", from: "2 + 400 g") == .keep("400 g"))
}

@Test func removingNeverDropsWhatItCannotCount() {
    // Another meal may need the salt; units that do not match say nothing either.
    #expect(ShoppingTotals.removing(nil, from: nil) == .keep(nil))
    #expect(ShoppingTotals.removing("1 pincée", from: "au goût") == .keep("au goût"))
    #expect(ShoppingTotals.removing("2", from: "400 g") == .keep("400 g"))
    #expect(ShoppingTotals.removing("1 pincée", from: "3 pincée + au goût") == .keep("2 pincée + au goût"))
}
