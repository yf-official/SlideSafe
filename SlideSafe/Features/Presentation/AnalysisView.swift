import SwiftUI

struct AnalysisView: View {
    let analysis: PresentationAnalysis
    @ObservedObject var viewModel: PresentationViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                fileHeader
                overview
                reviewItems
                conversionOptions
                editabilityNotice
                actionBar
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 38)
            .padding(.vertical, 30)
        }
    }

    @ViewBuilder
    private var reviewItems: some View {
        let issues = analysis.slides.flatMap(\.issues)
        if !issues.isEmpty {
            DisclosureGroup("analysis.view_review") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(issues.prefix(20)) { issue in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("analysis.slide")
                            Text(issue.slideIndex.formatted())
                            Text("· \(issue.shapeName):")
                            Text(LocalizedStringKey(issue.reason.localizationKey))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
        }
    }

    private var fileHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(analysis.sourceURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("analysis.complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("analysis.choose_another") {
                viewModel.processAnotherFile()
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("analysis.overview")
                .font(.headline)
            HStack(spacing: 10) {
                metric("analysis.slides", value: analysis.slideCount)
                metric("analysis.text_objects", value: analysis.textObjectCount)
                metric("analysis.fonts", value: analysis.fonts.count)
                metric("analysis.needs_review", value: analysis.needsReviewCount)
            }
        }
    }

    private func metric(_ key: LocalizedStringKey, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value.formatted())
                .font(.title2.weight(.semibold))
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var conversionOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("conversion.options")
                .font(.headline)

            Picker("conversion.mode", selection: $viewModel.conversionMode) {
                ForEach(ConversionMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(spacing: 0) {
                ForEach(analysis.fonts) { font in
                    Button {
                        if viewModel.conversionMode == .selectedFonts {
                            viewModel.toggleFont(font)
                        }
                    } label: {
                        HStack {
                            if viewModel.conversionMode == .selectedFonts {
                                Image(systemName: viewModel.selectedFonts.contains(font.name) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(font.isAvailable ? Color.accentColor : .secondary)
                            }
                            Text(font.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if !font.isAvailable {
                                Text("font.unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Text(font.count.formatted())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!font.isAvailable)

                    if font.id != analysis.fonts.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var editabilityNotice: some View {
        Label("conversion.editability_notice", systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var actionBar: some View {
        HStack {
            HStack(spacing: 4) {
                Text(analysis.supportedTextCount.formatted())
                Text("analysis.supported_suffix")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("conversion.create_safe_copy") {
                viewModel.chooseOutputAndConvert()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                analysis.supportedTextCount == 0
                    || (viewModel.conversionMode == .selectedFonts && viewModel.selectedFonts.isEmpty)
            )
        }
    }
}
