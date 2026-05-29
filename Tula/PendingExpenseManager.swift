//
//  PendingExpenseManager.swift
//  Tula
//
//  Manages pending expenses saved by the Share Extension for import
//  by the main app. Uses the App Group shared container for IPC.
//

import Foundation

/// A pending expense created by the Share Extension, waiting to be
/// imported into SwiftData by the main app.
struct PendingExpense: Codable {
    var id: String = UUID().uuidString
    var amount: Double
    var merchant: String?
    var date: Date
    var category: String?
    var note: String?
    var source: String  // "share"
    var receiptImageFilename: String?
    var createdAt: Date = Date()
}

/// Reads and writes pending expenses to the App Group shared container.
/// Used by both the Share Extension (writes) and the main app (reads & deletes).
final class PendingExpenseManager {

    private let appGroupID = "group.com.app.Tula"
    private let pendingFileName = "pending_expenses.json"
    private let receiptsFolderName = "shared_receipts"

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private var pendingFileURL: URL? {
        containerURL?.appendingPathComponent(pendingFileName)
    }

    private var receiptsFolderURL: URL? {
        containerURL?.appendingPathComponent(receiptsFolderName)
    }

    // MARK: - Write (Share Extension)

    /// Add a pending expense to the queue.
    func addPendingExpense(_ expense: PendingExpense) {
        var existing = loadPendingExpenses()
        existing.append(expense)
        savePendingExpenses(existing)
    }

    /// Save receipt image data to the shared container.
    func saveReceiptImage(data: Data, filename: String) {
        guard let folder = receiptsFolderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent(filename)
        try? data.write(to: fileURL)
    }

    // MARK: - Read (Main App)

    /// Load all pending expenses from the shared container.
    func loadPendingExpenses() -> [PendingExpense] {
        guard let url = pendingFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PendingExpense].self, from: data)) ?? []
    }

    /// Load receipt image data for a given filename.
    func loadReceiptImage(filename: String) -> Data? {
        guard let folder = receiptsFolderURL else { return nil }
        let fileURL = folder.appendingPathComponent(filename)
        return try? Data(contentsOf: fileURL)
    }

    // MARK: - Delete (Main App, after import)

    /// Remove a specific pending expense by ID.
    func removePendingExpense(id: String) {
        var existing = loadPendingExpenses()
        existing.removeAll { $0.id == id }
        savePendingExpenses(existing)
    }

    /// Clear all pending expenses (after successful import).
    func clearAll() {
        guard let url = pendingFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Delete a receipt image file.
    func deleteReceiptImage(filename: String) {
        guard let folder = receiptsFolderURL else { return }
        let fileURL = folder.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Private

    private func savePendingExpenses(_ expenses: [PendingExpense]) {
        guard let url = pendingFileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(expenses) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
