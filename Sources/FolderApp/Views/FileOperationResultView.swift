import SwiftUI

struct FileOperationResultView: View {
    let report: FileOperationReport
    let onReveal: (FileOperationItemResult) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if report.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("Nothing Changed")
                        .font(.headline)
                    Text("No items were processed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(report.results) { result in
                            resultRow(result)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 340)
    }

    private func resultRow(_ result: FileOperationItemResult) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: result.outcome))
                .foregroundStyle(color(for: result.outcome))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.source.lastPathComponent.isEmpty ? "File operation" : result.source.lastPathComponent)
                    .lineLimit(1)
                if let message = result.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.outcome.rawValue.capitalized)
                .font(.caption.weight(.medium))
                .frame(width: 72, alignment: .trailing)

            Button("Show in Finder") { onReveal(result) }
                .buttonStyle(.borderless)
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        report.failed.isEmpty ? "File Operation Complete" : "File Operation Finished with Issues"
    }

    private var summary: String {
        "\(report.succeeded.count) succeeded, \(report.failed.count) failed, \(report.skipped.count) skipped"
    }

    private func symbol(for outcome: FileOperationOutcome) -> String {
        switch outcome {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .skipped: return "forward.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private func color(for outcome: FileOperationOutcome) -> Color {
        switch outcome {
        case .succeeded: return .green
        case .failed: return .red
        case .skipped, .cancelled: return .orange
        }
    }
}
