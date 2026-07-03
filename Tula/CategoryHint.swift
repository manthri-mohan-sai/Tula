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
            return "restaurants, cafes, food delivery, dining out, snacks, tea, coffee, lunch, dinner, breakfast, biryani, pizza, burger, chai, samosa, dosa, thali, meal, noodles, momos, sweets, bakery, juice, paneer, roti, paratha, idli, vada, pav, sandwich, wrap, roll, shawarma, kebab, tandoori, kulcha, naan, puri, bhaji, chaat, golgappa, pani puri, sev puri, dabeli, frankie, tikka, malai, lassi, milkshake, smoothie, falooda, kulfi, ice cream, gelato, pastry, donut, muffin, brownie, cookie, biscuit, biscoff, lotus, oreo, cake, waffle, pancake, croissant, nachos, fries, wings, steak, sushi, ramen, pho, dim sum, dumpling, momo, chowmein, manchurian, fried rice, pulao, khichdi, rajma, chole, aloo, gobi, bhindi, dal makhani, butter chicken, chicken tikka, fish fry, egg, omelette, maggi, poha, upma, uttapam, medu vada, pongal, pesarattu, misal pav, vada pav, bhel puri, jalebi, gulab jamun, rasgulla, barfi, ladoo, halwa, kheer, payasam, rabri, mithai, tiffin, nashta, khana, snack"
        // Groceries
        case "basket.fill", "cart.fill", "bag.fill":
            return "supermarkets, grocery stores, kirana, vegetables, fruits, fruit, milk, eggs, rice, atta, dal, oil, bread, dairy, daily essentials, provisions, sabzi, subzi, grocery, doodh, butter, cheese, flour, sugar, masala, spices, apple, banana, mango, orange, onion, potato, tomato, pomegranate, grapes, papaya, watermelon, lemon, ginger, garlic, coriander, paneer, curd, yogurt, ghee, cream, chips, biscuits, cookies, chocolate, namkeen, mixture, papad, pickle, achar, jam, ketchup, sauce, noodles, pasta, oats, cereal, muesli, cornflakes, peanut butter, honey, tea leaves, coffee powder, detergent, soap, shampoo, toothpaste, tissue, napkins, salt, pepper, turmeric, chilli, cumin, jeera, cinnamon, cardamom, saffron, besan, sooji, maida, poha flakes, jaggery, nuts, almonds, cashew, raisins, dates, dry fruits, coconut, tamarind, vinegar, soda, water bottle, juice pack, amul, mother dairy, britannia, parle, haldirams, lijjat, aashirvaad, fortune, saffola, tata"
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
            return "pharmacies, medicines, doctors, hospitals, clinics, lab tests, medical, checkup, health, prescription, medicine, doctor, hospital, pharmacy, dawai, tablet, capsule, syrup, ointment, bandage, sanitizer, thermometer, inhaler, drops, vitamins, supplements, protein, crocin, dolo, paracetamol, aspirin, antacid, digene, eno, vicks, ibuprofen, betadine"
        // Shopping (clothes, electronics, lifestyle)
        case "tshirt.fill", "tv.fill", "laptopcomputer", "iphone",
             "tag.fill":
            return "clothing, electronics, gadgets, lifestyle, online shopping, accessories, clothes, shoes, shirt, jeans, phone, laptop, headphones, earbuds, airpods, charger, cable, case, cover, watch, sunglasses, perfume, deodorant, bag, backpack, wallet, belt, kurta, saree, lehenga, kurti, chudi, dress, trousers, shorts, sneakers, sandals, slippers, chappal"
        // Entertainment / leisure
        case "film.fill", "ticket.fill", "music.note", "gamecontroller.fill",
             "popcorn.fill":
            return "movies, concerts, streaming, games, theatre, events, movie, tickets, netflix, spotify, gaming, popcorn, arcade, bowling, paintball, cricket, football, badminton, swimming, match, show, standup, comedy, drama, musical"
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
        case "gift.fill":
            return "gifts, donations, charity"
        default:
            return nil
        }
    }

    // MARK: - Compound Phrases

    /// Compound phrases that indicate a specific category. Checked BEFORE
    /// individual token matching so "movie ticket" hits Entertainment even
    /// though "movie" alone might also hit it. Longer phrases first to
    /// avoid partial matches.
    private static let compoundPhrases: [(phrase: String, category: String)] = [
        // Entertainment
        ("movie ticket", "Entertainment"), ("movie tickets", "Entertainment"),
        ("concert ticket", "Entertainment"), ("concert tickets", "Entertainment"),
        ("game pass", "Entertainment"), ("amusement park", "Entertainment"),
        ("theme park", "Entertainment"), ("escape room", "Entertainment"),
        ("book ticket", "Entertainment"),
        // Food (compound items clearly food)
        ("office lunch", "Food"), ("team lunch", "Food"),
        ("team dinner", "Food"), ("working lunch", "Food"),
        ("coffee break", "Food"), ("chai nashta", "Food"),
        ("nashta", "Food"),
        // Transport
        ("cab fare", "Transport"), ("auto fare", "Transport"),
        ("metro card", "Transport"), ("bus pass", "Transport"),
        ("toll charge", "Transport"), ("parking fee", "Transport"),
        ("cab ride", "Transport"), ("auto ride", "Transport"),
        // Health
        ("doctor visit", "Health"), ("lab test", "Health"),
        ("blood test", "Health"), ("health checkup", "Health"),
        ("eye checkup", "Health"), ("dawai", "Health"),
        // Education
        ("school fees", "Education"), ("school fee", "Education"),
        ("tuition fee", "Education"), ("tuition fees", "Education"),
        ("coaching class", "Education"), ("online course", "Education"),
        // Personal Care
        ("hair cut", "Personal Care"), ("haircut", "Personal Care"),
        ("spa visit", "Personal Care"),
        // Subscriptions
        ("gym membership", "Subscriptions"), ("club membership", "Subscriptions"),
        // Home
        ("house rent", "Home"), ("pest control", "Home"),
        ("water purifier", "Home"),
        // Bills & Utilities
        ("phone recharge", "Bills"), ("mobile recharge", "Bills"),
        ("electricity bill", "Bills"), ("gas cylinder", "Bills"),
        ("wifi bill", "Bills"), ("internet bill", "Bills"),
    ]

    // MARK: - Action Verbs

    /// Verbs/action words that strongly indicate a category context.
    /// Weaker than compound phrases or keyword matches — only used when
    /// no other signal found a category.
    private static let actionVerbs: [String: String] = [
        // Food
        "ate": "Food", "eaten": "Food", "dined": "Food",
        "ordered": "Food", "drank": "Food",
        // Entertainment
        "watched": "Entertainment", "streamed": "Entertainment",
        "played": "Entertainment",
        // Transport
        "drove": "Transport", "rode": "Transport",
        "commuted": "Transport", "traveled": "Transport",
        "travelled": "Transport",
        "refueled": "Transport", "fueled": "Transport",
        // Shopping
        "purchased": "Shopping", "shopped": "Shopping",
        // Health
        "consulted": "Health", "prescribed": "Health",
    ]

    /// Match input text against category hint keywords. Used by the rule
    /// parser as a semantic fallback when neither direct name match nor
    /// MerchantRule/FuzzyMatcher found a category.
    ///
    /// **Priority order:**
    /// 1. Compound phrase match (strongest — "movie ticket" → Entertainment)
    /// 2. Single-token keyword match (existing — "fruits" → Groceries)
    /// 3. Action-verb inference (weakest — "ate" → Food)
    ///
    /// **Minimum token length**: 3 characters — avoids matching on tiny
    /// filler words ("on", "at", "to").
    static func matchCategory(
        text: String,
        categories: [(category: Category, iconKey: String)]
    ) -> Category? {
        let lowered = text.lowercased()

        // Phase 1: Compound phrase match (strongest signal).
        for entry in compoundPhrases {
            guard lowered.contains(entry.phrase) else { continue }
            if let cat = categories.first(where: {
                $0.category.name.localizedCaseInsensitiveCompare(entry.category) == .orderedSame
                || $0.category.name.lowercased().contains(entry.category.lowercased())
            }) {
                return cat.category
            }
        }

        // Phase 2: Single-token keyword match.
        let inputTokens = Array(
            lowered
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

        if bestScore > 0 { return bestCategory }

        // Phase 3: Action verb inference (only if Phase 2 found nothing).
        for token in inputTokens {
            if let targetCategory = actionVerbs[token] {
                if let cat = categories.first(where: {
                    $0.category.name.localizedCaseInsensitiveCompare(targetCategory) == .orderedSame
                    || $0.category.name.lowercased().contains(targetCategory.lowercased())
                }) {
                    return cat.category
                }
            }
        }

        return nil
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
