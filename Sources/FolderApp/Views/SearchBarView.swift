//
//  SearchBarView.swift
//  Folder
//
//  Search bar with live results
//

import SwiftUI

struct SearchBarView: View {
    @ObservedObject var searchViewModel: SearchViewModel
    @ObservedObject var fileExplorerViewModel: FileExplorerViewModel
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search input bar
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search in current folder...", text: $searchViewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isSearchFieldFocused)
                    .onChange(of: searchViewModel.searchQuery) { newValue in
                        searchViewModel.search(in: fileExplorerViewModel.currentPath)
                    }

                // Reserve this space permanently so starting a search never
                // changes the search bar's layout.
                ZStack {
                    if searchViewModel.isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Searching")
                    }
                }
                .frame(width: 16, height: 16)

                if !searchViewModel.searchQuery.isEmpty {
                    Button(action: { searchViewModel.clearSearch() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button("Done") {
                    searchViewModel.deactivateSearch()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Search results
            if !searchViewModel.searchQuery.isEmpty {
                if searchViewModel.isSearching {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Searching...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchViewModel.searchResults.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.questionmark")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No results found")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Try a different search term")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Display search results
                    List(searchViewModel.searchResults) { item in
                        SearchResultRow(item: item)
                            .onTapGesture(count: 2) {
                                fileExplorerViewModel.openItem(item)
                                searchViewModel.deactivateSearch()
                            }
                    }
                    .listStyle(.plain)
                }
            } else {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Type to search")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Searches in current folder + 2 levels deep")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            isSearchFieldFocused = true
        }
    }
}

struct SearchResultRow: View {
    let item: FileSystemItem
    @StateObject private var iconService = IconService.shared

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            iconService.swiftUIIcon(for: item, size: 20)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)

            // Name and path
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Text(item.path.path)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Type indicator
            if item.type == .folder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
