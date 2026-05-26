//
//  Item.swift
//  Tula
//
//  Created by Mohan Manthri on 26/05/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
