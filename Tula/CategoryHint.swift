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
            return "restaurants, cafes, food delivery, dining out, snacks, tea, coffee"
        // Groceries
        case "basket.fill", "cart.fill", "bag.fill":
            return "supermarkets, grocery stores, kirana, vegetables, dairy, daily essentials"
        // Transport - fuel
        case "fuelpump.fill", "fuelpump":
            return "petrol, fuel, diesel, CNG, gas station"
        // Transport - mobility
        case "car.fill", "bus.fill", "tram.fill", "scooter",
             "figure.walk", "airplane":
            return "cabs, ride-share, ola, uber, auto-rickshaw, metro, bus, train, flights, parking"
        // Health / medical
        case "cross.case.fill", "cross.fill", "heart.fill",
             "pills.fill", "stethoscope":
            return "pharmacies, medicines, doctors, hospitals, clinics, lab tests"
        // Shopping (clothes, electronics, lifestyle)
        case "tshirt.fill", "tv.fill", "laptopcomputer", "iphone",
             "gift.fill", "tag.fill":
            return "clothing, electronics, gadgets, lifestyle, online shopping, accessories"
        // Entertainment / leisure
        case "film.fill", "ticket.fill", "music.note", "gamecontroller.fill",
             "popcorn.fill":
            return "movies, concerts, streaming, games, theatre, events"
        // Utilities & bills
        case "bolt.fill", "lightbulb.fill", "wifi", "drop.fill",
             "flame.fill", "phone.fill":
            return "electricity, water, gas, internet, mobile recharge, broadband, DTH"
        // Home & maintenance
        case "house.fill", "wrench.and.screwdriver.fill",
             "paintbrush.fill", "leaf.fill":
            return "rent, furniture, repairs, maintenance, household items, plants"
        // Education
        case "book.fill", "graduationcap.fill", "pencil.and.ruler.fill":
            return "school fees, tuition, books, courses, stationery, classes"
        // Personal care & beauty
        case "scissors", "comb.fill", "drop.degreesign.fill":
            return "salon, haircut, spa, cosmetics, personal care"
        // Subscriptions
        case "repeat.circle.fill", "arrow.clockwise":
            return "netflix, spotify, recurring subscriptions, memberships"
        // Travel
        case "suitcase.fill", "map.fill", "globe":
            return "hotels, tours, travel bookings, vacations"
        // Pets
        case "pawprint.fill", "dog.fill", "cat.fill":
            return "vet, pet food, pet supplies, grooming"
        // Kids
        case "figure.child", "teddybear.fill":
            return "toys, school supplies, kids' clothing, daycare"
        // Gifts
        case "gift.fill" as String:
            return "gifts, donations, charity"
        default:
            return nil
        }
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