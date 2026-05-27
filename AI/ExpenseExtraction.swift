//
//  ExpenseExtraction.swift
//  Tula
//
//  Created by Lokesh Polina on 27/05/26.
//

import Foundation

struct ExpenseExtraction: Codable {

    let amount: Double?
    let merchant: String?
    let category: String?
    let account: String?
    let note: String?
    let date: String?
}
