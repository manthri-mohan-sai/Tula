import Foundation
import SwiftData

/// First-launch seed data. Populates the database with:
/// - 12 sensible default categories with icons + colors
/// - 2 default accounts (Bank, Cash) — credit cards and wallets are
///   user-added since they vary per person
/// - ~50 merchant rules for popular Indian merchants
///
/// Idempotent: re-running won't double-insert anything, but the gating in
/// TulaApp via @AppStorage("seedDataInstalled") prevents the work entirely
/// after the first successful run.
enum SeedData {

    static func installIfNeeded(into context: ModelContext) {
        // Only seed if there are no categories yet. The @AppStorage flag is the
        // primary gate; this is belt-and-suspenders for cases where the user
        // deletes & reinstalls but local @AppStorage somehow persisted (unlikely).
        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        guard existing.isEmpty else { return }

        let categories = installCategories(into: context)
        installAccounts(into: context)
        installMerchantRules(into: context, categories: categories)

        try? context.save()
    }

    // MARK: Categories

    /// Returns the inserted categories so merchant-rule seeding can reference them.
    private static func installCategories(into context: ModelContext) -> [String: Category] {
        let defaults: [(name: String, icon: String, color: String)] = [
            ("Food",             "fork.knife",            "#FF6B6B"),
            ("Groceries",        "cart.fill",             "#51CF66"),
            ("Transport",        "car.fill",              "#339AF0"),
            ("Shopping",         "bag.fill",              "#F783AC"),
            ("Entertainment",    "popcorn.fill",          "#9775FA"),
            ("Bills & Utilities","bolt.fill",             "#FFD43B"),
            ("Rent",             "house.fill",            "#A18072"),
            ("Health",           "cross.case.fill",       "#FF8787"),
            ("Education",        "book.fill",             "#20C997"),
            ("Travel",           "airplane",              "#22B8CF"),
            ("Personal Care",    "drop.fill",             "#CC5DE8"),
            ("Other",            "ellipsis.circle.fill",  "#868E96"),
        ]

        var map: [String: Category] = [:]
        for (index, def) in defaults.enumerated() {
            let cat = Category(name: def.name, iconKey: def.icon,
                               colorHex: def.color, sortOrder: index)
            context.insert(cat)
            map[def.name] = cat
        }
        return map
    }

    // MARK: Accounts

    private static func installAccounts(into context: ModelContext) {
        let bank = Account(name: "Bank", kind: .bank,
                           iconKey: "building.columns", colorHex: "#4A90E2",
                           sortOrder: 0)
        let cash = Account(name: "Cash", kind: .cash,
                           iconKey: "banknote.fill", colorHex: "#51CF66",
                           sortOrder: 1)
        context.insert(bank)
        context.insert(cash)
    }

    // MARK: Merchant Rules

    /// Curated for Indian users — covers the merchants that dominate everyday
    /// spending. Patterns are lowercased substrings; matching is case-insensitive
    /// against the merchant field of an expense.
    private static func installMerchantRules(into context: ModelContext,
                                              categories: [String: Category]) {
        let rules: [(pattern: String, categoryName: String)] = [
            // Food / Dining
            ("swiggy",         "Food"),
            ("zomato",         "Food"),
            ("dunzo",          "Food"),
            ("eatsure",        "Food"),
            ("starbucks",      "Food"),
            ("ccd",            "Food"),
            ("cafe coffee day","Food"),
            ("mcdonald",       "Food"),
            ("kfc",            "Food"),
            ("dominos",        "Food"),
            ("pizza hut",      "Food"),
            ("subway",         "Food"),
            ("burger king",    "Food"),
            ("blue tokai",     "Food"),
            ("third wave",     "Food"),

            // Groceries / Quick Commerce
            ("blinkit",        "Groceries"),
            ("zepto",          "Groceries"),
            ("instamart",      "Groceries"),
            ("bigbasket",      "Groceries"),
            ("dmart",          "Groceries"),
            ("more retail",    "Groceries"),
            ("reliance fresh", "Groceries"),
            ("nature's basket","Groceries"),

            // Transport
            ("uber",           "Transport"),
            ("ola",            "Transport"),
            ("rapido",         "Transport"),
            ("irctc",          "Transport"),
            ("redbus",         "Transport"),
            ("indigo",         "Transport"),
            ("vistara",        "Transport"),
            ("air india",      "Transport"),
            ("spicejet",       "Transport"),
            ("petrol",         "Transport"),
            ("fastag",         "Transport"),
            ("metro",          "Transport"),

            // Shopping
            ("amazon",         "Shopping"),
            ("flipkart",       "Shopping"),
            ("myntra",         "Shopping"),
            ("ajio",           "Shopping"),
            ("nykaa",          "Shopping"),
            ("meesho",         "Shopping"),
            ("tata cliq",      "Shopping"),
            ("decathlon",      "Shopping"),
            ("ikea",           "Shopping"),

            // Entertainment
            ("bookmyshow",     "Entertainment"),
            ("netflix",        "Entertainment"),
            ("prime video",    "Entertainment"),
            ("hotstar",        "Entertainment"),
            ("disney+",        "Entertainment"),
            ("spotify",        "Entertainment"),
            ("youtube premium","Entertainment"),
            ("zee5",           "Entertainment"),
            ("sonyliv",        "Entertainment"),
            ("apple music",    "Entertainment"),

            // Bills & Utilities
            ("airtel",         "Bills & Utilities"),
            ("jio",            "Bills & Utilities"),
            ("vi",             "Bills & Utilities"),
            ("vodafone",       "Bills & Utilities"),
            ("electricity",    "Bills & Utilities"),
            ("bescom",         "Bills & Utilities"),
            ("tata power",     "Bills & Utilities"),
            ("gas bill",       "Bills & Utilities"),
            ("water bill",     "Bills & Utilities"),
            ("broadband",      "Bills & Utilities"),
            ("act fibernet",   "Bills & Utilities"),

            // Health
            ("apollo",         "Health"),
            ("1mg",            "Health"),
            ("pharmeasy",      "Health"),
            ("netmeds",        "Health"),
            ("practo",         "Health"),
            ("cult.fit",       "Health"),
            ("cure.fit",       "Health"),
            ("gym",             "Health"),

            // Education
            ("byjus",          "Education"),
            ("udemy",          "Education"),
            ("coursera",       "Education"),
            ("unacademy",      "Education"),
            ("vedantu",        "Education"),
            ("upgrad",         "Education"),

            // Travel
            ("makemytrip",     "Travel"),
            ("goibibo",        "Travel"),
            ("ixigo",          "Travel"),
            ("oyo",            "Travel"),
            ("airbnb",         "Travel"),
            ("booking.com",    "Travel"),
            ("agoda",          "Travel"),

            // Personal Care
            ("salon",          "Personal Care"),
            ("urbanclap",      "Personal Care"),
            ("urban company",  "Personal Care"),
        ]

        for rule in rules {
            guard let cat = categories[rule.categoryName] else { continue }
            let merchantRule = MerchantRule(pattern: rule.pattern,
                                            category: cat,
                                            isUserDefined: false)
            context.insert(merchantRule)
        }
    }
}
