import Foundation
import SwiftData

/// First-launch seed data + ongoing default-rule installer. Populates:
/// - 12 sensible default categories with icons + colors
/// - 2 default accounts (Bank, Cash) — credit cards and wallets are
///   user-added since they vary per person
/// - ~500 merchant rules covering Indian and global merchants/items
///
/// **Two entry points:**
/// 1. `installIfNeeded` — first-launch only (gated by empty Category fetch).
///    Installs categories, accounts, and the full merchant-rule table.
/// 2. `installMissingDefaultMerchantRules` — runs every launch. Idempotent.
///    Adds any rules from the table that don't yet exist in the database,
///    so existing users automatically get new rules when the app updates.
enum SeedData {

    static func installIfNeeded(into context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        guard existing.isEmpty else { return }

        let categories = installCategories(into: context)
        installAccounts(into: context)
        installMerchantRules(into: context, categories: categories)

        try? context.save()
    }

    /// Idempotent installer that adds any default rules missing from the DB.
    /// Run on every app launch — cheap (one fetch + a set diff). Lets us ship
    /// new default categorizations to existing users without database migrations.
    static func installMissingDefaultMerchantRules(into context: ModelContext) {
        // Need category map by name to attach rules.
        guard let allCategories = try? context.fetch(FetchDescriptor<Category>()),
              !allCategories.isEmpty else { return }

        let categoryMap = Dictionary(uniqueKeysWithValues:
            allCategories.map { ($0.name, $0) })

        // Pull existing default-rule patterns. Don't touch user-defined rules
        // — those represent the user's own learning and must be respected
        // even if they conflict with a default rule we ship.
        let existingDefaults = (try? context.fetch(FetchDescriptor<MerchantRule>()))?
            .filter { !$0.isUserDefined }
            .map { $0.pattern } ?? []
        let existingSet = Set(existingDefaults)

        var inserted = 0
        for rule in defaultMerchantRules {
            guard !existingSet.contains(rule.pattern),
                  let cat = categoryMap[rule.categoryName] else { continue }
            context.insert(MerchantRule(pattern: rule.pattern,
                                        category: cat,
                                        isUserDefined: false))
            inserted += 1
        }

        if inserted > 0 {
            try? context.save()
        }
    }

    // MARK: Categories

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

    private static func installMerchantRules(into context: ModelContext,
                                              categories: [String: Category]) {
        for rule in defaultMerchantRules {
            guard let cat = categories[rule.categoryName] else { continue }
            context.insert(MerchantRule(pattern: rule.pattern,
                                        category: cat,
                                        isUserDefined: false))
        }
    }

    // MARK: Default rules table
    //
    // Single source of truth for default merchant→category mappings.
    // Used by both first-install AND the idempotent installer that runs
    // on every launch.
    //
    // Patterns are lowercased substrings, matched case-insensitively against
    // the merchant field. The parser's fuzzy matcher (in ExpenseParser)
    // normalizes whitespace and accepts small edit-distance variations,
    // so "icecream" matches "ice cream", "swigy" matches "swiggy", etc.
    //
    // Order doesn't affect matching (first found wins per launch), but
    // categorization helps maintenance.
    static let defaultMerchantRules: [(pattern: String, categoryName: String)] = [

        // ── FOOD: Delivery apps ──────────────────────────────────────
        ("swiggy", "Food"), ("zomato", "Food"), ("dunzo", "Food"),
        ("eatsure", "Food"), ("eat sure", "Food"), ("faasos", "Food"),
        ("box8", "Food"), ("freshmenu", "Food"), ("fresh menu", "Food"),
        ("eatfit", "Food"), ("eat fit", "Food"), ("behrouz", "Food"),
        ("ovenstory", "Food"), ("mojo pizza", "Food"), ("lunchbox", "Food"),
        ("rebel foods", "Food"),

        // ── FOOD: Global QSR ─────────────────────────────────────────
        ("mcdonald", "Food"), ("mcdonalds", "Food"), ("kfc", "Food"),
        ("dominos", "Food"), ("domino's", "Food"), ("pizza hut", "Food"),
        ("pizzahut", "Food"), ("subway", "Food"), ("burger king", "Food"),
        ("burgerking", "Food"), ("taco bell", "Food"), ("wendys", "Food"),
        ("wendy's", "Food"), ("popeyes", "Food"), ("chipotle", "Food"),

        // ── FOOD: Indian chains ──────────────────────────────────────
        ("haldiram", "Food"), ("bikanervala", "Food"),
        ("saravana bhavan", "Food"), ("sagar ratna", "Food"),
        ("paradise", "Food"), ("empire", "Food"),
        ("punjabi by nature", "Food"), ("karim", "Food"),
        ("barbeque nation", "Food"), ("bbq nation", "Food"),
        ("absolute barbecue", "Food"), ("mainland china", "Food"),
        ("oh calcutta", "Food"), ("copper chimney", "Food"),
        ("rajdhani", "Food"), ("chai point", "Food"), ("chayos", "Food"),
        ("chai sutta", "Food"), ("chai sutta bar", "Food"),
        ("wow momo", "Food"), ("wow momos", "Food"),
        ("nik baker", "Food"), ("theobroma", "Food"), ("monginis", "Food"),

        // ── FOOD: Coffee ─────────────────────────────────────────────
        ("starbucks", "Food"), ("ccd", "Food"), ("cafe coffee day", "Food"),
        ("blue tokai", "Food"), ("third wave", "Food"), ("barista", "Food"),
        ("costa coffee", "Food"), ("tim hortons", "Food"),
        ("dunkin", "Food"), ("dunkin donuts", "Food"),
        ("subko", "Food"), ("araku", "Food"),

        // ── FOOD: North Indian ───────────────────────────────────────
        ("biryani", "Food"), ("biriyani", "Food"), ("butter chicken", "Food"),
        ("dal makhani", "Food"), ("paneer tikka", "Food"), ("tikka", "Food"),
        ("kebab", "Food"), ("seekh", "Food"), ("tandoori", "Food"),
        ("chole", "Food"), ("chole bhature", "Food"), ("bhature", "Food"),
        ("rajma", "Food"), ("kadhi", "Food"), ("sabzi", "Food"),
        ("subzi", "Food"), ("paneer", "Food"), ("paratha", "Food"),
        ("naan", "Food"), ("kulcha", "Food"), ("roti", "Food"),
        ("malai kofta", "Food"), ("shahi paneer", "Food"),
        ("kadai paneer", "Food"), ("aloo gobi", "Food"),
        ("aloo paratha", "Food"), ("paneer paratha", "Food"),

        // ── FOOD: South Indian ───────────────────────────────────────
        ("dosa", "Food"), ("masala dosa", "Food"), ("idli", "Food"),
        ("vada", "Food"), ("medu vada", "Food"), ("sambar", "Food"),
        ("rasam", "Food"), ("upma", "Food"), ("pongal", "Food"),
        ("uttapam", "Food"), ("appam", "Food"), ("puttu", "Food"),
        ("kerala parotta", "Food"), ("rava idli", "Food"),
        ("set dosa", "Food"), ("ghee roast", "Food"),

        // ── FOOD: Street food ────────────────────────────────────────
        ("samosa", "Food"), ("kachori", "Food"), ("pav bhaji", "Food"),
        ("vada pav", "Food"), ("dabeli", "Food"), ("golgappa", "Food"),
        ("panipuri", "Food"), ("pani puri", "Food"), ("bhel", "Food"),
        ("bhel puri", "Food"), ("sev puri", "Food"), ("chaat", "Food"),
        ("aloo tikki", "Food"), ("kathi roll", "Food"), ("frankie", "Food"),
        ("momos", "Food"), ("momo", "Food"), ("puri", "Food"),

        // ── FOOD: Sweets / desserts ──────────────────────────────────
        ("ice cream", "Food"), ("icecream", "Food"), ("ice-cream", "Food"),
        ("kulfi", "Food"), ("gulab jamun", "Food"), ("jalebi", "Food"),
        ("rasgulla", "Food"), ("rasmalai", "Food"), ("ras malai", "Food"),
        ("sandesh", "Food"), ("kheer", "Food"), ("halwa", "Food"),
        ("ladoo", "Food"), ("laddu", "Food"), ("barfi", "Food"),
        ("burfi", "Food"), ("mithai", "Food"), ("sweets", "Food"),
        ("dessert", "Food"), ("cake", "Food"), ("pastry", "Food"),
        ("donut", "Food"), ("doughnut", "Food"), ("brownie", "Food"),
        ("cookie", "Food"), ("waffle", "Food"), ("baskin robbins", "Food"),
        ("baskin", "Food"), ("naturals ice cream", "Food"),
        ("cream stone", "Food"), ("amul", "Food"), ("kwality walls", "Food"),
        ("havmor", "Food"), ("mother dairy", "Food"),

        // ── FOOD: Indo-Chinese & global ──────────────────────────────
        ("chowmein", "Food"), ("chow mein", "Food"), ("manchurian", "Food"),
        ("fried rice", "Food"), ("hakka noodles", "Food"), ("noodles", "Food"),
        ("ramen", "Food"), ("sushi", "Food"), ("pasta", "Food"),
        ("pizza", "Food"), ("burger", "Food"), ("sandwich", "Food"),
        ("wrap", "Food"), ("salad", "Food"), ("bowl", "Food"),
        ("thali", "Food"), ("meals", "Food"),

        // ── FOOD: Quick noodles ──────────────────────────────────────
        ("maggi", "Food"), ("maggie", "Food"), ("yippee", "Food"),
        ("top ramen", "Food"), ("knorr", "Food"), ("cup noodles", "Food"),

        // ── FOOD: Beverages (non-alcoholic) ──────────────────────────
        ("chai", "Food"), ("tea", "Food"), ("coffee", "Food"),
        ("latte", "Food"), ("cappuccino", "Food"), ("espresso", "Food"),
        ("americano", "Food"), ("lassi", "Food"), ("buttermilk", "Food"),
        ("chaas", "Food"), ("juice", "Food"), ("smoothie", "Food"),
        ("milkshake", "Food"), ("shake", "Food"), ("coca cola", "Food"),
        ("cocacola", "Food"), ("pepsi", "Food"), ("sprite", "Food"),
        ("fanta", "Food"), ("thums up", "Food"), ("mountain dew", "Food"),
        ("limca", "Food"), ("frooti", "Food"), ("maaza", "Food"),
        ("red bull", "Food"), ("monster", "Food"), ("redbull", "Food"),
        ("appy fizz", "Food"), ("paper boat", "Food"),

        // ── FOOD: Proteins (generic) ─────────────────────────────────
        ("chicken", "Food"), ("mutton", "Food"), ("fish", "Food"),
        ("prawn", "Food"), ("egg", "Food"), ("omelette", "Food"),
        ("omelet", "Food"), ("bacon", "Food"),

        // ── FOOD: Meal occasions ─────────────────────────────────────
        ("breakfast", "Food"), ("brunch", "Food"), ("lunch", "Food"),
        ("dinner", "Food"), ("supper", "Food"), ("snack", "Food"),
        ("snacks", "Food"), ("food", "Food"), ("meal", "Food"),
        ("dining", "Food"), ("restaurant", "Food"), ("cafe", "Food"),
        ("bakery", "Food"), ("dhaba", "Food"), ("canteen", "Food"),
        ("mess", "Food"), ("tiffin", "Food"),

        // ── GROCERIES: Quick commerce & supermarkets ─────────────────
        ("blinkit", "Groceries"), ("zepto", "Groceries"),
        ("instamart", "Groceries"), ("swiggy instamart", "Groceries"),
        ("bigbasket", "Groceries"), ("big basket", "Groceries"),
        ("bb daily", "Groceries"), ("dmart", "Groceries"),
        ("d-mart", "Groceries"), ("d mart", "Groceries"),
        ("more retail", "Groceries"), ("reliance fresh", "Groceries"),
        ("reliance smart", "Groceries"), ("nature's basket", "Groceries"),
        ("natures basket", "Groceries"), ("spencer", "Groceries"),
        ("spencer's", "Groceries"), ("star bazaar", "Groceries"),
        ("jiomart", "Groceries"), ("jio mart", "Groceries"),
        ("country delight", "Groceries"), ("milk basket", "Groceries"),
        ("milkbasket", "Groceries"), ("supr daily", "Groceries"),
        ("suprdaily", "Groceries"), ("daily ninja", "Groceries"),
        ("dailyninja", "Groceries"), ("licious", "Groceries"),
        ("freshtohome", "Groceries"), ("fresh to home", "Groceries"),
        ("tendercuts", "Groceries"), ("zappfresh", "Groceries"),
        ("otipy", "Groceries"), ("milkmate", "Groceries"),
        ("farmlink", "Groceries"),

        // ── GROCERIES: Generic items ─────────────────────────────────
        ("groceries", "Groceries"), ("grocery", "Groceries"),
        ("vegetables", "Groceries"), ("veggies", "Groceries"),
        ("fruits", "Groceries"), ("milk", "Groceries"),
        ("bread", "Groceries"), ("eggs", "Groceries"),
        ("rice", "Groceries"), ("atta", "Groceries"),
        ("flour", "Groceries"), ("dal", "Groceries"),
        ("oil", "Groceries"), ("ghee", "Groceries"),
        ("masala", "Groceries"), ("spices", "Groceries"),
        ("salt", "Groceries"), ("sugar", "Groceries"),
        ("kirana", "Groceries"), ("supermarket", "Groceries"),

        // ── TRANSPORT: Rideshare ─────────────────────────────────────
        ("uber", "Transport"), ("ola", "Transport"), ("rapido", "Transport"),
        ("lyft", "Transport"), ("blablacar", "Transport"),
        ("bla bla car", "Transport"), ("quick ride", "Transport"),
        ("quickride", "Transport"),

        // ── TRANSPORT: Public ────────────────────────────────────────
        ("metro", "Transport"), ("bus", "Transport"), ("train", "Transport"),
        ("local", "Transport"), ("auto", "Transport"), ("rickshaw", "Transport"),
        ("cab", "Transport"), ("taxi", "Transport"),

        // ── TRANSPORT: Booking ───────────────────────────────────────
        ("irctc", "Transport"), ("redbus", "Transport"),
        ("red bus", "Transport"), ("abhibus", "Transport"),
        ("ksrtc", "Transport"), ("msrtc", "Transport"),
        ("apsrtc", "Transport"), ("tsrtc", "Transport"),

        // ── TRANSPORT: Airlines ──────────────────────────────────────
        ("indigo", "Transport"), ("vistara", "Transport"),
        ("air india", "Transport"), ("airindia", "Transport"),
        ("spicejet", "Transport"), ("spice jet", "Transport"),
        ("akasa", "Transport"), ("akasa air", "Transport"),
        ("go air", "Transport"), ("goair", "Transport"),
        ("go first", "Transport"), ("gofirst", "Transport"),
        ("emirates", "Transport"), ("singapore airlines", "Transport"),
        ("etihad", "Transport"), ("lufthansa", "Transport"),
        ("qatar airways", "Transport"), ("british airways", "Transport"),
        ("united airlines", "Transport"), ("american airlines", "Transport"),
        ("delta airlines", "Transport"), ("klm", "Transport"),
        ("air france", "Transport"), ("turkish airlines", "Transport"),
        ("cathay pacific", "Transport"), ("thai airways", "Transport"),

        // ── TRANSPORT: Fuel ──────────────────────────────────────────
        ("petrol", "Transport"), ("diesel", "Transport"), ("fuel", "Transport"),
        ("gas station", "Transport"), ("petrol pump", "Transport"),
        ("hp petrol", "Transport"), ("iocl", "Transport"),
        ("bpcl", "Transport"), ("indian oil", "Transport"),
        ("indianoil", "Transport"), ("shell petrol", "Transport"),
        ("essar", "Transport"), ("nayara", "Transport"),
        ("reliance petrol", "Transport"),

        // ── TRANSPORT: Tolls & parking ───────────────────────────────
        ("fastag", "Transport"), ("toll", "Transport"),
        ("parking", "Transport"), ("park+", "Transport"),
        ("getmyparking", "Transport"),

        // ── TRANSPORT: Vehicle services ──────────────────────────────
        ("servicing", "Transport"), ("car service", "Transport"),
        ("bike service", "Transport"), ("puc", "Transport"),
        ("rto", "Transport"),

        // ── SHOPPING: Online marketplaces ────────────────────────────
        ("amazon", "Shopping"), ("flipkart", "Shopping"), ("myntra", "Shopping"),
        ("ajio", "Shopping"), ("nykaa", "Shopping"),
        ("nykaa fashion", "Shopping"), ("meesho", "Shopping"),
        ("tata cliq", "Shopping"), ("tatacliq", "Shopping"),
        ("tata neu", "Shopping"), ("tataneu", "Shopping"),
        ("snapdeal", "Shopping"), ("paytm mall", "Shopping"),
        ("jabong", "Shopping"), ("limeroad", "Shopping"),
        ("firstcry", "Shopping"), ("first cry", "Shopping"),
        ("shopclues", "Shopping"), ("club factory", "Shopping"),
        ("shein", "Shopping"), ("urbanic", "Shopping"),
        ("zivame", "Shopping"), ("clovia", "Shopping"),

        // ── SHOPPING: Fashion brands ─────────────────────────────────
        ("zara", "Shopping"), ("h&m", "Shopping"), ("hm india", "Shopping"),
        ("uniqlo", "Shopping"), ("levis", "Shopping"), ("levi's", "Shopping"),
        ("gap", "Shopping"), ("forever 21", "Shopping"),
        ("forever21", "Shopping"), ("mango", "Shopping"),
        ("only", "Shopping"), ("vero moda", "Shopping"),
        ("jack jones", "Shopping"), ("jack & jones", "Shopping"),
        ("us polo", "Shopping"), ("us polo assn", "Shopping"),
        ("tommy hilfiger", "Shopping"), ("calvin klein", "Shopping"),
        ("ralph lauren", "Shopping"), ("polo ralph", "Shopping"),
        ("allen solly", "Shopping"), ("van heusen", "Shopping"),
        ("peter england", "Shopping"), ("louis philippe", "Shopping"),
        ("arrow", "Shopping"), ("park avenue", "Shopping"),

        // ── SHOPPING: Department stores ──────────────────────────────
        ("lifestyle", "Shopping"), ("max", "Shopping"),
        ("pantaloons", "Shopping"), ("westside", "Shopping"),
        ("fbb", "Shopping"), ("big bazaar", "Shopping"),
        ("reliance trends", "Shopping"), ("shoppers stop", "Shopping"),
        ("shopper stop", "Shopping"), ("central", "Shopping"),
        ("brand factory", "Shopping"), ("globus", "Shopping"),

        // ── SHOPPING: Electronics ────────────────────────────────────
        ("croma", "Shopping"), ("reliance digital", "Shopping"),
        ("vijay sales", "Shopping"), ("sangeetha", "Shopping"),
        ("poorvika", "Shopping"), ("lot mobile", "Shopping"),
        ("oneplus", "Shopping"), ("samsung", "Shopping"),
        ("apple store", "Shopping"), ("mi store", "Shopping"),
        ("mi.com", "Shopping"), ("xiaomi", "Shopping"),
        ("realme", "Shopping"), ("oppo", "Shopping"), ("vivo", "Shopping"),
        ("nothing", "Shopping"), ("motorola", "Shopping"),
        ("boat", "Shopping"), ("noise", "Shopping"), ("sony", "Shopping"),
        ("lg", "Shopping"), ("philips", "Shopping"), ("bose", "Shopping"),
        ("jbl", "Shopping"), ("logitech", "Shopping"),
        ("hp store", "Shopping"), ("dell", "Shopping"),
        ("lenovo", "Shopping"), ("asus", "Shopping"), ("acer", "Shopping"),

        // ── SHOPPING: Home / furniture ───────────────────────────────
        ("ikea", "Shopping"), ("urban ladder", "Shopping"),
        ("urbanladder", "Shopping"), ("pepperfry", "Shopping"),
        ("hometown", "Shopping"), ("home centre", "Shopping"),
        ("fabindia", "Shopping"), ("fab india", "Shopping"),
        ("godrej interio", "Shopping"), ("nilkamal", "Shopping"),
        ("home stop", "Shopping"), ("homestop", "Shopping"),

        // ── SHOPPING: Sports & shoes ─────────────────────────────────
        ("decathlon", "Shopping"), ("nike", "Shopping"),
        ("adidas", "Shopping"), ("puma", "Shopping"),
        ("reebok", "Shopping"), ("under armour", "Shopping"),
        ("skechers", "Shopping"), ("new balance", "Shopping"),
        ("asics", "Shopping"), ("woodland", "Shopping"),
        ("bata", "Shopping"), ("liberty", "Shopping"),
        ("crocs", "Shopping"), ("metro shoes", "Shopping"),

        // ── SHOPPING: Beauty & personal care brands ──────────────────
        ("nykaa beauty", "Shopping"), ("mac cosmetics", "Shopping"),
        ("sephora", "Shopping"), ("the body shop", "Shopping"),
        ("body shop", "Shopping"), ("forest essentials", "Shopping"),
        ("kiehl", "Shopping"), ("lakme", "Shopping"),
        ("loreal", "Shopping"), ("l'oreal", "Shopping"),
        ("maybelline", "Shopping"), ("mamaearth", "Shopping"),
        ("mama earth", "Shopping"), ("plum", "Shopping"),
        ("wow skin", "Shopping"), ("the man company", "Shopping"),
        ("beardo", "Shopping"), ("bombay shaving", "Shopping"),
        ("ustraa", "Shopping"), ("biotique", "Shopping"),

        // ── SHOPPING: Generic ────────────────────────────────────────
        ("shopping", "Shopping"), ("clothes", "Shopping"),
        ("clothing", "Shopping"), ("shoes", "Shopping"), ("bag", "Shopping"),
        ("watch", "Shopping"), ("jewellery", "Shopping"),
        ("jewelry", "Shopping"), ("accessories", "Shopping"),

        // ── ENTERTAINMENT: Video streaming ───────────────────────────
        ("netflix", "Entertainment"), ("prime video", "Entertainment"),
        ("primevideo", "Entertainment"), ("amazon prime", "Entertainment"),
        ("hotstar", "Entertainment"), ("disney+", "Entertainment"),
        ("disney plus", "Entertainment"), ("jio cinema", "Entertainment"),
        ("jiocinema", "Entertainment"), ("zee5", "Entertainment"),
        ("sony liv", "Entertainment"), ("sonyliv", "Entertainment"),
        ("voot", "Entertainment"), ("mx player", "Entertainment"),
        ("alt balaji", "Entertainment"), ("altbalaji", "Entertainment"),
        ("hoichoi", "Entertainment"), ("eros now", "Entertainment"),
        ("erosnow", "Entertainment"), ("apple tv", "Entertainment"),
        ("appletv", "Entertainment"), ("youtube premium", "Entertainment"),
        ("youtube", "Entertainment"),

        // ── ENTERTAINMENT: Music ─────────────────────────────────────
        ("spotify", "Entertainment"), ("apple music", "Entertainment"),
        ("amazon music", "Entertainment"), ("gaana", "Entertainment"),
        ("jiosaavn", "Entertainment"), ("jio saavn", "Entertainment"),
        ("saavn", "Entertainment"), ("wynk", "Entertainment"),
        ("youtube music", "Entertainment"), ("tidal", "Entertainment"),

        // ── ENTERTAINMENT: Cinema ────────────────────────────────────
        ("bookmyshow", "Entertainment"), ("book my show", "Entertainment"),
        ("paytm insider", "Entertainment"), ("insider.in", "Entertainment"),
        ("district", "Entertainment"), ("pvr", "Entertainment"),
        ("inox", "Entertainment"), ("cinepolis", "Entertainment"),
        ("cinepolis india", "Entertainment"), ("movie ticket", "Entertainment"),
        ("movie", "Entertainment"), ("cinema", "Entertainment"),
        ("theatre", "Entertainment"), ("theater", "Entertainment"),
        ("concert", "Entertainment"), ("show", "Entertainment"),
        ("play", "Entertainment"),

        // ── ENTERTAINMENT: Gaming ────────────────────────────────────
        ("playstation", "Entertainment"), ("ps5", "Entertainment"),
        ("ps4", "Entertainment"), ("xbox", "Entertainment"),
        ("nintendo", "Entertainment"), ("steam", "Entertainment"),
        ("epic games", "Entertainment"), ("epicgames", "Entertainment"),
        ("fortnite", "Entertainment"), ("free fire", "Entertainment"),
        ("pubg", "Entertainment"), ("bgmi", "Entertainment"),
        ("mobile legends", "Entertainment"), ("clash royale", "Entertainment"),
        ("clash of clans", "Entertainment"), ("genshin", "Entertainment"),

        // ── ENTERTAINMENT: Books / reading ───────────────────────────
        ("kindle", "Entertainment"), ("audible", "Entertainment"),
        ("scribd", "Entertainment"), ("magzter", "Entertainment"),
        ("storytel", "Entertainment"), ("pratilipi", "Entertainment"),
        ("kuku fm", "Entertainment"), ("kukufm", "Entertainment"),
        ("audiobook", "Entertainment"), ("ebook", "Entertainment"),

        // ── BILLS: Mobile carriers ───────────────────────────────────
        ("airtel", "Bills & Utilities"), ("jio", "Bills & Utilities"),
        ("vi ", "Bills & Utilities"), ("vodafone", "Bills & Utilities"),
        ("idea", "Bills & Utilities"), ("bsnl", "Bills & Utilities"),
        ("mtnl", "Bills & Utilities"),

        // ── BILLS: Broadband / DTH ───────────────────────────────────
        ("airtel xstream", "Bills & Utilities"),
        ("airtel fiber", "Bills & Utilities"),
        ("jio fiber", "Bills & Utilities"),
        ("jiofiber", "Bills & Utilities"),
        ("act fibernet", "Bills & Utilities"),
        ("hathway", "Bills & Utilities"), ("tata sky", "Bills & Utilities"),
        ("tatasky", "Bills & Utilities"), ("tata play", "Bills & Utilities"),
        ("dish tv", "Bills & Utilities"), ("dishtv", "Bills & Utilities"),
        ("d2h", "Bills & Utilities"), ("airtel digital", "Bills & Utilities"),
        ("sun direct", "Bills & Utilities"), ("siti cable", "Bills & Utilities"),
        ("you broadband", "Bills & Utilities"),
        ("broadband", "Bills & Utilities"), ("wifi", "Bills & Utilities"),
        ("internet", "Bills & Utilities"), ("recharge", "Bills & Utilities"),

        // ── BILLS: Electricity ───────────────────────────────────────
        ("electricity", "Bills & Utilities"), ("bescom", "Bills & Utilities"),
        ("mseb", "Bills & Utilities"), ("tata power", "Bills & Utilities"),
        ("adani electricity", "Bills & Utilities"),
        ("adani power", "Bills & Utilities"),
        ("torrent power", "Bills & Utilities"),
        ("kseb", "Bills & Utilities"), ("kpdcl", "Bills & Utilities"),
        ("tsspdcl", "Bills & Utilities"), ("pspcl", "Bills & Utilities"),
        ("uppcl", "Bills & Utilities"), ("bses", "Bills & Utilities"),
        ("ndmc", "Bills & Utilities"),

        // ── BILLS: Water ─────────────────────────────────────────────
        ("water bill", "Bills & Utilities"), ("bwssb", "Bills & Utilities"),
        ("hmwssb", "Bills & Utilities"), ("djb", "Bills & Utilities"),

        // ── BILLS: Gas ───────────────────────────────────────────────
        ("gas bill", "Bills & Utilities"), ("gas cylinder", "Bills & Utilities"),
        ("indane", "Bills & Utilities"), ("bharat gas", "Bills & Utilities"),
        ("bharatgas", "Bills & Utilities"), ("hp gas", "Bills & Utilities"),
        ("hpgas", "Bills & Utilities"),

        // ── BILLS: App stores / cloud ────────────────────────────────
        ("app store", "Bills & Utilities"), ("appstore", "Bills & Utilities"),
        ("google play", "Bills & Utilities"), ("playstore", "Bills & Utilities"),
        ("icloud", "Bills & Utilities"), ("apple one", "Bills & Utilities"),
        ("google one", "Bills & Utilities"), ("dropbox", "Bills & Utilities"),
        ("onedrive", "Bills & Utilities"), ("google drive", "Bills & Utilities"),

        // ── BILLS: Software subscriptions ────────────────────────────
        ("zoom", "Bills & Utilities"), ("microsoft 365", "Bills & Utilities"),
        ("office 365", "Bills & Utilities"),
        ("google workspace", "Bills & Utilities"),
        ("slack", "Bills & Utilities"), ("notion", "Bills & Utilities"),
        ("figma", "Bills & Utilities"), ("adobe", "Bills & Utilities"),
        ("creative cloud", "Bills & Utilities"),
        ("github", "Bills & Utilities"), ("gitlab", "Bills & Utilities"),
        ("chatgpt", "Bills & Utilities"), ("openai", "Bills & Utilities"),
        ("claude", "Bills & Utilities"), ("anthropic", "Bills & Utilities"),
        ("perplexity", "Bills & Utilities"), ("canva", "Bills & Utilities"),
        ("grammarly", "Bills & Utilities"), ("1password", "Bills & Utilities"),
        ("nordvpn", "Bills & Utilities"), ("expressvpn", "Bills & Utilities"),
        ("vpn", "Bills & Utilities"),

        // ── RENT ─────────────────────────────────────────────────────
        ("rent", "Rent"), ("maintenance", "Rent"), ("society", "Rent"),
        ("nobroker", "Rent"), ("no broker", "Rent"),
        ("housing.com", "Rent"), ("magicbricks", "Rent"), ("99acres", "Rent"),
        ("nestaway", "Rent"), ("zolo", "Rent"), ("stanza living", "Rent"),
        ("colive", "Rent"), ("oyo life", "Rent"),

        // ── HEALTH: Pharmacies ───────────────────────────────────────
        ("apollo pharmacy", "Health"), ("1mg", "Health"),
        ("tata 1mg", "Health"), ("pharmeasy", "Health"),
        ("pharm easy", "Health"), ("netmeds", "Health"),
        ("medplus", "Health"), ("med plus", "Health"),
        ("wellness forever", "Health"), ("generic aadhaar", "Health"),
        ("frank ross", "Health"), ("guardian pharmacy", "Health"),

        // ── HEALTH: Hospitals ────────────────────────────────────────
        ("apollo hospital", "Health"), ("fortis", "Health"),
        ("manipal hospital", "Health"), ("max hospital", "Health"),
        ("narayana", "Health"), ("columbia asia", "Health"),
        ("medanta", "Health"), ("aiims", "Health"), ("kims", "Health"),
        ("rainbow hospital", "Health"),

        // ── HEALTH: Diagnostic / consultation ────────────────────────
        ("practo", "Health"), ("doctor", "Health"), ("dr.", "Health"),
        ("consultation", "Health"), ("lab test", "Health"),
        ("diagnostic", "Health"), ("diagnostics", "Health"),
        ("blood test", "Health"), ("x-ray", "Health"), ("xray", "Health"),
        ("mri", "Health"), ("ct scan", "Health"), ("ecg", "Health"),
        ("dental", "Health"), ("dentist", "Health"),
        ("orthopedic", "Health"), ("ortho", "Health"),
        ("dr lal pathlabs", "Health"), ("lal pathlabs", "Health"),
        ("metropolis", "Health"), ("thyrocare", "Health"),

        // ── HEALTH: Fitness ──────────────────────────────────────────
        ("cult.fit", "Health"), ("cure.fit", "Health"),
        ("cult fit", "Health"), ("cure fit", "Health"), ("cult", "Health"),
        ("curefit", "Health"), ("gym", "Health"), ("fitness", "Health"),
        ("gold's gym", "Health"), ("golds gym", "Health"),
        ("snap fitness", "Health"), ("anytime fitness", "Health"),
        ("fitternity", "Health"), ("zumba", "Health"), ("yoga", "Health"),
        ("crossfit", "Health"), ("pilates", "Health"),

        // ── HEALTH: Mental health / wellness ─────────────────────────
        ("betterhelp", "Health"), ("better help", "Health"),
        ("headspace", "Health"), ("wysa", "Health"),
        ("mindhouse", "Health"), ("therapy", "Health"),
        ("therapist", "Health"), ("counselling", "Health"),
        ("counseling", "Health"),

        // ── HEALTH: Insurance ────────────────────────────────────────
        ("lic", "Health"), ("icici lombard", "Health"),
        ("hdfc ergo", "Health"), ("hdfc life", "Health"),
        ("star health", "Health"), ("max bupa", "Health"),
        ("niva bupa", "Health"), ("religare", "Health"),
        ("acko", "Health"), ("digit insurance", "Health"),
        ("policybazaar", "Health"), ("policy bazaar", "Health"),
        ("insurance", "Health"), ("mediclaim", "Health"),

        // ── HEALTH: Generic ──────────────────────────────────────────
        ("medicine", "Health"), ("tablets", "Health"),
        ("medical", "Health"), ("clinic", "Health"),
        ("hospital", "Health"), ("checkup", "Health"),
        ("check-up", "Health"), ("pharmacy", "Health"),

        // ── EDUCATION ────────────────────────────────────────────────
        ("byjus", "Education"), ("byju's", "Education"),
        ("unacademy", "Education"), ("vedantu", "Education"),
        ("upgrad", "Education"), ("simplilearn", "Education"),
        ("great learning", "Education"), ("scaler", "Education"),
        ("masai", "Education"), ("internshala", "Education"),
        ("coursera", "Education"), ("udemy", "Education"),
        ("edx", "Education"), ("khan academy", "Education"),
        ("khanacademy", "Education"), ("codecademy", "Education"),
        ("datacamp", "Education"), ("pluralsight", "Education"),
        ("linkedin learning", "Education"), ("skillshare", "Education"),
        ("masterclass", "Education"), ("duolingo", "Education"),
        ("babbel", "Education"), ("busuu", "Education"),
        ("school fees", "Education"), ("tuition", "Education"),
        ("coaching", "Education"), ("classes", "Education"),
        ("course", "Education"), ("kota", "Education"),
        ("allen institute", "Education"), ("aakash", "Education"),
        ("fiitjee", "Education"), ("resonance", "Education"),
        ("physicswallah", "Education"), ("physics wallah", "Education"),
        ("textbook", "Education"), ("textbooks", "Education"),
        ("stationery", "Education"),

        // ── TRAVEL ───────────────────────────────────────────────────
        ("makemytrip", "Travel"), ("make my trip", "Travel"),
        ("mmt", "Travel"), ("goibibo", "Travel"), ("ixigo", "Travel"),
        ("easemytrip", "Travel"), ("ease my trip", "Travel"),
        ("cleartrip", "Travel"), ("clear trip", "Travel"),
        ("yatra", "Travel"), ("thomas cook", "Travel"), ("sotc", "Travel"),
        ("cox & kings", "Travel"), ("cox and kings", "Travel"),
        ("kesari", "Travel"), ("oyo", "Travel"), ("airbnb", "Travel"),
        ("booking.com", "Travel"), ("agoda", "Travel"),
        ("expedia", "Travel"), ("trivago", "Travel"), ("treebo", "Travel"),
        ("fabhotels", "Travel"), ("fab hotels", "Travel"),
        ("zostel", "Travel"), ("hostelworld", "Travel"),
        ("trip.com", "Travel"), ("klook", "Travel"), ("viator", "Travel"),
        ("getyourguide", "Travel"), ("hotel", "Travel"),
        ("resort", "Travel"), ("homestay", "Travel"), ("villa", "Travel"),
        ("trip", "Travel"), ("vacation", "Travel"), ("holiday", "Travel"),
        ("tour", "Travel"), ("visa", "Travel"), ("passport", "Travel"),
        ("immigration", "Travel"),

        // ── PERSONAL CARE ────────────────────────────────────────────
        ("salon", "Personal Care"), ("parlor", "Personal Care"),
        ("parlour", "Personal Care"), ("haircut", "Personal Care"),
        ("hair cut", "Personal Care"), ("urbanclap", "Personal Care"),
        ("urban company", "Personal Care"), ("urban clap", "Personal Care"),
        ("naturals salon", "Personal Care"), ("jawed habib", "Personal Care"),
        ("lakme salon", "Personal Care"), ("looks salon", "Personal Care"),
        ("vlcc", "Personal Care"), ("habibs", "Personal Care"),
        ("toni & guy", "Personal Care"), ("toni and guy", "Personal Care"),
        ("spa", "Personal Care"), ("massage", "Personal Care"),
        ("ayurveda", "Personal Care"), ("manicure", "Personal Care"),
        ("pedicure", "Personal Care"), ("facial", "Personal Care"),
        ("waxing", "Personal Care"),

        // ── OTHER: Coworking ─────────────────────────────────────────
        ("wework", "Other"), ("awfis", "Other"), ("91springboard", "Other"),
        ("coworking", "Other"),

        // ── OTHER: Donations / religion ──────────────────────────────
        ("donation", "Other"), ("donate", "Other"), ("charity", "Other"),
        ("temple", "Other"), ("mosque", "Other"), ("church", "Other"),
        ("gurudwara", "Other"), ("red cross", "Other"),
        ("give india", "Other"), ("giveindia", "Other"),
        ("akshay patra", "Other"),

        // ── OTHER: Gifts ─────────────────────────────────────────────
        ("gift", "Other"), ("present", "Other"),

        // ── OTHER: Pets ──────────────────────────────────────────────
        ("pet ", "Other"), ("vet ", "Other"), ("veterinary", "Other"),
        ("pet food", "Other"), ("pedigree", "Other"),
        ("royal canin", "Other"), ("whiskas", "Other"),
        ("heads up for tails", "Other"), ("supertails", "Other"),

        // ── OTHER: Alcohol ───────────────────────────────────────────
        ("beer", "Other"), ("wine", "Other"), ("vodka", "Other"),
        ("whisky", "Other"), ("whiskey", "Other"), ("rum", "Other"),
        ("scotch", "Other"), ("alcohol", "Other"), ("liquor", "Other"),
        ("kingfisher", "Other"), ("budweiser", "Other"),
        ("heineken", "Other"), ("corona", "Other"),
        ("blenders pride", "Other"), ("magic moments", "Other"),
        ("bira", "Other"), ("simba", "Other"), ("mcdowell", "Other"),
        ("imperial blue", "Other"),

        // ── OTHER: ATM / cash ────────────────────────────────────────
        ("atm", "Other"), ("atm withdrawal", "Other"),
        ("cash withdrawal", "Other"),
    ]
}
