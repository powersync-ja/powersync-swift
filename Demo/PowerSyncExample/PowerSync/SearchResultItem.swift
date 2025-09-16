import Foundation

enum SearchResultContent: Hashable {
    case list(ListContent)
    case todo(Todo)
}

struct SearchResultItem: Identifiable, Hashable {
    let id: String
    let content: SearchResultContent

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(content)
    }

    static func == (lhs: SearchResultItem, rhs: SearchResultItem) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content
    }
}
