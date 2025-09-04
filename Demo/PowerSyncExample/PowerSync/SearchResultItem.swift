//
//  SearchResultItem.swift
//  PowerSyncExample
//
//  Created by Joshua Brink on 2025/09/03.
//

import Foundation

enum SearchResultType {
    case list
    case todo
}

struct SearchResultItem: Identifiable, Hashable {
    let id: String
    let type: SearchResultType
    let content: AnyHashable

    var listContent: ListContent? {
        content as? ListContent
    }

    var todo: Todo? {
        content as? Todo
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(type)
    }

    static func == (lhs: SearchResultItem, rhs: SearchResultItem) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type
    }
}
