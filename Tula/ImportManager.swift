import Foundation
import SwiftData

// MARK: - Import Manager

/// Parses CSV files and imports expenses into the SwiftData store.
///
/// Supports two formats:
/// 1. **Tula export** — detected by "Tula Expense Report" header. Skips
///    the preamble and parses the transaction table directly.
/// 2. **Generic CSV** — any CSV with a header row. User maps columns
///    via `ColumnMapping`.
///
/// Duplicate detection: rows matching (calendar day + amount + merchant
/// lowercase) against existing expenses are flagged as duplicates and
/// skipped during commit.
enum ImportManager {

    // MARK: - Types

    struct ParsedRow: Identifiable {
        let id = UUID()
        var date: Date
        var amount: Double
        var merchant: String?
        var categoryName: String?
        var accountName: String?
        var note: String?
        var isDuplicate: Bool = false
    }

    enum CSVFormat {
        case tulaExport
        case generic
    }

    struct ColumnMapping {
        var dateCol: Int = 0
        var amountCol: Int = 1
        var merchantCol: Int? = nil
        var categoryCol: Int? = nil
        var accountCol: Int? = nil
        var noteCol: Int? = nil
    }

    struct ImportResult {
        var imported: Int = 0
        var skipped: Int = 0
        var errors: Int = 0
    }

    // MARK: - Format Detection

    /// Detects whether a CSV string is a Tula export or generic CSV.
    static func detectFormat(_ csv: String) -> CSVFormat {
        let firstLine = csv.prefix(while: { $0 != "\n" && $0 != "\r" })
        if firstLine.contains("Tula Expense Report") {
            return .tulaExport
        }
        return .generic
    }

    // MARK: - CSV Parsing Utilities

    /// Strips UTF-8 BOM if present.
    private static func stripBOM(_ csv: String) -> String {
        var s = csv
        if s.hasPrefix("\u{FEFF}") {
            s.removeFirst()
        }
        return s
    }

    /// Splits a CSV string into lines, handling both CRLF and LF.
    private static func splitLines(_ csv: String) -> [String] {
        csv.replacingOccurrences(of: "\r\n", with: "\n")
           .replacingOccurrences(of: "\r", with: "\n")
           .components(separatedBy: "\n")
    }

    /// Parses a single CSV line into fields, respecting quoted fields
    /// and escaped quotes (doubled double-quotes).
    static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = line.makeIterator()

        while let c = chars.next() {
            if inQuotes {
                if c == "\"" {
                    // Peek for doubled quote
                    // We need a different approach since makeIterator doesn't support peek
                    current.append(c)
                    inQuotes = false
                } else {
                    current.append(c)
                }
            } else {
                if c == "\"" {
                    // Check if this is an escaped quote inside a field
                    if current.last == "\"" {
                        // Doubled quote → literal quote
                        current.removeLast()
                        current.append("\"")
                        inQuotes = true
                    } else {
                        inQuotes = true
                    }
                } else if c == "," {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(c)
                }
            }
        }
        fields.append(current)

        // Clean up: remove surrounding quotes and unescape
        return fields.map { field in
            var f = field.trimmingCharacters(in: .whitespaces)
            if f.hasPrefix("\"") && f.hasSuffix("\"") && f.count >= 2 {
                f = String(f.dropFirst().dropLast())
                f = f.replacingOccurrences(of: "\"\"", with: "\"")
            }
            return f
        }
    }

    // MARK: - Tula Format Parsing

    /// Parses a Tula-exported CSV. Skips the preamble (summary + category
    /// breakdown) and reads from the transaction header row onward.
    static func parseTulaFormat(_ csv: String) -> [ParsedRow] {
        let cleaned = stripBOM(csv)
        let lines = splitLines(cleaned)

        // Find the transaction header row: "Date,Time,Amount,..."
        guard let headerIndex = lines.firstIndex(where: {
            $0.hasPrefix("Date,Time,Amount")
        }) else {
            return []
        }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd HH:mm"
        dateFmt.locale = Locale(identifier: "en_US_POSIX")

        let dateOnlyFmt = DateFormatter()
        dateOnlyFmt.dateFormat = "yyyy-MM-dd"
        dateOnlyFmt.locale = Locale(identifier: "en_US_POSIX")

        var rows: [ParsedRow] = []

        for i in (headerIndex + 1)..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let fields = parseCSVLine(line)
            // Expected: Date, Time, Amount, Currency, Merchant, Category, Account, Source, Note
            guard fields.count >= 3 else { continue }

            let dateStr = fields[0]
            let timeStr = fields.count > 1 ? fields[1] : "00:00"
            guard let amount = Double(fields[2].trimmingCharacters(in: .whitespaces)),
                  amount > 0 else { continue }

            let date = dateFmt.date(from: "\(dateStr) \(timeStr)")
                ?? dateOnlyFmt.date(from: dateStr)
                ?? Date()

            let merchant = fields.count > 4 ? nilIfEmpty(fields[4]) : nil
            let category = fields.count > 5 ? nilIfEmpty(fields[5]) : nil
            let account  = fields.count > 6 ? nilIfEmpty(fields[6]) : nil
            let note     = fields.count > 8 ? nilIfEmpty(fields[8]) : nil

            rows.append(ParsedRow(
                date: date,
                amount: amount,
                merchant: merchant,
                categoryName: category,
                accountName: account,
                note: note
            ))
        }

        return rows
    }

    // MARK: - Generic Format Parsing

    /// Reads headers from the first row of a generic CSV.
    static func readHeaders(_ csv: String) -> [String] {
        let cleaned = stripBOM(csv)
        let lines = splitLines(cleaned)
        guard let first = lines.first else { return [] }
        return parseCSVLine(first)
    }

    /// Parses a generic CSV using the provided column mapping.
    static func parseGeneric(_ csv: String, mapping: ColumnMapping) -> [ParsedRow] {
        let cleaned = stripBOM(csv)
        let lines = splitLines(cleaned)
        guard lines.count > 1 else { return [] }

        // Try multiple date formats
        let dateFormats = [
            "yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy",
            "dd-MM-yyyy", "yyyy/MM/dd", "d/M/yyyy",
            "yyyy-MM-dd HH:mm", "dd/MM/yyyy HH:mm"
        ]

        var rows: [ParsedRow] = []

        // Skip header row (index 0)
        for i in 1..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let fields = parseCSVLine(line)
            guard fields.count > max(mapping.dateCol, mapping.amountCol) else { continue }

            let dateStr = fields[mapping.dateCol].trimmingCharacters(in: .whitespaces)
            let amountStr = fields[mapping.amountCol]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: "")

            guard let amount = Double(amountStr), amount > 0 else { continue }

            // Try each date format
            var date: Date?
            for fmt in dateFormats {
                let df = DateFormatter()
                df.dateFormat = fmt
                df.locale = Locale(identifier: "en_US_POSIX")
                if let d = df.date(from: dateStr) {
                    date = d
                    break
                }
            }
            guard let parsedDate = date else { continue }

            let merchant = mapping.merchantCol.flatMap { fields.count > $0 ? nilIfEmpty(fields[$0]) : nil }
            let category = mapping.categoryCol.flatMap { fields.count > $0 ? nilIfEmpty(fields[$0]) : nil }
            let account  = mapping.accountCol.flatMap { fields.count > $0 ? nilIfEmpty(fields[$0]) : nil }
            let note     = mapping.noteCol.flatMap { fields.count > $0 ? nilIfEmpty(fields[$0]) : nil }

            rows.append(ParsedRow(
                date: parsedDate,
                amount: amount,
                merchant: merchant,
                categoryName: category,
                accountName: account,
                note: note
            ))
        }

        return rows
    }

    // MARK: - Duplicate Detection

    /// Marks rows that match existing expenses as duplicates.
    /// Match criteria: same calendar day + same amount + same merchant (case-insensitive).
    static func markDuplicates(_ rows: inout [ParsedRow], existing: [Expense]) {
        let calendar = Calendar.current
        // Build a set of (day, amount, merchant) keys from existing expenses
        var existingKeys = Set<String>()
        for expense in existing {
            let day = calendar.startOfDay(for: expense.date)
            let key = "\(day.timeIntervalSince1970)|\(expense.amount)|\((expense.merchant ?? "").lowercased())"
            existingKeys.insert(key)
        }

        for i in rows.indices {
            let day = calendar.startOfDay(for: rows[i].date)
            let key = "\(day.timeIntervalSince1970)|\(rows[i].amount)|\((rows[i].merchant ?? "").lowercased())"
            rows[i].isDuplicate = existingKeys.contains(key)
        }
    }

    // MARK: - Commit

    /// Inserts non-duplicate parsed rows as Expense records into the context.
    @MainActor
    static func commit(
        rows: [ParsedRow],
        into context: ModelContext,
        categories: [Category],
        accounts: [Account]
    ) -> ImportResult {
        var result = ImportResult()

        // Build lookup dictionaries (case-insensitive)
        let categoryMap = Dictionary(
            uniqueKeysWithValues: categories.map { ($0.name.lowercased(), $0) }
        )
        let accountMap = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.name.lowercased(), $0) }
        )

        for row in rows {
            if row.isDuplicate {
                result.skipped += 1
                continue
            }

            let matchedCategory = row.categoryName.flatMap { categoryMap[$0.lowercased()] }
            let matchedAccount = row.accountName.flatMap { accountMap[$0.lowercased()] }

            let expense = Expense(
                amount: row.amount,
                date: row.date,
                merchant: row.merchant,
                note: row.note,
                source: ExpenseSource.imported,
                category: matchedCategory,
                account: matchedAccount
            )

            context.insert(expense)
            result.imported += 1
        }

        do {
            try context.save()
        } catch {
            result.errors += 1
        }

        return result
    }

    // MARK: - Helpers

    private static func nilIfEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
