import SwiftUI

struct FileOperationProgressView: View {
    let progress: FileOperationProgress?
    let samples: [FileOperationCoordinator.TransferProgressSample]
    let isCancellationRequested: Bool
    let onCancel: () -> Void
    let onMinimize: () -> Void
    let startedAt: Date
    let settledDragOffset: CGSize
    let onMoveFinished: (CGSize) -> Void
    @State private var showsDetails = false
    @GestureState private var liveDragTranslation = CGSize.zero

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    TransferWindowControls(onMinimize: onMinimize)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isCancellationRequested ? "Cancelling File Operation…" : "Transferring Files")
                            .font(.headline.weight(.semibold))
                        if let progress {
                            Text("\(progress.completed) of \(progress.total) items completed")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Preparing transfer…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 7) {
                        if let progress {
                            Text("\(Int((progress.fractionCompleted * 100).rounded()))%")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Color.folderAccent)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.folderAccent.opacity(0.14), in: Capsule())
                        }
                        Button("Cancel", action: onCancel)
                            .disabled(isCancellationRequested)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                if let progress {
                    VStack(alignment: .leading, spacing: 12) {
                        FileOperationProgressBar(fraction: progress.fractionCompleted)

                        HStack(spacing: 0) {
                            TransferMetric(label: "Elapsed", value: durationText(elapsed))
                            Divider().frame(height: 24).padding(.horizontal, 16)
                            TransferMetric(
                                label: "Remaining",
                                value: remainingText(for: progress, elapsed: elapsed),
                                alignment: .trailing
                            )
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                                .foregroundStyle(Color.folderAccent)
                            Text(progress.currentItem?.lastPathComponent ?? "Finalizing transfer…")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            if let rate = transferRate(for: progress, elapsed: elapsed) {
                                Text(rate)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(13)
                    .background(Color.folderSubtleFill.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsDetails.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                        Text(showsDetails ? "Hide Transfer Details" : "Show Transfer Details")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("Last 10 seconds")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(Color.folderAccent)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color.folderAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)

                if showsDetails {
                    TransferRateGraph(samples: samples, referenceDate: timeline.date)
                        .frame(height: 112)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.folderStroke.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .offset(
            x: settledDragOffset.width + liveDragTranslation.width,
            y: settledDragOffset.height + liveDragTranslation.height
        )
        // `updating` applies a lightweight transform to this view only. The
        // browser does not re-render for every pointer movement, which keeps
        // the floating window smooth even while progress data is arriving.
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .updating($liveDragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    onMoveFinished(value.translation)
                }
        )
        .transaction { $0.animation = nil }
        .accessibilityIdentifier("fileOperationProgress")
    }

    private func remainingText(for progress: FileOperationProgress, elapsed: TimeInterval) -> String {
        let fraction = progress.fractionCompleted
        guard fraction > 0, fraction < 1 else { return "Estimating time remaining…" }
        let remaining = elapsed * (1 - fraction) / fraction
        return "About \(durationText(remaining)) remaining"
    }

    private func transferRate(for progress: FileOperationProgress, elapsed: TimeInterval) -> String? {
        guard elapsed >= 1, progress.completed > 0 else { return nil }
        let rate = Double(progress.completed) / elapsed
        return String(format: "%.1f items per second", rate)
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let rounded = max(0, Int(duration.rounded()))
        if rounded < 60 { return "\(rounded)s" }
        return "\(rounded / 60)m \(rounded % 60)s"
    }
}

private struct FileOperationProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.folderStroke.opacity(0.48))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.folderAccent.opacity(0.82), Color.folderAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Transfer progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

private struct TransferMetric: View {
    let label: String
    let value: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

/// Der gelbe macOS-Fensterknopf minimiert das schwebende Transferfenster,
/// ohne die laufende Dateioperation anzutasten.
private struct TransferWindowControls: View {
    let onMinimize: () -> Void
    @State private var isHoveringMinimize = false

    var body: some View {
        Button(action: onMinimize) {
            ZStack {
                Circle().fill(Color.yellow.opacity(0.9))
                if isHoveringMinimize {
                    Image(systemName: "minus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black.opacity(0.62))
                }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help("Minimize")
        .onHover { isHoveringMinimize = $0 }
        .frame(width: 14, alignment: .leading)
        .frame(height: 14)
    }
}

/// Die minimierte Darstellung bleibt sichtbar, ohne die Dateiansicht zu
/// überdecken. Ein Klick stellt das vollständige Transferfenster wieder her.
struct MinimizedFileOperationProgressView: View {
    let progress: FileOperationProgress?
    let onRestore: () -> Void

    var body: some View {
        Button(action: onRestore) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.folderAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transferring Files")
                        .font(.caption.weight(.semibold))
                    if let progress {
                        ProgressView(value: progress.fractionCompleted)
                            .tint(Color.folderAccent)
                            .frame(width: 120)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let progress {
                    Text("\(Int((progress.fractionCompleted * 100).rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.folderStroke.opacity(0.62), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Show transfer details")
    }
}

private struct TransferRateGraph: View {
    let samples: [FileOperationCoordinator.TransferProgressSample]
    let referenceDate: Date
    private let visibleDuration: TimeInterval = 10

    private var visibleSamples: [FileOperationCoordinator.TransferProgressSample] {
        samples.filter { referenceDate.timeIntervalSince($0.timestamp) <= visibleDuration }
    }

    private var averageRate: Double {
        guard !visibleSamples.isEmpty else { return 0 }
        return visibleSamples.map(\.itemsPerSecond).reduce(0, +) / Double(visibleSamples.count)
    }

    private var maximumDeviation: Double {
        let observed = visibleSamples.map { abs($0.itemsPerSecond - averageRate) }.max() ?? 0
        // Die alte Reserve von 50 % der Durchschnittsrate hat normale
        // Änderungen fast auf die Mittellinie zusammengedrückt. Eine kleine
        // feste Reserve filtert Messrauschen; echte Schwankungen bestimmen die
        // Skala weiterhin selbst und bleiben beim Öffnen der Details sichtbar.
        return max(observed * 1.25, averageRate * 0.08, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Transfer rate")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(String(format: "Last 10s · Avg %.1f items/s", averageRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.folderSubtleFill)

                    Path { path in
                        let width = geometry.size.width
                        let height = geometry.size.height
                        for step in 1..<5 {
                            let x = width * CGFloat(step) / 5
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: height))
                        }
                    }
                    .stroke(Color.folderStroke.opacity(0.38), lineWidth: 1)

                    Path { path in
                        let middle = geometry.size.height / 2
                        path.move(to: CGPoint(x: 0, y: middle))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: middle))
                    }
                    .stroke(
                        Color.folderStroke.opacity(0.72),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )

                    Path { path in
                        guard !visibleSamples.isEmpty else { return }
                        let width = geometry.size.width
                        let height = geometry.size.height
                        let start = referenceDate.addingTimeInterval(-visibleDuration)
                        for (index, sample) in visibleSamples.enumerated() {
                            let elapsed = min(max(sample.timestamp.timeIntervalSince(start), 0), visibleDuration)
                            let x = width * CGFloat(elapsed / visibleDuration)
                            let normalizedDeviation = (sample.itemsPerSecond - averageRate) / maximumDeviation
                            let y = height / 2 - height * 0.40 * CGFloat(normalizedDeviation)
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.folderAccent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                    if visibleSamples.isEmpty {
                        Text("Collecting transfer data…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            HStack {
                Text("10 seconds ago")
                Spacer()
                Text("Now")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color.folderSubtleFill.opacity(0.74), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transfer rate graph")
    }
}

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
        .accessibilityIdentifier("fileOperationResult")
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
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if report.wasCancelled { return "File Operation Cancelled" }
        return report.failed.isEmpty ? "File Operation Complete" : "File Operation Finished with Issues"
    }

    private var summary: String {
        "\(report.succeeded.count) succeeded, \(report.failed.count) failed, \(report.skipped.count) skipped, \(report.cancelled.count) cancelled"
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
