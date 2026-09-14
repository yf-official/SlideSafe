import SwiftUI

struct ImportView: View {
    @StateObject private var viewModel = PresentationViewModel()
    @State private var isFileImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isUnsupportedFileAlertPresented = false

    var body: some View {
        Group {
            if viewModel.isAnalyzing || viewModel.isConverting {
                ProcessingView(progress: viewModel.progress, isConversion: viewModel.isConverting)
            } else if let report = viewModel.report {
                CompletionView(report: report, viewModel: viewModel)
            } else if let analysis = viewModel.analysis {
                AnalysisView(analysis: analysis, viewModel: viewModel)
            } else {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        Spacer(minLength: 40)

                        VStack(spacing: 28) {
                            introduction

                            if let selectedFile = viewModel.selectedFile {
                                selectedFileCard(selectedFile)
                            } else {
                                dropZone
                            }
                        }
                        .frame(maxWidth: min(960, max(1, proxy.size.width - 80)))
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 40)

                        Spacer(minLength: 40)

                        Text("privacy.local")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("app.title")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("settings.button", systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
                .help("settings.button")
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [PowerPointDocument.fileType],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .alert("error.unsupported.title", isPresented: $isUnsupportedFileAlertPresented) {
            Button("error.dismiss", role: .cancel) { }
        } message: {
            Text("error.unsupported.message")
        }
        .alert("error.processing.title", isPresented: $viewModel.isErrorPresented) {
            Button("error.view_details") {
                viewModel.isTechnicalDetailsPresented = true
            }
            Button("error.dismiss", role: .cancel) { }
        } message: {
            Text("error.processing.message")
        }
        .sheet(isPresented: $viewModel.isTechnicalDetailsPresented) {
            VStack(alignment: .leading, spacing: 16) {
                Text("error.details.title")
                    .font(.headline)
                ScrollView {
                    Text(viewModel.technicalErrorDetails)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("error.dismiss") {
                        viewModel.isTechnicalDetailsPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 520, height: 260)
        }
    }

    private var introduction: some View {
        VStack(spacing: 8) {
            Text("import.heading")
                .font(.system(size: 26, weight: .semibold))

            Text("import.description")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)

            VStack(spacing: 5) {
                Text("import.drop.title")
                    .font(.title3.weight(.medium))

                Text("import.drop.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button("import.choose_file") {
                isFileImporterPresented = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("import.supported_format")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.07) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.28),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7, 6])
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isFileImporterPresented = true
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedFiles(urls)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("import.choose_file")
    }

    private func selectedFileCard(_ url: URL) -> some View {
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text("import.selected.title")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }

            HStack {
                Button("import.replace") {
                    isFileImporterPresented = true
                }

                Spacer()

                Button("import.continue") {
                    viewModel.analyze()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedFiles(urls)
        }
    }

    private func handleDroppedFiles(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        return selectFile(url)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        _ = selectFile(url)
    }

    @discardableResult
    private func selectFile(_ url: URL) -> Bool {
        guard PowerPointDocument.isSupported(url) else {
            isUnsupportedFileAlertPresented = true
            return false
        }

        viewModel.selectFile(url)
        return true
    }
}

#Preview {
    ImportView()
        .frame(width: 760, height: 560)
}
