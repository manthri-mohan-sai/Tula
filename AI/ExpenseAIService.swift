//
//  ExpenseAIService.swift
//  Tula
//
//  Created by Lokesh Polina on 27/05/26.
//
import Foundation

final class ExpenseAIService {

    static let shared = ExpenseAIService()

    private let appleExtractor = AppleFoundationExtractor()

    func extract(from text: String) async -> ExpenseExtraction? {

        if appleExtractor.isAvailable {

            do {
                if #available(iOS 26.0, *) {
                    return try await appleExtractor.extract(from: text)
                } else {
                    return nil
                }
            } catch {
                print(error)
            }
        }

        return nil
    }
}
