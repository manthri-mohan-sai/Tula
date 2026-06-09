import Foundation
import SwiftData
import CryptoKit

/// Encrypted backup & restore for Tula's entire data set.
///
/// The export produces a single `.tulabackup` file that's:
/// - JSON-encoded for portability
/// - AES-GCM encrypted with a user-provided passphrase (PBKDF2-derived key)
/// - safely round-trippable: re-importing yields an identical database
///
/// Pattern lifted from Loan Tracker's BackupManager. Two key changes:
/// - More entities (Account, Category, Expense, Transfer, RecurringRule, MerchantRule)
/// - References between entities preserved via stable UUID lookups on restore

// MARK: - DTOs

struct BackupBundle: Codable {
    var schemaVersion: Int = 1
    var exportedAt: Date = .now
    var accounts: [AccountDTO]
    var categories: [CategoryDTO]
    var expenses: [ExpenseDTO]
    var transfers: [TransferDTO]
    var recurringRules: [RecurringRuleDTO]
    var merchantRules: [MerchantRuleDTO]
}

struct AccountDTO: Codable {
    let id: UUID
    let name: String
    let kind: String
    let currencyCode: String
    let iconKey: String
    let colorHex: String
    let isArchived: Bool
    let sortOrder: Int
    let createdAt: Date
    let creditLimit: Double?
    let openingBalance: Double
}

struct CategoryDTO: Codable {
    let id: UUID
    let name: String
    let iconKey: String
    let colorHex: String
    let isArchived: Bool
    let sortOrder: Int
    let createdAt: Date
}

struct ExpenseDTO: Codable {
    let id: UUID
    let amount: Double
    let date: Date
    let merchant: String?
    let note: String?
    let rawInput: String?
    let source: String
    let createdAt: Date
    let categoryID: UUID?
    let accountID: UUID?
    let recurringRuleID: UUID?
}

struct TransferDTO: Codable {
    let id: UUID
    let amount: Double
    let date: Date
    let note: String?
    let kind: String
    let createdAt: Date
    let fromAccountID: UUID?
    let toAccountID: UUID?
    let recurringRuleID: UUID?
}

struct RecurringRuleDTO: Codable {
    let id: UUID
    let name: String
    let amount: Double
    let kind: String
    let frequency: String?     // Optional for backward compatibility with old backups
    let dayOfMonth: Int
    let startDate: Date
    let endDate: Date?
    let isPaused: Bool
    let note: String?
    let createdAt: Date
    let lastGeneratedDate: Date?
    let categoryID: UUID?
    let accountID: UUID?
    let fromAccountID: UUID?
    let toAccountID: UUID?
}

struct MerchantRuleDTO: Codable {
    let id: UUID
    let pattern: String
    let isUserDefined: Bool
    let createdAt: Date
    let categoryID: UUID?
    let accountID: UUID?
}

// MARK: - Backup Manager

enum BackupError: LocalizedError {
    case noData
    case encryptionFailed
    case decryptionFailed
    case malformedBackup
    case wrongPassphrase

    var errorDescription: String? {
        switch self {
        case .noData: return "No data to back up."
        case .encryptionFailed: return "Could not encrypt the backup."
        case .decryptionFailed: return "Could not decrypt the backup."
        case .malformedBackup: return "This file isn't a valid Tula backup."
        case .wrongPassphrase: return "Wrong passphrase. Try again."
        }
    }
}

enum BackupManager {

    // MARK: - Auto Backup

    private static let autoBackupDir = "AutoBackups"
    private static let maxAutoBackups = 7
    private static let lastAutoBackupKey = "lastAutoBackupDate"

    @MainActor
    static func autoBackupIfNeeded(context: ModelContext) {
        let lastBackup = UserDefaults.standard.object(forKey: lastAutoBackupKey) as? Date ?? .distantPast
        guard !Calendar.current.isDateInToday(lastBackup) else { return }

        do {
            let dir = try autoBackupDirectory()
            let bundle = try buildBundle(from: context)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(bundle)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let filename = "tula-auto-\(formatter.string(from: .now)).json"
            let fileURL = dir.appendingPathComponent(filename)
            try data.write(to: fileURL, options: .atomic)

            UserDefaults.standard.set(Date.now, forKey: lastAutoBackupKey)
            pruneOldBackups(in: dir)
        } catch {
            // Silent failure — auto-backup is best-effort
        }
    }

    static var lastAutoBackupDate: Date? {
        UserDefaults.standard.object(forKey: lastAutoBackupKey) as? Date
    }

    private static func autoBackupDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(autoBackupDir)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func pruneOldBackups(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ) else { return }

        let sorted = files
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return da > db
            }

        for file in sorted.dropFirst(maxAutoBackups) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    @MainActor
    private static func buildBundle(from context: ModelContext) throws -> BackupBundle {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        let transfers = (try? context.fetch(FetchDescriptor<Transfer>())) ?? []
        let recurringRules = (try? context.fetch(FetchDescriptor<RecurringRule>())) ?? []
        let merchantRules = (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? []

        guard !accounts.isEmpty || !expenses.isEmpty else {
            throw BackupError.noData
        }

        return BackupBundle(
            accounts: accounts.map(AccountDTO.from),
            categories: categories.map(CategoryDTO.from),
            expenses: expenses.map(ExpenseDTO.from),
            transfers: transfers.map(TransferDTO.from),
            recurringRules: recurringRules.map(RecurringRuleDTO.from),
            merchantRules: merchantRules.map(MerchantRuleDTO.from)
        )
    }

    // MARK: - Export

    @MainActor
    static func exportBackup(from context: ModelContext, passphrase: String) throws -> Data {
        let bundle = try buildBundle(from: context)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(bundle)
        return try encrypt(jsonData, passphrase: passphrase)
    }

    // MARK: - Import

    /// Restore from an encrypted backup file. The strategy is destructive:
    /// existing data is wiped and replaced. (Merge restore is interesting
    /// but error-prone for v1; explicit replace is safer.)
    @MainActor
    static func importBackup(_ data: Data, into context: ModelContext, passphrase: String) throws {
        let jsonData = try decrypt(data, passphrase: passphrase)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let bundle: BackupBundle
        do {
            bundle = try decoder.decode(BackupBundle.self, from: jsonData)
        } catch {
            throw BackupError.malformedBackup
        }

        // Wipe existing data.
        try wipeAll(in: context)

        // Insert in dependency order: Accounts → Categories → MerchantRules
        // → RecurringRules → Expenses → Transfers. Each pass builds up an
        // ID-keyed lookup so subsequent passes can resolve references.

        var accountByID: [UUID: Account] = [:]
        for dto in bundle.accounts {
            let kind = AccountKind(rawValue: dto.kind) ?? .bank
            let account = Account(
                name: dto.name,
                kind: kind,
                currencyCode: dto.currencyCode,
                iconKey: dto.iconKey,
                colorHex: dto.colorHex,
                openingBalance: dto.openingBalance,
                creditLimit: dto.creditLimit,
                sortOrder: dto.sortOrder
            )
            account.id = dto.id
            account.isArchived = dto.isArchived
            account.createdAt = dto.createdAt
            context.insert(account)
            accountByID[dto.id] = account
        }

        var categoryByID: [UUID: Category] = [:]
        for dto in bundle.categories {
            let cat = Category(
                name: dto.name,
                iconKey: dto.iconKey,
                colorHex: dto.colorHex,
                sortOrder: dto.sortOrder
            )
            cat.id = dto.id
            cat.isArchived = dto.isArchived
            cat.createdAt = dto.createdAt
            context.insert(cat)
            categoryByID[dto.id] = cat
        }

        for dto in bundle.merchantRules {
            let rule = MerchantRule(
                pattern: dto.pattern,
                category: dto.categoryID.flatMap { categoryByID[$0] },
                account: dto.accountID.flatMap { accountByID[$0] },
                isUserDefined: dto.isUserDefined
            )
            rule.id = dto.id
            rule.createdAt = dto.createdAt
            context.insert(rule)
        }

        var ruleByID: [UUID: RecurringRule] = [:]
        for dto in bundle.recurringRules {
            let kind = RecurringKind(rawValue: dto.kind) ?? .expense
            let frequency = dto.frequency.flatMap { RecurringFrequency(rawValue: $0) } ?? .monthly
            let rule = RecurringRule(
                name: dto.name,
                amount: dto.amount,
                kind: kind,
                dayOfMonth: dto.dayOfMonth,
                frequency: frequency,
                startDate: dto.startDate
            )
            rule.id = dto.id
            rule.endDate = dto.endDate
            rule.isPaused = dto.isPaused
            rule.note = dto.note
            rule.createdAt = dto.createdAt
            rule.lastGeneratedDate = dto.lastGeneratedDate
            rule.category = dto.categoryID.flatMap { categoryByID[$0] }
            rule.account = dto.accountID.flatMap { accountByID[$0] }
            rule.fromAccount = dto.fromAccountID.flatMap { accountByID[$0] }
            rule.toAccount = dto.toAccountID.flatMap { accountByID[$0] }
            context.insert(rule)
            ruleByID[dto.id] = rule
        }

        for dto in bundle.expenses {
            let source = ExpenseSource(rawValue: dto.source) ?? .manual
            let expense = Expense(
                amount: dto.amount,
                date: dto.date,
                merchant: dto.merchant,
                note: dto.note,
                source: source,
                category: dto.categoryID.flatMap { categoryByID[$0] },
                account: dto.accountID.flatMap { accountByID[$0] }
            )
            expense.id = dto.id
            expense.rawInput = dto.rawInput
            expense.createdAt = dto.createdAt
            expense.recurringRule = dto.recurringRuleID.flatMap { ruleByID[$0] }
            context.insert(expense)
        }

        for dto in bundle.transfers {
            let kind = TransferKind(rawValue: dto.kind) ?? .generic
            let transfer = Transfer(
                amount: dto.amount,
                fromAccount: dto.fromAccountID.flatMap { accountByID[$0] },
                toAccount: dto.toAccountID.flatMap { accountByID[$0] },
                date: dto.date,
                kind: kind,
                note: dto.note
            )
            transfer.id = dto.id
            transfer.createdAt = dto.createdAt
            transfer.recurringRule = dto.recurringRuleID.flatMap { ruleByID[$0] }
            context.insert(transfer)
        }

        try context.save()
    }

    // MARK: - Wipe (used by restore)

    @MainActor
    private static func wipeAll(in context: ModelContext) throws {
        for expense in (try? context.fetch(FetchDescriptor<Expense>())) ?? [] {
            context.delete(expense)
        }
        for transfer in (try? context.fetch(FetchDescriptor<Transfer>())) ?? [] {
            context.delete(transfer)
        }
        for rule in (try? context.fetch(FetchDescriptor<RecurringRule>())) ?? [] {
            context.delete(rule)
        }
        for mRule in (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? [] {
            context.delete(mRule)
        }
        for category in (try? context.fetch(FetchDescriptor<Category>())) ?? [] {
            context.delete(category)
        }
        for account in (try? context.fetch(FetchDescriptor<Account>())) ?? [] {
            context.delete(account)
        }
        try context.save()
    }

    // MARK: - Crypto

    /// File format: [16 bytes salt][12 bytes nonce][...ciphertext+tag...]
    /// Key derived via PBKDF2-SHA256, 100k iterations.
    private static let saltSize = 16
    private static let nonceSize = 12
    private static let iterations = 100_000

    private static func encrypt(_ plaintext: Data, passphrase: String) throws -> Data {
        var salt = Data(count: saltSize)
        let saltStatus = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, saltSize, ptr.baseAddress!)
        }
        guard saltStatus == errSecSuccess else { throw BackupError.encryptionFailed }

        let key = try deriveKey(from: passphrase, salt: salt)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        var output = Data()
        output.append(salt)
        output.append(contentsOf: nonce)
        if let combined = sealed.combined {
            // sealed.combined = nonce + ciphertext + tag. We already prepended
            // nonce separately; strip it to avoid duplicating bytes.
            output.append(combined.dropFirst(nonceSize))
        } else {
            throw BackupError.encryptionFailed
        }
        return output
    }

    private static func decrypt(_ data: Data, passphrase: String) throws -> Data {
        guard data.count > saltSize + nonceSize + 16 else { throw BackupError.malformedBackup }

        let salt = data.prefix(saltSize)
        let nonceBytes = data.dropFirst(saltSize).prefix(nonceSize)
        let ciphertextAndTag = data.dropFirst(saltSize + nonceSize)

        let key = try deriveKey(from: passphrase, salt: salt)

        // Validate nonce structure — throws if malformed, value not needed
        // beyond the validation since SealedBox(combined:) reconstructs it.
        _ = try AES.GCM.Nonce(data: nonceBytes)

        // sealed.combined expects nonce + ciphertext + tag, so reassemble.
        var combined = Data()
        combined.append(nonceBytes)
        combined.append(ciphertextAndTag)

        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw BackupError.wrongPassphrase
        }
    }

    private static func deriveKey(from passphrase: String, salt: Data) throws -> SymmetricKey {
        let passwordData = Data(passphrase.utf8)
        var derivedKeyData = Data(count: 32)

        let status = derivedKeyData.withUnsafeMutableBytes { derivedBytes -> Int32 in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress, passwordData.count,
                        saltBytes.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedBytes.baseAddress, 32
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw BackupError.encryptionFailed }
        return SymmetricKey(data: derivedKeyData)
    }
}

import CommonCrypto

// MARK: - DTO Conversions

/// These all read @Model properties, which are MainActor-isolated.
/// The DTO conversion itself runs on MainActor since callers (BackupManager)
/// are MainActor too.

extension AccountDTO {
    @MainActor
    static func from(_ a: Account) -> AccountDTO {
        AccountDTO(
            id: a.id, name: a.name, kind: a.kind.rawValue,
            currencyCode: a.currencyCode, iconKey: a.iconKey, colorHex: a.colorHex,
            isArchived: a.isArchived, sortOrder: a.sortOrder, createdAt: a.createdAt,
            creditLimit: a.creditLimit, openingBalance: a.openingBalance
        )
    }
}

extension CategoryDTO {
    @MainActor
    static func from(_ c: Category) -> CategoryDTO {
        CategoryDTO(
            id: c.id, name: c.name, iconKey: c.iconKey, colorHex: c.colorHex,
            isArchived: c.isArchived, sortOrder: c.sortOrder, createdAt: c.createdAt
        )
    }
}

extension ExpenseDTO {
    @MainActor
    static func from(_ e: Expense) -> ExpenseDTO {
        ExpenseDTO(
            id: e.id, amount: e.amount, date: e.date,
            merchant: e.merchant, note: e.note, rawInput: e.rawInput,
            source: e.source.rawValue, createdAt: e.createdAt,
            categoryID: e.category?.id, accountID: e.account?.id,
            recurringRuleID: e.recurringRule?.id
        )
    }
}

extension TransferDTO {
    @MainActor
    static func from(_ t: Transfer) -> TransferDTO {
        TransferDTO(
            id: t.id, amount: t.amount, date: t.date,
            note: t.note, kind: t.kind.rawValue, createdAt: t.createdAt,
            fromAccountID: t.fromAccount?.id, toAccountID: t.toAccount?.id,
            recurringRuleID: t.recurringRule?.id
        )
    }
}

extension RecurringRuleDTO {
    @MainActor
    static func from(_ r: RecurringRule) -> RecurringRuleDTO {
        RecurringRuleDTO(
            id: r.id, name: r.name, amount: r.amount, kind: r.kind.rawValue,
            frequency: r.frequency.rawValue,
            dayOfMonth: r.dayOfMonth, startDate: r.startDate, endDate: r.endDate,
            isPaused: r.isPaused, note: r.note, createdAt: r.createdAt,
            lastGeneratedDate: r.lastGeneratedDate,
            categoryID: r.category?.id, accountID: r.account?.id,
            fromAccountID: r.fromAccount?.id, toAccountID: r.toAccount?.id
        )
    }
}

extension MerchantRuleDTO {
    @MainActor
    static func from(_ m: MerchantRule) -> MerchantRuleDTO {
        MerchantRuleDTO(
            id: m.id, pattern: m.pattern, isUserDefined: m.isUserDefined,
            createdAt: m.createdAt,
            categoryID: m.category?.id, accountID: m.account?.id
        )
    }
}
