//
//  SearchResultItem.swift
//  PowerSyncExample
//
//  Created by Wade Morris on 4/9/25.
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
