//
//  CategoryHint.swift
//  Tula
//
//  Created by Mohan Manthri on 30/05/26.
//


import Foundation

/// Helpers that build richer category context for Foundation Models
/// prompts. The on-device model is smart enough to categorize correctly
/// when it knows what each category is FOR — but it needs prompts that
/// describe each category's intent, not just its name.
///
/// **Why this exists**: passing "Food, Groceries, Transport, Health,
/// Shopping, Other" to FM is weak — the model has to guess the user's
/// taxonomy. Passing "Food (restaurants, dining), Transport (petrol,
/// cabs, transit), ..." makes the model's job trivial. The descriptions
/// come from icon keys (SF Symbols) since the Category model doesn't
/// have a user-authored description field.
///
/// **Maintenance**: when new default icons ship via SeedData, add their
/// keys here. Missing entries fall back to the category name alone —
/// degrades gracefully without breaking.
enum CategoryHint {

    /// Map an SF Symbol icon key to a short descriptive phrase that
    /// captures the category's intent in 2-6 keywords. The keywords
    /// are what the FM will pattern-match incoming merchants/items
    /// against, so they should cover the common cases (fuel includes
    /// petrol AND CNG; transport includes cabs AND auto AND metro).
    ///
    /// **Conservative on edge cases**: when an icon could plausibly
    /// fit multiple categories (e.g., "bag" → could be Groceries OR
    /// Shopping), the hint sticks to the dominant interpretation and
    /// trusts the user-assigned category name to disambiguate.
    static func description(forIcon icon: String) -> String? {
        switch icon {
        // Food & dining
        case "fork.knife", "fork.knife.circle.fill",
             "cup.and.saucer.fill", "takeoutbag.and.cup.and.straw.fill":
            return "restaurants, cafes, food delivery, dining out, snacks, tea, coffee, lunch, dinner, breakfast, biryani, pizza, burger, chai, samosa, dosa, thali, meal, noodles, momos, sweets, bakery, juice, paneer, roti, paratha, idli, vada, pav"
        // Groceries
        case "basket.fill", "cart.fill", "bag.fill":
            return "supermarkets, grocery stores, kirana, vegetables, fruits, fruit, milk, eggs, rice, atta, dal, oil, bread, dairy, daily essentials, provisions, sabzi, subzi, grocery, doodh, butter, cheese, flour, sugar, masala, spices, apple, banana, mango, orange, onion, potato, tomato, pomegranate, grapes, papaya, watermelon, lemon, ginger, garlic, coriander, paneer"
        // Transport - fuel
        case "fuelpump.fill", "fuelpump":
            return "petrol, fuel, diesel, CNG, gas station, petrol pump, filling station"
        // Transport - mobility
        case "car.fill", "bus.fill", "tram.fill", "scooter",
             "figure.walk", "airplane":
            return "cabs, ride-share, ola, uber, auto-rickshaw, metro, bus, train, flights, parking, toll, taxi, cab, auto, rapido"
        // Health / medical
        case "cross.case.fill", "cross.fill", "heart.fill",
             "pills.fill", "stethoscope":
            return "pharmacies, medicines, doctors, hospitals, clinics, lab tests, medical, checkup, health, prescription, medicine, doctor, hospital, pharmacy"
        // Shopping (clothes, electronics, lifestyle)
        case "tshirt.fill", "tv.fill", "laptopcomputer", "iphone",
             "gift.fill", "tag.fill":
            return "clothing, electronics, gadgets, lifestyle, online shopping, accessories, clothes, shoes, shirt, jeans, phone, laptop, headphones"
        // Entertainment / leisure
        case "film.fill", "ticket.fill", "music.note", "gamecontroller.fill",
             "popcorn.fill":
            return "movies, concerts, streaming, games, theatre, events, movie, tickets, netflix, spotify, gaming"
        // Utilities & bills
        case "bolt.fill", "lightbulb.fill", "wifi", "drop.fill",
             "flame.fill", "phone.fill":
            return "electricity, water, gas, internet, mobile recharge, broadband, DTH, bill, bills, recharge, wifi"
        // Home & maintenance
        case "house.fill", "wrench.and.screwdriver.fill",
             "paintbrush.fill", "leaf.fill":
            return "rent, furniture, repairs, maintenance, household items, plants, plumber, electrician, carpenter"
        // Education
        case "book.fill", "graduationcap.fill", "pencil.and.ruler.fill":
            return "school fees, tuition, books, courses, stationery, classes, coaching, academy, exam"
        // Personal care & beauty
        case "scissors", "comb.fill", "drop.degreesign.fill":
            return "salon, haircut, spa, cosmetics, personal care, parlour, beauty, facial, barber"
        // Subscriptions
        case "repeat.circle.fill", "arrow.clockwise":
            return "netflix, spotify, recurring subscriptions, memberships, gym, subscription"
        // Travel
        case "suitcase.fill", "map.fill", "globe":
            return "hotels, tours, travel bookings, vacations, flight, hotel, resort, airbnb"
        // Pets
        case "pawprint.fill", "dog.fill", "cat.fill":
            return "vet, pet food, pet supplies, grooming, veterinary"
        // Kids
        case "figure.child", "teddybear.fill":
            return "toys, school supplies, kids clothing, daycare, diapers, baby"
        // Gifts
        case "gift.fill" as String:
            return "gifts, donations, charity"
        default:
            return nil
        }
    }

    /// Match input text against category hint keywords. Used by the rule
    /// parser as a semantic fallback when neither direct name match nor
    /// MerchantRule/FuzzyMatcher found a category. Tokenizes both the
    /// input and each category's hint into individual words, then counts
    /// overlap. The category with the most keyword hits wins.
    ///
    /// **Minimum token length**: 3 characters — avoids matching on tiny
    /// filler words ("on", "at", "to") that appear in hints as part of
    /// multi-word phrases.
    ///
    /// **Example**: input "fruits" matches Groceries' hint which contains
    /// "fruits, fruit, ...". Input "fuel" matches Fuel/Transport's hint.
    static func matchCategory(
        text: String,
        categories: [(category: Category, iconKey: String)]
    ) -> Category? {
        let inputTokens = Array(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 }
        )
        guard !inputTokens.isEmpty else { return nil }

        var bestCategory: Category?
        var bestScore = 0

        for entry in categories {
            guard let hint = description(forIcon: entry.iconKey) else { continue }
            let hintTokens = Set(
                hint.lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map(String.init)
                    .filter { $0.count >= 3 }
            )

            // Count hits: exact match OR prefix/stem match (handles
            // plurals like "apples" ↔ "apple", "medicines" ↔ "medicine").
            // Prefix match requires both tokens ≥ 4 chars and the shorter
            // one to be a prefix of the longer one — avoids false positives
            // on short words.
            var score = 0
            for input in inputTokens {
                if hintTokens.contains(input) {
                    score += 1
                } else {
                    for hint in hintTokens {
                        let shorter = min(input.count, hint.count)
                        if shorter >= 4 {
                            if input.hasPrefix(hint) || hint.hasPrefix(input) {
                                score += 1
                                break
                            }
                        }
                    }
                }
            }

            if score > bestScore {
                bestScore = score
                bestCategory = entry.category
            }
        }

        return bestScore > 0 ? bestCategory : nil
    }

    /// Build a formatted category list for inclusion in an FM prompt.
    /// Each line: `- {name} ({hint})` when an icon hint is available,
    /// or `- {name}` for categories without a known icon mapping.
    ///
    /// **Input format**: tuples of (name, iconKey). Empty array returns
    /// empty string (callers should guard before invoking FM in that
    /// case since the model needs SOMETHING to pick from).
    ///
    /// **Example output**:
    ///   - Food (restaurants, cafes, food delivery, dining out)
    ///   - Transport (cabs, ride-share, ola, uber, auto-rickshaw, metro)
    ///   - Health (pharmacies, medicines, doctors, hospitals)
    ///   - Other
    static func formatList(_ categories: [(name: String, iconKey: String)]) -> String {
        categories.map { entry in
            if let hint = description(forIcon: entry.iconKey) {
                return "- \(entry.name) (\(hint))"
            }
            return "- \(entry.name)"
        }
        .joined(separator: "\n")
    }
}
