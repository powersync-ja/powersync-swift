//
//  SearchScreen.swift
//  PowerSyncExample
//
//  Created by Wade Morris on 4/9/25.
//

import SwiftUI

struct SearchScreen: View {
    @Environment(SystemManager.self) private var system
    @State private var searchText: String = ""
    @State private var searchResults: [SearchResultItem] = []
    @State private var isLoading: Bool = false
    @State private var searchError: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        
        NavigationView {
            List {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let error = searchError {
                    Text("Error: \(error)")
                } else if searchText.isEmpty {
                     ContentUnavailableView("Search Lists & Todos", systemImage: "magnifyingglass")
                } else if searchResults.isEmpty && !searchText.isEmpty {
                     ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(searchResults) { item in
                        SearchResultRow(item: item)
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $searchText, prompt: "Search Lists & Todos")
            .onChange(of: searchText) { _, newValue in
                 triggerSearch(term: newValue)
            }
             .onChange(of: searchText) { _, newValue in
                 if newValue.isEmpty && !isLoading {
                     searchResults = []
                     searchError = nil
                 }
             }
        }
        .navigationViewStyle(.stack)
    }

    private func triggerSearch(term: String) {
        searchTask?.cancel()

        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTerm.isEmpty else {
            self.searchResults = []
            self.searchError = nil
            self.isLoading = false
            return
        }

        self.isLoading = false
        self.searchError = nil

        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))

                self.isLoading = true

                print("Performing search for: \(trimmedTerm)")
                let results = try await system.searchListsAndTodos(searchTerm: trimmedTerm)

                try Task.checkCancellation()

                self.searchResults = results.compactMap { item in
                    if let list = item as? ListContent {
                        return SearchResultItem(id: list.id, type: .list, content: list)
                    } else if let todo = item as? Todo {
                        return SearchResultItem(id: todo.id, type: .todo, content: todo)
                    }
                    return nil
                }
                self.searchError = nil
                print("Search completed with \(self.searchResults.count) results.")

            } catch is CancellationError {
                print("Search task cancelled.")
            } catch {
                print("Search failed: \(error.localizedDescription)")
                self.searchError = error.localizedDescription
                self.searchResults = []
            }

            self.isLoading = false
        }
    }
}

#Preview {
    SearchScreen()
        .environment(SystemManager())
}
