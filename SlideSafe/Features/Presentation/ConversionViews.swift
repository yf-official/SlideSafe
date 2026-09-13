import SwiftUI

struct ProcessingView: View {
    let progress: ProcessingProgress?
    let isConversion: Bool

    var body: some View {
        VStack(spacing: 22) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 7) {
                Text(isConversion ? "progress.converting" : "progress.analyzing")
                    .font(.title3.weight(.medium))
                Text(progressText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressText: LocalizedStringKey {
        guard let progress else { return "progress.preparing" }
        switch progress.stage {
        case .extracting:
            return "progress.extracting"
        case .packaging:
            return "progress.packaging"
        case .analyzing, .outlining:
            return "progress.slide \(progress.currentSlide) \(progress.totalSlides)"
        }
    }
}

struct CompletionView: View {
    let report: ConversionReport
    @ObservedObject var viewModel: PresentationViewModel
    @State private var skippedItemsExpanded = false
    @State private var warningsExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.green)

                    VStack(spacing: 7) {
                        Text("completion.title")
                            .font(.title2.weight(.semibold))
                        Text(report.outputURL.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 10) {
                        resultMetric("completion.slides", value: report.slideCount)
                        resultMetric("completion.converted", value: report.convertedTextCount)
                        resultMetric("completion.skipped", value: report.skippedCount)
                        resultMetric("completion.warnings", value: report.warningCount)
                    }

                    if !report.skippedIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            DisclosureGroup(isExpanded: $warningsExpanded) {
                                LazyVStack(alignment: .leading, spacing: 9) {
                                    ForEach(warningGroups, id: \.reason) { group in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(.orange)
                                            Text(LocalizedStringKey(group.reason.localizationKey))
                                            Spacer()
                                            HStack(spacing: 3) {
                                                Text(group.count.formatted())
                                                Text("completion.items")
                                            }
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.top, 10)
                            } label: {
                                Label("completion.warning_details", systemImage: "exclamationmark.triangle")
                                    .font(.headline)
                            }

                            Divider()

                            DisclosureGroup(
                                "completion.view_details",
                                isExpanded: $skippedItemsExpanded
                            ) {
                                LazyVStack(alignment: .leading, spacing: 9) {
                                    ForEach(report.skippedIssues) { issue in
                                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                                            Text("completion.slide")
                                            Text(issue.slideIndex.formatted())
                                            Text("· \(issue.shapeName):")
                                            Text(LocalizedStringKey(issue.reason.localizationKey))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                    }
                                }
                                .padding(.top, 10)
                            }
                        }
                        .padding(16)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 38)
                .padding(.vertical, 30)
            }

            Divider()

            HStack(spacing: 12) {
                Button("completion.process_another") {
                    viewModel.processAnotherFile()
                }
                Spacer()
                Button("completion.show_finder") {
                    viewModel.revealOutput()
                }
                Button("completion.open") {
                    viewModel.openOutput()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 38)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var warningGroups: [(reason: OutlineSkipReason, count: Int)] {
        Dictionary(grouping: report.skippedIssues, by: \.reason)
            .map { (reason: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.reason.rawValue < $1.reason.rawValue
            }
    }

    private func resultMetric(_ key: LocalizedStringKey, value: Int) -> some View {
        VStack(spacing: 5) {
            Text(value.formatted())
                .font(.title3.weight(.semibold))
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}
