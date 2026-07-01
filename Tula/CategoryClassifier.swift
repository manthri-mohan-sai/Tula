import Foundation

/// High-precision, deterministic item→category classifier.
///
/// **Why this exists.** The language model (and merchant-rule fuzzy matcher)
/// occasionally mis-route an obvious item list — e.g. "onions, tomatoes, ginger
/// garlic paste" landing in *Health* instead of *Groceries*. Those inputs aren't
/// ambiguous to a human, so they shouldn't be left to a probabilistic model.
/// This classifier owns the unambiguous cases with a curated lexicon and stays
/// **silent (returns nil) whenever the signal is weak or tied**, deferring to
/// the FM / rule chain. Precision over recall — a confident answer here is
/// trusted above the model, which is how quick-log entries land correctly
/// without the user re-editing.
///
/// Lexicons deliberately exclude genuinely ambiguous tokens (paneer, noodles,
/// snacks) so the classifier never *confidently* guesses wrong.
enum CategoryClassifier {

    /// A canonical bucket, the synonyms used to map it onto the user's own
    /// category names, and the tokens that near-certainly imply it.
    private struct Lexicon {
        let canonical: String
        let synonyms: [String]
        let tokens: Set<String>
    }

    private static let lexicons: [Lexicon] = [
        Lexicon(
            canonical: "Groceries",
            synonyms: ["grocer", "vegetable", "kirana", "provision"],
            tokens: [
                "onion", "tomato", "potato", "ginger", "garlic", "paste", "chilli",
                "chili", "coriander", "cilantro", "spinach", "palak", "methi",
                "carrot", "bean", "pea", "cabbage", "cauliflower", "gobi", "brinjal",
                "eggplant", "capsicum", "cucumber", "pumpkin", "radish", "beetroot",
                "okra", "bhindi", "lemon", "lime", "banana", "apple", "mango",
                "orange", "grape", "pomegranate", "papaya", "watermelon", "guava",
                "pineapple", "kiwi", "strawberry", "fruit", "vegetable", "veggie",
                "sabzi", "subzi", "rice", "atta", "flour", "maida", "sooji", "rava",
                "dal", "lentil", "pulse", "sugar", "salt", "oil", "ghee", "milk",
                "doodh", "curd", "dahi", "yogurt", "butter", "cheese", "egg",
                "bread", "masala", "turmeric", "haldi", "jeera", "cumin", "mustard",
                "ketchup", "jam", "honey", "biscuit", "namkeen", "chip", "oat",
                "cereal", "cornflake", "peanut", "almond", "cashew", "raisin",
                "nut", "coconut", "tamarind", "jaggery", "gud", "besan", "poha",
                "soap", "shampoo", "toothpaste", "detergent", "tissue", "grocery",
                "kirana", "provision", "supermarket"
            ]
        ),
        Lexicon(
            canonical: "Food",
            synonyms: ["food", "dining", "drink", "restaurant", "eat", "meal"],
            tokens: [
                "biryani", "biriyani", "dosa", "idli", "vada", "samosa", "pizza",
                "burger", "sandwich", "roll", "wrap", "momo", "chowmein",
                "manchurian", "pulao", "thali", "meal", "lunch", "dinner",
                "breakfast", "brunch", "paratha", "roti", "naan", "kulcha", "puri",
                "chole", "rajma", "curry", "kebab", "tikka", "tandoori", "shawarma",
                "frankie", "dabeli", "pavbhaji", "vadapav", "misal", "upma",
                "pongal", "uttapam", "cake", "pastry", "donut", "brownie", "cookie",
                "icecream", "kulfi", "falooda", "lassi", "milkshake", "smoothie",
                "restaurant", "cafe", "dhaba", "swiggy", "zomato", "domino",
                "mcdonald", "kfc", "pizzahut", "burgerking", "starbucks",
                "chai", "tea", "coffee"
            ]
        ),
        Lexicon(
            canonical: "Transport",
            synonyms: ["transport", "commute", "fuel", "cab", "travel"],
            tokens: [
                "cab", "auto", "ola", "uber", "rapido", "taxi", "metro", "bus",
                "train", "rickshaw", "petrol", "diesel", "fuel", "cng", "parking",
                "toll", "flight"
            ]
        ),
        Lexicon(
            canonical: "Health",
            synonyms: ["health", "medical", "medicine", "pharma"],
            tokens: [
                "medicine", "tablet", "capsule", "syrup", "doctor", "hospital",
                "clinic", "pharmacy", "chemist", "dawai", "crocin", "dolo",
                "paracetamol", "bandage", "ointment", "prescription", "checkup",
                "vaccine", "injection", "apollo", "pharmeasy"
            ]
        ),
        Lexicon(
            canonical: "Bills",
            synonyms: ["bill", "utilit", "recharge"],
            tokens: [
                "electricity", "recharge", "broadband", "internet", "wifi", "dth",
                "postpaid", "prepaid", "cylinder", "bill"
            ]
        ),
        Lexicon(
            canonical: "Entertainment",
            synonyms: ["entertain", "leisure", "movie"],
            tokens: ["movie", "cinema", "netflix", "spotify", "bookmyshow",
                     "concert", "game", "pvr"]
        ),
        Lexicon(
            canonical: "Personal Care",
            synonyms: ["personal", "care", "beauty", "groom", "salon"],
            tokens: ["salon", "haircut", "parlour", "spa", "facial", "barber"]
        ),
        Lexicon(
            canonical: "Shopping",
            synonyms: ["shop", "cloth", "electronic"],
            tokens: ["shirt", "jean", "tshirt", "shoe", "dress", "kurta", "saree",
                     "laptop", "charger", "headphone", "earbud", "clothes", "myntra"]
        )
    ]

    /// Classify free text into one of the user's categories, or nil when the
    /// item signal is absent, weak, or tied between buckets.
    static func classify(_ text: String, into categories: [Category]) -> Category? {
        let tokens = self.tokens(in: text)
        guard !tokens.isEmpty else { return nil }

        var scores: [Int: Int] = [:]   // lexicon index → matched-token count
        for (index, lexicon) in lexicons.enumerated() {
            let score = tokens.reduce(0) { partial, token in
                candidateForms(token).contains(where: lexicon.tokens.contains)
                    ? partial + 1 : partial
            }
            if score > 0 { scores[index] = score }
        }
        guard !scores.isEmpty else { return nil }

        let ranked = scores.sorted { $0.value > $1.value }
        let (topIndex, topScore) = (ranked[0].key, ranked[0].value)

        // A tie at the top means the input straddles two buckets — defer.
        if ranked.count > 1, ranked[1].value == topScore { return nil }

        return resolve(canonical: lexicons[topIndex], in: categories)
    }

    // MARK: - Helpers

    /// Lowercased alphanumeric tokens of length ≥ 3.
    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    /// Candidate singular forms for a token, covering simple plurals
    /// ("onions" → "onion", "tomatoes" → "tomato", "shoes" → "shoe").
    private static func candidateForms(_ token: String) -> Set<String> {
        var forms: Set<String> = [token]
        if token.hasSuffix("es"), token.count > 4 {
            forms.insert(String(token.dropLast(2)))
        }
        if token.hasSuffix("s"), token.count > 3 {
            forms.insert(String(token.dropLast()))
        }
        return forms
    }

    /// Map a canonical bucket onto the user's actual category list via its
    /// synonyms. Returns nil when the user has no comparable category.
    private static func resolve(canonical lexicon: Lexicon,
                                in categories: [Category]) -> Category? {
        let active = categories.filter { !$0.isArchived }
        for synonym in lexicon.synonyms {
            if let match = active.first(where: {
                $0.name.lowercased().contains(synonym)
            }) {
                return match
            }
        }
        return nil
    }
}
