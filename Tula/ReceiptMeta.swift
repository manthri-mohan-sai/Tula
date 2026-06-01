import Foundation

/// Centralized metadata used by the receipt-parsing pipeline.
///
/// **Why this file exists**: keyword sets used by classifiers and
/// extractors were originally inline in `ReceiptStorage.swift`, but
/// (a) they were undersized — only the keywords I happened to think
/// of when writing each function — and (b) tuning them required
/// hunting through 1500+ lines of mixed parser code. Centralizing
/// them here lets us grow the coverage aggressively and tune in one
/// place.
///
/// **Scope**: all matching is case-insensitive substring (`lowered.contains(keyword)`),
/// so entries should be lowercase. Multi-word phrases are fine. Keep
/// each entry short and unambiguous; "subscription" matches Netflix
/// and Adobe, so don't put generic words in narrow categories.
///
/// **Coverage philosophy**: optimized for Indian receipts — Hindi/Tamil/
/// Telugu/Kannada text on receipts usually gets OCR'd in Latin script
/// (the raw bytes are Devanagari/Tamil etc but printers and POS systems
/// almost always use English labels for amounts and structural metadata),
/// so this file is English-centric. Regional script support would
/// require a different OCR engine entirely.
enum ReceiptMeta {

    // MARK: - Document Classification Keywords
    //
    // Each Set below is scored against the OCR text in
    // `classifyDocument(from:)`. The set with the most hits ≥ threshold
    // wins. Keep entries distinctive — overlapping phrases (e.g.
    // "amount" in multiple sets) muddies scoring. Specific terms like
    // "kot no" (kitchen order ticket — only printed by restaurant POS
    // systems) are far more useful than generic "bill".

    /// UPI confirmation screenshots — PhonePe, Google Pay, Paytm,
    /// BHIM, every bank's UPI app, CRED, Slice, etc. These screens
    /// have a very consistent template: prominent amount, status
    /// banner, "Paid to" line, transaction ID.
    static let upiKeywords: Set<String> = [
        // Core UPI vocabulary
        "upi ref", "upi transaction", "upi id", "upi:", "upi payment",
        "transaction id", "transaction successful", "txn id", "txn no",
        "transaction details", "transaction reference",
        // Payment status
        "paid to", "transferred to", "received from", "money sent",
        "money received", "successful", "payment successful",
        "transfer successful", "completed", "successfully paid",
        // Account/handle markers
        "vpa", "@upi", "@paytm", "@ybl", "@okaxis", "@oksbi", "@okhdfcbank",
        "@okicici", "@apl", "@ibl", "@axl", "@hdfcbank",
        // App branding (helpful classifier signal even though we don't
        // want to use these as merchant names)
        "phonepe", "google pay", "g pay", "paytm", "bhim", "amazon pay",
        "cred", "slice", "freecharge", "mobikwik",
        // Receipt formatting specific to UPI
        "utr", "rrn", "ref no:", "ref no.", "reference number"
    ]

    /// Food / grocery delivery order summaries — Swiggy, Zomato,
    /// Blinkit, Zepto, Instamart, BigBasket, Dunzo, Magicpin. Order
    /// summaries are structured similarly across apps: brand header,
    /// items list, total at bottom, delivery fee + GST line items.
    static let orderSummaryKeywords: Set<String> = [
        "order summary", "order details", "order id", "order #",
        "bill summary", "bill details", "your order",
        // Delivery-specific
        "delivery partner", "delivery fee", "delivery charge",
        "delivery address", "delivery instructions", "delivery time",
        "out for delivery", "order delivered",
        // Restaurant/store reference (used by delivery apps)
        "restaurant", "store", "outlet", "kitchen",
        // Pricing structure unique to delivery
        "item total", "subtotal", "platform fee", "handling fee",
        "convenience fee", "packing charges", "restaurant charges",
        // Promo / loyalty
        "promo applied", "coupon applied", "swiggy one", "zomato gold",
        "instamart", "blinkit", "zepto", "bigbasket",
        // Payment summary
        "to pay", "amount payable", "total paid", "bill total"
    ]

    /// Printed restaurant / kirana / cafe bills. Format: merchant +
    /// bill number at top, table info, items with prices in columns,
    /// taxes at bottom, grand total. Lots of POS-system vocabulary.
    static let restaurantKeywords: Set<String> = [
        // Bill identifiers (printed at top by POS systems)
        "bill no", "bill no.", "bill number", "bill date", "bill time",
        "kot no", "kot:", "kot ", "kitchen order", "kot/bot",
        "cash bill", "tax invoice", "duplicate copy",
        // Service info
        "table no", "table :", "table number", "table-",
        "floor :", "floor-", "captain", "steward", "waiter",
        "cover", "covers", "no. of pax", "no of pax", "pax:",
        // Tax structure (very common on Indian restaurant bills)
        "cgst", "sgst", "igst", "gst no", "gstin",
        "service charge", "service tax", "service chrg",
        // Common Indian restaurant menu words
        "starters", "main course", "desserts", "beverages",
        "south indian", "north indian", "chinese", "tandoor",
        // POS branding (helpful classifier signal)
        "powered by", "petpooja", "posist", "limetray", "torqus"
    ]

    /// Hospital / clinic / diagnostics / pharmacy bills. Very rich
    /// vocabulary — medical terminology, specialties, charge types.
    /// Often the bills have complex multi-section layouts with patient
    /// info at top and a "Net Payable" at the bottom.
    static let hospitalKeywords: Set<String> = [
        // Patient identifiers
        "patient name", "patient id", "patient no", "patient :",
        "mrd no", "mrd number", "mrn", "uhid", "uhid:", "uhid -",
        "ip number", "ip no", "ip no:", "op number", "op no",
        // Admission / discharge
        "admission date", "admission time", "admission no",
        "discharge date", "discharge time", "discharge summary",
        "doa", "dod", "ward name", "ward no", "ward :",
        "bed no", "bed:", "bed number", "room no",
        // Clinical structure
        "doctor name", "doctor :", "consultant", "consulting doctor",
        "ref. doctor", "referring doctor", "speciality", "specialty",
        "diagnosis", "complaint", "history", "treatment",
        // Specialty names (very distinctive signals)
        "urology", "cardiology", "neurology", "oncology", "orthopedic",
        "orthopaedic", "pediatric", "paediatric", "gynaecology",
        "gynecology", "radiology", "pathology", "dermatology",
        "ophthalmology", "psychiatry", "general medicine",
        "obstetric", "endocrinology", "nephrology", "hematology",
        // Charge categories
        "consultation", "consultation fee", "consultancy",
        "procedure", "invasive procedure", "surgery", "operation",
        "ot consumable", "ot pharmacy", "ot charges", "ot fee",
        "drug administration", "iv administration", "injection charges",
        "room charges", "room rent", "icu charges", "hdu charges",
        "nursing charges", "nursing care",
        "package charges", "package amount",
        "lab test", "laboratory", "investigation", "investigations",
        "diagnostic", "scan", "x-ray", "mri", "ct scan", "ultrasound",
        "blood test", "urine test",
        "pharmacy", "medicines", "drugs",
        // Bill total labels specific to hospitals
        "net payable", "net amount payable", "amount payable",
        "final amount", "balance due", "advance paid", "advance amount",
        "deposit paid", "refund amount", "to be refund",
        // Hospital brand names (chains common in India)
        "apollo", "fortis", "max healthcare", "manipal", "narayana",
        "kims", "asian institute", "rainbow children", "cloudnine",
        "yashoda", "amri", "wockhardt",
        // Form indicators
        "interim bill", "final bill", "bill of supply",
        "gaurdian name", "guardian name", "billing account"
    ]

    /// Utility bills — electricity, water, gas, telco, broadband,
    /// DTH. State electricity boards have distinct vocabularies that
    /// help classify which utility this is.
    static let utilityKeywords: Set<String> = [
        // Universal utility-bill markers
        "consumer no", "consumer number", "consumer name", "consumer id",
        "account no", "account number", "service no", "service number",
        "billing period", "billing month", "billing cycle",
        "due date", "bill due", "pay by",
        "previous reading", "current reading", "meter reading",
        "previous balance", "current bill", "current charges",
        "amount due", "total payable", "amount payable", "net amount",
        // Electricity
        "electricity", "kwh", "units consumed", "consumption",
        "meter no", "meter number", "tariff", "energy charges",
        "fuel adjustment", "electricity duty", "wheeling charges",
        // State electricity boards (India)
        "bses", "tata power", "torrent power", "msedcl", "kseb",
        "tsspdcl", "apspdcl", "wbsedcl", "punjab state power",
        "uppcl", "noida power", "ndmc",
        // Water boards
        "water board", "water bill", "water charges", "sewerage",
        "djb", "delhi jal", "bwssb", "hmwssb", "mwssb",
        // Gas
        "gas connection", "lpg", "piped gas", "png",
        "indraprastha gas", "mahanagar gas", "adani gas",
        // Telecom / broadband / mobile
        "broadband", "fiber", "internet plan", "data plan",
        "mobile recharge", "prepaid", "postpaid",
        "airtel", "jio", "vi ", "vodafone idea", "bsnl", "mtnl",
        // DTH / cable
        "dth", "tata sky", "tata play", "dish tv", "videocon d2h",
        "sun direct", "airtel digital",
        // Subscription specific to utility-like services
        "monthly plan", "quarterly plan", "annual plan"
    ]

    // MARK: - Amount / Total Label Keywords

    /// Unambiguous final-total markers — when these appear in a line,
    /// the value on (or near) that line IS the bill's grand total.
    /// These are SAFE for the amount extractor's Phase 1: trust
    /// without further checking.
    static let finalTotalKeywords = [
        // Standard "total" markers
        "grand total", "gr total", "grand tot", "g.total",
        "net amount", "net total", "net payable", "net amt",
        "net amount payable", "net bill amount",
        "bill amount", "billed amount", "total bill",
        "amount payable", "amt payable", "payable amount",
        "to pay", "to be paid", "total payable",
        "final amount", "final total", "final payable",
        "round off total", "rounded off",
        "amount due", "total due", "balance due", "balance payable",
        "you pay", "you paid", "amount paid", "total paid",
        "invoice total", "invoice amount",
        // Indian English variations
        "amount to pay", "kindly pay", "total amount due",
        "outstanding amount", "current bill amount",
        // Retail/supermarket variations
        "amount receivable", "amount recvbl",
        "total payable amount",
        "total invoice value", "invoice value",
        "total amount",
        // Restaurant POS variations
        "bill amt", "round total",
        // UPI screen amounts (the prominent labeled amount)
        "amount sent", "transaction amount"
    ]

    /// Ambiguous total markers — "total" without qualifier could be a
    /// sub-total or item total. Phase 2 of the amount extractor
    /// gathers all matches and cross-validates against the items sum
    /// before picking.
    static let ambiguousTotalKeywords = [
        "total", "sub total", "subtotal", "sub-total",
        "item total", "items total", "amount", "amt"
    ]

    /// Hospital-specific final-total labels. Stronger signals when
    /// the document has already been classified as a hospital bill.
    static let hospitalTotalKeywords = [
        "net payable", "amount payable", "final amount",
        "net amount payable", "total payable", "amount due",
        "balance due", "balance payable", "balance amount",
        "total amount payable", "net bill amount", "final payable"
    ]

    /// Utility bill total labels.
    static let utilityTotalKeywords = [
        "amount due", "total payable", "amount payable",
        "total amount due", "bill amount", "amount to pay",
        "net amount", "current bill amount", "current month amount",
        "total bill amount", "payable amount"
    ]

    /// Order-summary total labels — delivery apps use specific phrasing.
    static let orderTotalKeywords = [
        "bill total", "total paid", "amount paid",
        "order total", "grand total", "total amount",
        "to pay", "you paid", "paid amount"
    ]

    // MARK: - Payment Method Keywords
    //
    // Lines containing these are "how you paid" lines (Cash 500.00,
    // UPI 320.00, Card 1290.00). They're NOT the bill total. Filter
    // them out before amount extraction so they don't get picked up.

    static let paymentMethodKeywords: Set<String> = [
        "cash", "card", "credit", "debit", "swipe",
        "upi", "phonepe", "gpay", "google pay", "paytm", "bhim",
        "amazon pay", "cred", "slice", "freecharge", "mobikwik",
        "wallet", "net banking", "netbanking",
        "tendered", "change", "balance returned", "change due",
        "cheque", "bank transfer", "neft", "imps", "rtgs",
        "razorpay", "stripe", "payu",
        // Indian colloquial
        "received", "advance"
    ]

    // MARK: - Metadata / Noise Line Filter
    //
    // Lines that contain these phrases are NEVER line items — they're
    // document metadata. Page markers, patient info, bill identifiers,
    // addresses, disclaimers. Without this filter, item extractors
    // pull them in as fake items.

    static let metadataLineKeywords: Set<String> = [
        // Page / pagination
        "page ", "page-", "page:", "page no",
        // Patient / hospital metadata
        "patient name", "patient id", "patient no", "uhid",
        "ip number", "ip no", "op number",
        "mrd no", "mrd number", "mrn",
        "ward name", "ward no", "ward :",
        "bed no", "bed:", "bed number", "room no",
        "doctor name", "doctor:", "consulting doctor",
        "speciality", "specialty",
        "gaurdian", "guardian", "guardian name",
        "admission date", "admission time", "admission no",
        "discharge date", "discharge time",
        "billing account", "billing period",
        // Bill identifiers
        "bill no", "bill no:", "bill number", "bill date",
        "invoice no", "invoice number", "invoice date",
        "gstin", "gstn", "gst no", "pan no", "pan:",
        "from date", "to date", "todate", "date:",
        "ref no", "reference no", "ref :",
        // Order metadata (delivery apps)
        "order id", "order #", "order no",
        "delivery address", "delivery time", "delivery partner",
        "estimated delivery", "order placed",
        // Page markers in various forms
        " of ",   // catches "1 of 4", "Page 1 of 4"
        // Common header rows
        "sl no", "sl.no", "s.no", "s no", "sno", "sr no", "sr.no",
        "qty", "unit price", "rate", "discount",  // column headers
        // Form markers
        "bill of supply", "tax invoice", "interim bill", "final bill",
        "draft not final", "duplicate copy", "original for",
        // Address / contact (often has digits)
        "cell no", "mobile no", "phone no", "tel:", "telephone",
        "address", "email:", "website:",
        // Disclaimer / footers
        "disclaimer", "generated by", "cashier", "manager",
        "this interim", "this bill", "thank you", "visit again",
        "terms and conditions", "terms & conditions",
        // Payment metadata (passes total-marker filter but bill metadata)
        "deposit ", "outstanding amount", "to be refund",
        "amount paid", "payment details", "payment mode",
        // Address indicators — Indian receipts print the store address
        // at the top with building number, street, locality, district.
        // Without these markers, item-extractors pick up the building
        // number as a "price" and the locality name as the "item name".
        // Real failure: "ANRI PRIME #384 CHANDANAGAR VILLAGE" was
        // extracted as item "Anri Prime # Chandanagar Village ₹384".
        "village", "mandal", " dist ", "district", "taluk", "tehsil",
        "nagar", "colony", "phase", "block", "sector",
        " road", " street", " lane", " avenue", "marg", "circle",
        "floor", "ground floor", "first floor", "second floor",
        "apartment", "building", "complex", "plaza",
        "near", "opposite", "behind", "next to",
        "pincode", "pin code", "pin:", "pin -",
        // Corporate identifiers — every Indian business receipt has these
        // and they have alphanumeric patterns that confuse extractors.
        "cin:", "cin ", "cin-", "u51399", "u52", "u74",  // CIN prefix forms
        "fssai", "fssa1",  // food license, OCR may misread
        // Common header structure
        "tax invoice", "retail invoice",
        // Phone-number-line indicators (when prefixed with "ph" or similar)
        "ph:", "ph.", "phone:", "mobile:",
        // Store branding boilerplate (Ratnadeep, DMart specific patterns)
        "for queries", "whatsapp", "customer care", "helpline",
        "printed on",
        // Receipt totals / summary section — these appear AFTER the
        // item list and have small numbers that pass our filters
        // unless explicitly excluded. Common failures: "Disc 13.40"
        // and "Ref. No. / TXN ID :254" getting parsed as items.
        "disc:", "disc ", "disc.", "discount",
        "savings", "savings on", "savings %", "promo discount", "promo:",
        "gross sale", "gross value", "gross amount",
        "net payable", "net value", "net_value",
        "items:", "items :", "qty:", "qty :", "items 6",
        "received amount", "received amt", "balance pad", "balance paid",
        "balance pa d",   // Common OCR slip from "Balance Paid"
        "ref. no", "ref no.", "ref no /", "ref. no /", "ref. no.",
        "txn id", "txn:", "txn no", "trans id", "transaction id",
        "edc", "paytm edc",  // payment device labels
        // Tax summary rows — these rows have multiple small amounts
        // (CGST, SGST, CESS, NET_VALUE) on one line that confuse the
        // item extractor.
        "tax summary", "tax. summary", "tax amt", "taxamt",
        "sgst", "cgst", "igst", "cess", "net value",
        "***",  // section dividers like "*** Schemes ***"
        "scheme", "schemes",
        // Loyalty/coupon footer
        "loyalty", "points earned", "points redeemed",
        // Indian receipt closing lines
        "barcode", "qr code"
    ]

    // MARK: - Brand Recognition

    /// Delivery / aggregator brands. These names appear at the top of
    /// delivery order summaries as the APP name, not the merchant.
    /// When extracting the merchant from a delivery bill, we skip
    /// these so we get "Ramachandra Restaurant" rather than "Swiggy".
    static let deliveryBrands: Set<String> = [
        "swiggy", "zomato", "blinkit", "zepto", "instamart",
        "bigbasket", "dunzo", "magicpin", "rapido",
        "uber eats", "foodpanda",
        "amazon fresh", "amazon pantry", "jiomart",
        "ondc", "ekart"
    ]

    /// Payment app / wallet brands. Similar logic — these are the
    /// channel, not the merchant. When extracting from UPI screens
    /// we want the "Paid to" value, not the app's own brand name.
    static let paymentAppBrands: Set<String> = [
        "phonepe", "google pay", "g pay", "gpay", "paytm",
        "bhim", "amazon pay", "cred", "slice", "freecharge",
        "mobikwik", "ola money", "airtel money",
        // Bank app brands (UPI-enabled banking apps)
        "yono sbi", "hdfc bank", "icici imobile", "axis bank",
        "kotak 811", "ibl pay", "iob mobile"
    ]

    // MARK: - OCR Substitution Rules

    /// Common OCR character confusions in numeric contexts. Applied
    /// in `applyOCRDigitRecovery` when a keyword matched but no number
    /// was found on adjacent lines — we assume the OCR garbled the
    /// digits. Substitutions are uppercase→digit by default.
    static let ocrDigitSubstitutions: [Character: Character] = [
        "I": "1", "l": "1", "|": "1",
        "O": "0", "o": "0",
        "S": "5",
        "B": "8",
        "Z": "2",
        "T": "7",   // rare but seen on faded thermal print
        "G": "6"
    ]

    // MARK: - Currency Patterns

    /// Currency-marker prefixes. Used by `currencyValue(in:)` to
    /// identify lines that contain prices vs lines that just contain
    /// numbers (like reference IDs or phone numbers).
    static let currencyMarkers: [String] = [
        "₹", "Rs.", "Rs", "INR", "rs", "rupees", "rupee"
    ]

    // MARK: - Merchant → Category Hints (for FM fallback)
    //
    // When the FM can't decide a category, these brand→category hints
    // ground the decision. Loose substring match: if the merchant
    // contains the key, the value is a strong category hint. Used by
    // SmartExpenseParser.parseReceipt only as a hint to FM — the FM
    // can still override based on items.

    /// Brand → category-hint pairs. Lowercase keys, English category
    /// hints. The FM prompt receives these as supporting context
    /// when the merchant name is recognizable.
    ///
    /// **Coverage philosophy**: heavily Indian-market focused — major
    /// retail chains, food brands, services, and online platforms
    /// commonly seen on Indian receipts. Adding new merchants here is
    /// cheap and improves auto-categorization accuracy. When the
    /// merchant on a receipt matches any key (case-insensitive
    /// substring), the FM gets the category hint baked into the prompt.
    static let knownMerchantCategories: [String: String] = [
        // ---------------- Food & Drinks ----------------
        // Fast food / quick-service restaurants
        "mcdonalds": "Food & Drinks",
        "mcdonald": "Food & Drinks",
        "kfc": "Food & Drinks",
        "subway": "Food & Drinks",
        "dominos": "Food & Drinks",
        "domino's": "Food & Drinks",
        "pizza hut": "Food & Drinks",
        "burger king": "Food & Drinks",
        "taco bell": "Food & Drinks",
        // Cafes & coffee
        "starbucks": "Food & Drinks",
        "cafe coffee day": "Food & Drinks",
        "ccd": "Food & Drinks",
        "barista": "Food & Drinks",
        "chai point": "Food & Drinks",
        "chaayos": "Food & Drinks",
        "third wave coffee": "Food & Drinks",
        "blue tokai": "Food & Drinks",
        // Indian QSR / casual dining
        "haldiram": "Food & Drinks",
        "bikanervala": "Food & Drinks",
        "barbeque nation": "Food & Drinks",
        "absolute barbecue": "Food & Drinks",
        "punjab grill": "Food & Drinks",
        "saravana bhavan": "Food & Drinks",
        "sangeetha": "Food & Drinks",
        "anjappar": "Food & Drinks",
        "paradise biryani": "Food & Drinks",
        "bawarchi": "Food & Drinks",
        "behrouz biryani": "Food & Drinks",
        "biryani by kilo": "Food & Drinks",
        "wow! momo": "Food & Drinks",
        "wow momo": "Food & Drinks",
        "social": "Food & Drinks",
        "soda bottle openerwala": "Food & Drinks",
        // Delivery (the channel may be the merchant on receipts)
        "swiggy": "Food & Drinks",
        "zomato": "Food & Drinks",
        "eatfit": "Food & Drinks",
        "freshmenu": "Food & Drinks",
        "faasos": "Food & Drinks",
        "behrouz": "Food & Drinks",
        "rebel foods": "Food & Drinks",

        // ---------------- Groceries ----------------
        // Supermarket chains
        "dmart": "Groceries",
        "d-mart": "Groceries",
        "d mart": "Groceries",
        "more supermarket": "Groceries",
        "more retail": "Groceries",
        "reliance fresh": "Groceries",
        "reliance smart": "Groceries",
        "spencer": "Groceries",
        "spencers": "Groceries",
        "big bazaar": "Groceries",
        "easyday": "Groceries",
        "nature's basket": "Groceries",
        "natures basket": "Groceries",
        "star bazaar": "Groceries",
        "hypercity": "Groceries",
        "vishal mega mart": "Groceries",
        "ratnadeep": "Groceries",
        "heritage fresh": "Groceries",
        "q-mart": "Groceries",
        "qmart": "Groceries",
        // Quick-commerce
        "blinkit": "Groceries",
        "zepto": "Groceries",
        "instamart": "Groceries",
        "bigbasket": "Groceries",
        "big basket": "Groceries",
        "country delight": "Groceries",
        "milkbasket": "Groceries",
        "supr daily": "Groceries",
        "licious": "Groceries",
        "fresh to home": "Groceries",
        "freshtohome": "Groceries",
        "amazon fresh": "Groceries",
        "amazon pantry": "Groceries",
        "jiomart": "Groceries",
        "jio mart": "Groceries",
        "dunzo": "Groceries",

        // ---------------- Transport ----------------
        // Ride-hailing
        "uber": "Transport",
        "ola": "Transport",
        "ola cabs": "Transport",
        "rapido": "Transport",
        "blusmart": "Transport",
        "blu smart": "Transport",
        "meru": "Transport",
        "savaari": "Transport",
        // Petrol / fuel
        "indian oil": "Transport",
        "indianoil": "Transport",
        "ioc": "Transport",
        "iocl": "Transport",
        "bharat petroleum": "Transport",
        "bpcl": "Transport",
        "hindustan petroleum": "Transport",
        "hpcl": "Transport",
        "shell": "Transport",
        "reliance petroleum": "Transport",
        "nayara": "Transport",
        "essar": "Transport",
        // Trains / buses / flights
        "irctc": "Transport",
        "indian railways": "Transport",
        "redbus": "Transport",
        "abhibus": "Transport",
        "ksrtc": "Transport",
        "tsrtc": "Transport",
        "apsrtc": "Transport",
        "msrtc": "Transport",
        "indigo": "Transport",
        "vistara": "Transport",
        "air india": "Transport",
        "spicejet": "Transport",
        "akasa air": "Transport",
        "goair": "Transport",
        "go first": "Transport",
        "makemytrip": "Transport",
        "mmt": "Transport",
        "yatra": "Transport",
        "cleartrip": "Transport",
        "goibibo": "Transport",
        "easemytrip": "Transport",
        "ixigo": "Transport",
        // Parking / tolls
        "fastag": "Transport",
        "paytm fastag": "Transport",
        "park+": "Transport",
        "parkplus": "Transport",
        // Metros / public transport
        "delhi metro": "Transport",
        "namma metro": "Transport",
        "hyderabad metro": "Transport",
        "kochi metro": "Transport",
        "chennai metro": "Transport",
        "mumbai metro": "Transport",

        // ---------------- Health ----------------
        // Pharmacies
        "apollo pharmacy": "Health",
        "apollopharmacy": "Health",
        "1mg": "Health",
        "tata 1mg": "Health",
        "pharmeasy": "Health",
        "netmeds": "Health",
        "medplus": "Health",
        "med plus": "Health",
        "wellness forever": "Health",
        "guardian pharmacy": "Health",
        "frank ross": "Health",
        // Hospitals (major chains)
        "apollo hospital": "Health",
        "apollo hospitals": "Health",
        "fortis": "Health",
        "fortis hospital": "Health",
        "max hospital": "Health",
        "max healthcare": "Health",
        "manipal hospital": "Health",
        "manipal hospitals": "Health",
        "narayana": "Health",
        "narayana health": "Health",
        "kims hospital": "Health",
        "kims": "Health",
        "asian institute": "Health",
        "rainbow children": "Health",
        "rainbow hospital": "Health",
        "cloudnine": "Health",
        "cloud nine": "Health",
        "yashoda": "Health",
        "yashoda hospital": "Health",
        "amri": "Health",
        "wockhardt": "Health",
        "medanta": "Health",
        "lilavati": "Health",
        "hinduja hospital": "Health",
        "kokilaben": "Health",
        "sankara nethralaya": "Health",
        "aravind eye": "Health",
        // Diagnostics
        "thyrocare": "Health",
        "dr lal pathlabs": "Health",
        "lal pathlabs": "Health",
        "metropolis": "Health",
        "srl diagnostics": "Health",
        "vijaya diagnostic": "Health",
        // Health & wellness apps
        "cult.fit": "Health",
        "cultfit": "Health",
        "cure.fit": "Health",
        "healthifyme": "Health",
        "practo": "Health",
        "tata health": "Health",
        "mfine": "Health",

        // ---------------- Shopping ----------------
        // E-commerce
        "amazon": "Shopping",
        "amazon.in": "Shopping",
        "flipkart": "Shopping",
        "myntra": "Shopping",
        "ajio": "Shopping",
        "nykaa": "Shopping",
        "nykaa fashion": "Shopping",
        "meesho": "Shopping",
        "snapdeal": "Shopping",
        "shopclues": "Shopping",
        "tata cliq": "Shopping",
        "tatacliq": "Shopping",
        "limeroad": "Shopping",
        // Apparel & lifestyle
        "decathlon": "Shopping",
        "lifestyle": "Shopping",
        "shoppers stop": "Shopping",
        "westside": "Shopping",
        "max fashion": "Shopping",
        "pantaloons": "Shopping",
        "fbb": "Shopping",
        "central mall": "Shopping",
        "reliance trends": "Shopping",
        "h&m": "Shopping",
        "zara": "Shopping",
        "uniqlo": "Shopping",
        "fabindia": "Shopping",
        "biba": "Shopping",
        "global desi": "Shopping",
        // Electronics
        "croma": "Shopping",
        "vijay sales": "Shopping",
        "reliance digital": "Shopping",
        "sangeetha mobiles": "Shopping",
        "poorvika": "Shopping",
        "bajaj electronics": "Shopping",
        "apple store": "Shopping",
        // Home & furniture
        "ikea": "Shopping",
        "urban ladder": "Shopping",
        "pepperfry": "Shopping",
        "home centre": "Shopping",
        "@home": "Shopping",
        "godrej interio": "Shopping",
        // Books
        "bookmyshow": "Entertainment",   // movie/event tickets — primary category
        "crossword": "Shopping",
        "landmark": "Shopping",
        "kindle": "Shopping",

        // ---------------- Entertainment ----------------
        "paytm insider": "Entertainment",
        "district by zomato": "Entertainment",
        "pvr": "Entertainment",
        "inox": "Entertainment",
        "cinepolis": "Entertainment",
        "imax": "Entertainment",
        "carnival cinemas": "Entertainment",

        // ---------------- Subscriptions ----------------
        "netflix": "Subscriptions",
        "spotify": "Subscriptions",
        "amazon prime": "Subscriptions",
        "prime video": "Subscriptions",
        "disney+": "Subscriptions",
        "disney plus": "Subscriptions",
        "hotstar": "Subscriptions",
        "jiocinema": "Subscriptions",
        "jio cinema": "Subscriptions",
        "sonyliv": "Subscriptions",
        "sony liv": "Subscriptions",
        "zee5": "Subscriptions",
        "voot": "Subscriptions",
        "alt balaji": "Subscriptions",
        "youtube premium": "Subscriptions",
        "youtube music": "Subscriptions",
        "apple music": "Subscriptions",
        "apple tv": "Subscriptions",
        "icloud": "Subscriptions",
        "google one": "Subscriptions",
        "google drive": "Subscriptions",
        "google workspace": "Subscriptions",
        "microsoft 365": "Subscriptions",
        "office 365": "Subscriptions",
        "adobe": "Subscriptions",
        "adobe creative cloud": "Subscriptions",
        "canva": "Subscriptions",
        "notion": "Subscriptions",
        "figma": "Subscriptions",
        "github": "Subscriptions",
        "openai": "Subscriptions",
        "chatgpt": "Subscriptions",
        "claude": "Subscriptions",
        "linkedin premium": "Subscriptions",
        "audible": "Subscriptions",
        "kindle unlimited": "Subscriptions",
        "gaana": "Subscriptions",
        "wynk music": "Subscriptions",
        "jiosaavn": "Subscriptions",
        "saavn": "Subscriptions",

        // ---------------- Bills ----------------
        // Telecom
        "airtel": "Bills",
        "jio": "Bills",
        "vi ": "Bills",
        "vodafone": "Bills",
        "vodafone idea": "Bills",
        "bsnl": "Bills",
        "mtnl": "Bills",
        // DTH / cable
        "tata sky": "Bills",
        "tata play": "Bills",
        "dish tv": "Bills",
        "videocon d2h": "Bills",
        "sun direct": "Bills",
        "airtel digital tv": "Bills",
        "d2h": "Bills",
        // Broadband
        "act fibernet": "Bills",
        "act broadband": "Bills",
        "hathway": "Bills",
        "tikona": "Bills",
        "jio fiber": "Bills",
        "airtel xstream": "Bills",
        "excitel": "Bills",
        "spectra": "Bills",
        // Electricity boards
        "bses": "Bills",
        "tata power": "Bills",
        "torrent power": "Bills",
        "msedcl": "Bills",
        "kseb": "Bills",
        "tsspdcl": "Bills",
        "apspdcl": "Bills",
        "wbsedcl": "Bills",
        "uppcl": "Bills",
        "noida power": "Bills",
        "ndmc": "Bills",
        // Water
        "djb": "Bills",
        "delhi jal": "Bills",
        "bwssb": "Bills",
        "hmwssb": "Bills",
        "mwssb": "Bills",
        // Gas
        "indraprastha gas": "Bills",
        "mahanagar gas": "Bills",
        "adani gas": "Bills",
        "gail gas": "Bills",
        // Society maintenance / housing
        "mygate": "Bills",
        "nobroker": "Bills",
        "apnacomplex": "Bills",

        // ---------------- Education ----------------
        "byju's": "Education",
        "byjus": "Education",
        "unacademy": "Education",
        "vedantu": "Education",
        "physicswallah": "Education",
        "physics wallah": "Education",
        "white hat jr": "Education",
        "whitehat jr": "Education",
        "cuemath": "Education",
        "doubtnut": "Education",
        "udemy": "Education",
        "coursera": "Education",
        "edx": "Education",
        "upgrad": "Education",
        "great learning": "Education",
        "scaler": "Education",
        "interviewbit": "Education",
        "skillshare": "Education",
        "duolingo": "Education",

        // ---------------- Financial ----------------
        "zerodha": "Investments",
        "groww": "Investments",
        "upstox": "Investments",
        "icici direct": "Investments",
        "kuvera": "Investments",
        "smallcase": "Investments",
        "indmoney": "Investments",
        "ind money": "Investments",
        "policybazaar": "Insurance",
        "policy bazaar": "Insurance",
        "lic of india": "Insurance",
        "lic ": "Insurance",
        "hdfc life": "Insurance",
        "icici prudential": "Insurance",
        "max life": "Insurance",
        "sbi life": "Insurance",
        "acko": "Insurance",
        "digit insurance": "Insurance",

        // ---------------- Beauty / Personal Care ----------------
        "urbanclap": "Personal Care",
        "urban company": "Personal Care",
        "lakme salon": "Personal Care",
        "vlcc": "Personal Care",
        "naturals salon": "Personal Care",
        "jawed habib": "Personal Care",
        "bblunt": "Personal Care",
        "the body shop": "Personal Care",
        "forest essentials": "Personal Care",
        "kama ayurveda": "Personal Care",
        "mamaearth": "Personal Care",
        "wow skin": "Personal Care",
        "plum": "Personal Care",
        "purplle": "Personal Care"
    ]

    // MARK: - Per-Category Item Keywords
    //
    // When an FM has to categorize an expense and the merchant name
    // is unclear, the ITEMS list is the strongest signal. These
    // keyword sets map item words to categories. Substring match,
    // lowercase.
    //
    // **Used by**: passed into the FM prompt as supporting context
    // so the model can "look up" common items by category rather
    // than reasoning from scratch. Also usable as a fallback
    // categorizer when FM is unavailable.

    /// Item keywords that strongly signal each category. Mapping
    /// is item-keyword → category-name (matches Tula's default
    /// category list).
    static let itemCategoryHints: [String: String] = [
        // ---------------- Food & Drinks ----------------
        // Main course / dishes
        "dosa": "Food & Drinks",
        "idli": "Food & Drinks",
        "vada": "Food & Drinks",
        "sambar": "Food & Drinks",
        "uttapam": "Food & Drinks",
        "biryani": "Food & Drinks",
        "pulao": "Food & Drinks",
        "fried rice": "Food & Drinks",
        "noodles": "Food & Drinks",
        "manchurian": "Food & Drinks",
        "paneer butter masala": "Food & Drinks",
        "paneer tikka": "Food & Drinks",
        "shahi paneer": "Food & Drinks",
        "palak paneer": "Food & Drinks",
        // Note: bare "paneer" appears only in the Groceries section
        // below — when shown as part of a dish name above it resolves
        // to Food & Drinks; when bought as raw ingredient it resolves
        // to Groceries.
        "butter chicken": "Food & Drinks",
        "tikka masala": "Food & Drinks",
        "naan": "Food & Drinks",
        "roti": "Food & Drinks",
        "chapati": "Food & Drinks",
        "thali": "Food & Drinks",
        "meals": "Food & Drinks",
        "thali meal": "Food & Drinks",
        "veg meals": "Food & Drinks",
        "non veg meals": "Food & Drinks",
        "samosa": "Food & Drinks",
        "kachori": "Food & Drinks",
        "pakora": "Food & Drinks",
        "pakoda": "Food & Drinks",
        "vada pav": "Food & Drinks",
        "pav bhaji": "Food & Drinks",
        "chaat": "Food & Drinks",
        "panipuri": "Food & Drinks",
        "pani puri": "Food & Drinks",
        "golgappa": "Food & Drinks",
        "bhel puri": "Food & Drinks",
        "papdi": "Food & Drinks",
        // International
        "pizza": "Food & Drinks",
        "burger": "Food & Drinks",
        "sandwich": "Food & Drinks",
        "wrap": "Food & Drinks",
        "shawarma": "Food & Drinks",
        "pasta": "Food & Drinks",
        "lasagna": "Food & Drinks",
        "sushi": "Food & Drinks",
        "ramen": "Food & Drinks",
        // Drinks
        "coffee": "Food & Drinks",
        "latte": "Food & Drinks",
        "cappuccino": "Food & Drinks",
        "espresso": "Food & Drinks",
        "americano": "Food & Drinks",
        "mocha": "Food & Drinks",
        "tea": "Food & Drinks",
        "chai": "Food & Drinks",
        "masala chai": "Food & Drinks",
        "green tea": "Food & Drinks",
        "lemonade": "Food & Drinks",
        "juice": "Food & Drinks",
        "milkshake": "Food & Drinks",
        "smoothie": "Food & Drinks",
        "lassi": "Food & Drinks",
        "buttermilk": "Food & Drinks",
        "soda": "Food & Drinks",
        "coke": "Food & Drinks",
        "pepsi": "Food & Drinks",
        "sprite": "Food & Drinks",
        "fanta": "Food & Drinks",
        // Desserts
        "ice cream": "Food & Drinks",
        "icecream": "Food & Drinks",
        "gulab jamun": "Food & Drinks",
        "rasgulla": "Food & Drinks",
        "kulfi": "Food & Drinks",
        "halwa": "Food & Drinks",
        "kheer": "Food & Drinks",
        "cake": "Food & Drinks",
        "pastry": "Food & Drinks",
        "brownie": "Food & Drinks",
        "donut": "Food & Drinks",
        "muffin": "Food & Drinks",
        // Meal types
        "breakfast": "Food & Drinks",
        "lunch": "Food & Drinks",
        "dinner": "Food & Drinks",
        "snacks": "Food & Drinks",
        "brunch": "Food & Drinks",

        // ---------------- Groceries ----------------
        // Staples
        "rice": "Groceries",
        "basmati": "Groceries",
        "atta": "Groceries",
        "wheat flour": "Groceries",
        "maida": "Groceries",
        "sooji": "Groceries",
        "rava": "Groceries",
        "besan": "Groceries",
        "dal": "Groceries",
        "toor dal": "Groceries",
        "moong dal": "Groceries",
        "chana dal": "Groceries",
        "urad dal": "Groceries",
        "rajma": "Groceries",
        "chickpea": "Groceries",
        "chana": "Groceries",
        "kabuli chana": "Groceries",
        // Vegetables (common Indian)
        "tomato": "Groceries",
        "onion": "Groceries",
        "potato": "Groceries",
        "aloo": "Groceries",
        "lady finger": "Groceries",
        "bhindi": "Groceries",
        "cauliflower": "Groceries",
        "cabbage": "Groceries",
        "carrot": "Groceries",
        "spinach": "Groceries",
        "palak": "Groceries",
        "methi": "Groceries",
        "coriander": "Groceries",
        "dhania": "Groceries",
        "mint": "Groceries",
        "pudina": "Groceries",
        "ginger": "Groceries",
        "garlic": "Groceries",
        "green chilli": "Groceries",
        "lemon": "Groceries",
        // Dairy
        "milk": "Groceries",
        "curd": "Groceries",
        "yogurt": "Groceries",
        "butter": "Groceries",
        "ghee": "Groceries",
        "cheese": "Groceries",
        "paneer": "Groceries",
        "amul": "Groceries",
        "mother dairy": "Groceries",
        // Oils & spices
        "oil": "Groceries",
        "sunflower oil": "Groceries",
        "mustard oil": "Groceries",
        "coconut oil": "Groceries",
        "groundnut oil": "Groceries",
        "salt": "Groceries",
        "sugar": "Groceries",
        "jaggery": "Groceries",
        "haldi": "Groceries",
        "turmeric": "Groceries",
        "jeera": "Groceries",
        "cumin": "Groceries",
        "garam masala": "Groceries",
        "chilli powder": "Groceries",
        // Fruits
        "apple": "Groceries",
        "banana": "Groceries",
        "mango": "Groceries",
        "orange": "Groceries",
        "grapes": "Groceries",
        "papaya": "Groceries",
        "watermelon": "Groceries",
        "pineapple": "Groceries",
        // Packaged
        "biscuits": "Groceries",
        "bread": "Groceries",
        "eggs": "Groceries",
        "anda": "Groceries",
        "chicken": "Groceries",
        "mutton": "Groceries",
        "fish": "Groceries",
        "prawns": "Groceries",
        "noodles pack": "Groceries",
        "maggi": "Groceries",
        "kurkure": "Groceries",
        "lays": "Groceries",
        // Household
        "detergent": "Groceries",
        "surf excel": "Groceries",
        "ariel": "Groceries",
        "tide": "Groceries",
        "soap": "Groceries",
        "shampoo": "Groceries",
        "toothpaste": "Groceries",
        "colgate": "Groceries",
        "tissue": "Groceries",
        "garbage bag": "Groceries",

        // ---------------- Transport ----------------
        "petrol": "Transport",
        "diesel": "Transport",
        "fuel": "Transport",
        "cng": "Transport",
        "lpg auto": "Transport",
        "ride fare": "Transport",
        "trip fare": "Transport",
        "auto fare": "Transport",
        "taxi fare": "Transport",
        "cab fare": "Transport",
        "ola share": "Transport",
        "uber go": "Transport",
        "uber premier": "Transport",
        "metro card": "Transport",
        "metro recharge": "Transport",
        "smart card": "Transport",
        "train ticket": "Transport",
        "flight ticket": "Transport",
        "bus ticket": "Transport",
        "parking": "Transport",
        "parking fee": "Transport",
        "toll": "Transport",
        "toll plaza": "Transport",
        "fastag recharge": "Transport",

        // ---------------- Health ----------------
        "consultation": "Health",
        "doctor visit": "Health",
        "doctor fee": "Health",
        "consultation fee": "Health",
        "medicine": "Health",
        "tablet": "Health",
        "tablets": "Health",
        "capsule": "Health",
        "capsules": "Health",
        "syrup": "Health",
        "injection": "Health",
        "vaccination": "Health",
        "vaccine": "Health",
        "blood test": "Health",
        "lab test": "Health",
        "x-ray": "Health",
        "xray": "Health",
        "mri": "Health",
        "ct scan": "Health",
        "ultrasound": "Health",
        "ecg": "Health",
        "covid test": "Health",
        "rt-pcr": "Health",
        "rtpcr": "Health",
        "physiotherapy": "Health",
        "dental": "Health",
        "filling": "Health",
        "root canal": "Health",
        "extraction": "Health",
        "scaling": "Health",
        // Common drug names appear so much on bills they're worth listing
        "crocin": "Health",
        "dolo": "Health",
        "paracetamol": "Health",
        "azithromycin": "Health",
        "amoxicillin": "Health",
        "metformin": "Health",
        "atorvastatin": "Health",
        "pantop": "Health",
        "pantoprazole": "Health",
        "cetirizine": "Health",

        // ---------------- Shopping ----------------
        "shirt": "Shopping",
        "tshirt": "Shopping",
        "t-shirt": "Shopping",
        "jeans": "Shopping",
        "trousers": "Shopping",
        "kurta": "Shopping",
        "saree": "Shopping",
        "dress": "Shopping",
        "shoes": "Shopping",
        "sneakers": "Shopping",
        "sandals": "Shopping",
        "watch": "Shopping",
        "bag": "Shopping",
        "wallet": "Shopping",
        "perfume": "Shopping",
        "headphones": "Shopping",
        "earphones": "Shopping",
        "charger": "Shopping",
        "cable": "Shopping",
        "phone case": "Shopping",
        "screen protector": "Shopping",

        // ---------------- Entertainment ----------------
        "movie ticket": "Entertainment",
        "ticket": "Entertainment",  // weak — let category combo decide
        "concert": "Entertainment",
        "game pass": "Entertainment",
        "popcorn": "Entertainment",

        // ---------------- Bills ----------------
        "recharge": "Bills",
        "data pack": "Bills",
        "voice pack": "Bills",
        "mobile bill": "Bills",
        "broadband bill": "Bills",
        "wifi": "Bills",
        "electricity bill": "Bills",
        "energy charges": "Bills",
        "water bill": "Bills",
        "gas bill": "Bills",
        "lpg cylinder": "Bills",
        "lpg refill": "Bills",
        "dth recharge": "Bills",
        "maintenance": "Bills",
        "society maintenance": "Bills"
    ]

    // MARK: - Regex Patterns
    //
    // Compiled patterns for structured noise filtering. These match
    // common Indian-bill identifiers that should NEVER be parsed as
    // amounts, merchants, or items. Used by extractors as additional
    // filters beyond the keyword sets.

    /// GSTIN: 15-character alphanumeric — 2 digit state code, 10 char
    /// PAN, 1 entity number, 1 default Z, 1 checksum. Example:
    /// "37AAACA5443N3ZF". Lines containing this are header metadata,
    /// not items or amounts.
    static let gstinPattern = #"\b\d{2}[A-Z]{5}\d{4}[A-Z]\d[A-Z][A-Z\d]\b"#

    /// PAN: 10-char alphanumeric. Example: "AAACA5443N". Sometimes
    /// printed separately from GSTIN.
    static let panPattern = #"\b[A-Z]{5}\d{4}[A-Z]\b"#

    /// Indian phone number patterns. Common forms:
    ///   - 10 digits starting with 6-9 (mobile)
    ///   - +91 / 91 / 0 prefix variations
    ///   - Sometimes with spaces or hyphens
    static let phonePattern = #"(?:\+?91[\s\-]?)?[6-9]\d{9}\b"#

    /// Indian date formats commonly seen on bills:
    ///   - 21/12/2023, 21-12-2023, 21.12.2023
    ///   - 21-Dec-2023, 21 Dec 2023
    ///   - 2023-12-21 (ISO)
    /// Caller passes one of these into NSDataDetector or DateFormatter.
    /// This is for IDENTIFYING date lines so they can be skipped from
    /// other extraction.
    static let datePatterns: [String] = [
        #"\b\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}\b"#,
        #"\b\d{1,2}[\s\-]?(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*[\s\-]?\d{2,4}\b"#,
        #"\b\d{4}-\d{2}-\d{2}\b"#
    ]

    /// UPI handle / VPA pattern. Format: somename@bank-or-app.
    /// Common suffixes: @oksbi, @okhdfcbank, @okicici, @okaxis,
    /// @paytm, @ybl, @apl, @ibl, @upi. Lines containing these are
    /// almost always headers/footers, not items.
    static let upiHandlePattern = #"\b[\w\.\-]+@(?:ok[a-z]+|paytm|ybl|apl|ibl|axl|hdfcbank|axisbank|upi)\b"#

    // MARK: - Address / Location Noise
    //
    // Indian receipts often print the merchant's address near the top.
    // City and state names get picked up as merchant or item names if
    // we're not careful. Including the most populous cities as a noise
    // set lets the merchant extractor skip address lines.

    /// Indian cities — major metros + tier 2/3 cities seen on receipts
    /// most often. When a line contains ONLY a city name and nothing
    /// else useful (no item, no price, no merchant marker), it's the
    /// address line and should be skipped from merchant extraction.
    static let indianCities: Set<String> = [
        // Metros
        "mumbai", "delhi", "bangalore", "bengaluru", "hyderabad",
        "chennai", "kolkata", "ahmedabad", "pune",
        // Tier 1
        "jaipur", "surat", "lucknow", "kanpur", "nagpur", "patna",
        "indore", "thane", "bhopal", "visakhapatnam", "vizag",
        "pimpri", "vadodara", "ghaziabad", "ludhiana", "agra",
        "nashik", "faridabad", "meerut", "rajkot", "kalyan",
        "varanasi", "srinagar", "aurangabad", "dhanbad", "amritsar",
        "navi mumbai", "allahabad", "prayagraj", "ranchi", "howrah",
        "coimbatore", "jabalpur", "gwalior", "vijayawada", "jodhpur",
        "madurai", "raipur", "kota", "guwahati", "chandigarh",
        "solapur", "hubli", "tiruchirappalli", "trichy", "bareilly",
        "mysore", "mysuru", "tiruppur", "gurgaon", "gurugram",
        "noida", "greater noida",
        // South India tech corridors
        "electronic city", "whitefield", "marathahalli", "koramangala",
        "indiranagar", "hitech city", "hitec city", "madhapur",
        "gachibowli", "kondapur", "manikonda", "kompally", "kukatpally",
        "secunderabad", "begumpet", "banjara hills", "jubilee hills",
        // Common state names
        "telangana", "andhra pradesh", "karnataka", "tamil nadu",
        "kerala", "maharashtra", "gujarat", "rajasthan", "punjab",
        "haryana", "odisha", "west bengal", "uttar pradesh", "bihar"
    ]

    // MARK: - Unit Indicators
    //
    // Line items often include units (kg, gms, ltr). Recognizing these
    // helps confirm a line IS an item, not metadata.

    /// Quantity/unit suffixes that strongly indicate "this line is a
    /// purchased item with a measured quantity." Useful as a tiebreaker
    /// when deciding whether to keep a line in the item extractor.
    static let itemUnitSuffixes: Set<String> = [
        // Weight
        "kg", "kgs", "gm", "gms", "gram", "grams", "g ",
        // Volume
        "ml", "litre", "litres", "ltr", "liter", "liters", "l ",
        // Count
        "pcs", "pc", "nos", "no.", "qty", "pkt", "packet",
        "box", "btl", "bottle", "can", "cans",
        // Dozen / pair / set
        "dozen", "pair", "set", "pack"
    ]
}
