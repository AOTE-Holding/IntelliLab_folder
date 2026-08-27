import SwiftUI

/// Compact IntelliLab control strip for Finder-style sorting.
struct SortingToolbar: View {
    @ObservedObject var viewModel: FileExplorerViewModel
    @AppStorage("com.folder.sort-toolbar-alignment") private var alignmentRaw = ToolbarAlignment.leading.rawValue

    var body: some View {
        ZStack(alignment: toolbarAlignment) {
            // The unused part of this control strip is still part of the file
            // area. Keep it clickable so a single click clears the current
            // selection, just like clicking empty space below the grid/list.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.clearSelection()
                }

            HStack(spacing: 9) {
                sortButton(
                    title: "Name",
                    icon: "textformat",
                    option: .name
                )

                sortButton(
                    title: "Date",
                    icon: "calendar",
                    option: .dateModified
                )

                sortButton(
                    title: "Size",
                    icon: "archivebox",
                    option: .size
                )

                sortButton(
                    title: "Type",
                    icon: "doc",
                    option: .type
                )
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: toolbarAlignment)
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                alignmentRaw = ToolbarAlignment.leading.rawValue
            } label: {
                Label("Dock Left", systemImage: toolbarAlignment == .leading ? "checkmark" : "")
            }

            Button {
                alignmentRaw = ToolbarAlignment.center.rawValue
            } label: {
                Label("Dock Center", systemImage: toolbarAlignment == .center ? "checkmark" : "")
            }

            Button {
                alignmentRaw = ToolbarAlignment.trailing.rawValue
            } label: {
                Label("Dock Right", systemImage: toolbarAlignment == .trailing ? "checkmark" : "")
            }
        }
    }

    private var toolbarAlignment: Alignment {
        ToolbarAlignment(rawValue: alignmentRaw)?.alignment ?? .leading
    }

    private func sortButton(title: String, icon: String, option: ViewMode.SortOption) -> some View {
        Button(action: {
            if viewModel.viewMode.sortBy == option {
                // Same option clicked - toggle sort order
                viewModel.toggleSortOrder()
            } else {
                // Different option clicked - change sort option
                viewModel.setSortOption(option)
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))

                Text(title)
                    .font(.system(size: 12))

                // Show sort direction indicator if this is the active sort option
                if viewModel.viewMode.sortBy == option {
                    Image(systemName: viewModel.viewMode.sortOrder == .ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            // The whole visual chip is the control, including its padded area.
            // Without an explicit shape SwiftUI can restrict hit testing to the
            // glyphs/text when this toolbar is embedded in the file views.
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(viewModel.viewMode.sortBy == option ? Color.folderAccent.opacity(0.18) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .foregroundStyle(viewModel.viewMode.sortBy == option ? Color.folderAccent : .secondary)
        .buttonStyle(.plain)
        .help("Sort by \(title)")
    }

    private enum ToolbarAlignment: String {
        case leading
        case center
        case trailing

        var alignment: Alignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
    }
}
