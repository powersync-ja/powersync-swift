import SwiftUI
import Foundation

struct ListRow: View {
  let list: ListContent

  var body: some View {
    HStack {
      Text(list.name)
      Spacer()
      .buttonStyle(.plain)
    }
  }
}


#Preview {
    ListRow(
      list: .init(
        id: UUID().uuidString.lowercased(),
        name: "name",
        createdAt: "",
        ownerId: UUID().uuidString.lowercased()
      )
    )
}
