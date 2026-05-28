//
//  AppleFoundationExtractor.swift
//  Tula
//
//  Created by Lokesh Polina on 27/05/26.
//
import Foundation
import FoundationModels

final class AppleFoundationExtractor {

    var isAvailable: Bool {

        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }

        return false
    }

    @available(iOS 26.0, *)
    func extract(from text: String) async throws -> ExpenseExtraction {

        let session = LanguageModelSession()

        let prompt = """
        Extract expense information from this text.

        Return ONLY valid JSON.

        JSON fields:
        - amount
        - merchant
        - category
        - account
        - note
        - date

        Text:
        \(text)
        """

        let response = try await session.respond(
            to: prompt
        )

        let data = Data(response.content.utf8)

        return try JSONDecoder().decode(
            ExpenseExtraction.self,
            from: data
        )
    }
}
