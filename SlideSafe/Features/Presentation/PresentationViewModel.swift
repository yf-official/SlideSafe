import AppKit
import Foundation

@MainActor
final class PresentationViewModel: ObservableObject {
    @Published var selectedFile: URL?
    @Published var analysis: PresentationAnalysis?
    @Published var report: ConversionReport?
    @Published var progress: ProcessingProgress?
    @Published var isAnalyzing = false
    @Published var isConverting = false
    @Published var conversionMode: ConversionMode = .allText
    @Published var selectedFonts: Set<String> = []
    @Published var isErrorPresented = false
    @Published var isTechnicalDetailsPresented = false
    @Published var technicalErrorDetails = ""

    private let service = PresentationService()

    func selectFile(_ url: URL) {
        selectedFile = url
        analysis = nil
        report = nil
        progress = nil
    }

    func analyze() {
        guard let selectedFile, !isAnalyzing else { return }
        isAnalyzing = true
        progress = ProcessingProgress(stage: .extracting, currentSlide: 0, totalSlides: 0)

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { [service] in
                    try service.analyze(sourceURL: selectedFile) { update in
                        Task { @MainActor [weak self] in self?.progress = update }
                    }
                }.value
                analysis = result
                selectedFonts = Set(result.fonts.filter(\.isAvailable).map(\.name))
            } catch {
                present(error)
            }
            isAnalyzing = false
            progress = nil
        }
    }

    func chooseOutputAndConvert() {
        guard let analysis, !isConverting else { return }

        let savePanel = NSSavePanel()
        savePanel.title = localized("export.panel.title")
        savePanel.prompt = localized("export.panel.prompt")
        savePanel.allowedContentTypes = [PowerPointDocument.fileType]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.directoryURL = analysis.sourceURL.deletingLastPathComponent()
        savePanel.nameFieldStringValue = availableOutputName(for: analysis.sourceURL)

        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else { return }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            present(PPTXError.outputExists)
            return
        }
        convert(analysis: analysis, outputURL: outputURL)
    }

    func processAnotherFile() {
        selectedFile = nil
        analysis = nil
        report = nil
        progress = nil
        selectedFonts = []
        conversionMode = .allText
    }

    func openOutput() {
        guard let url = report?.outputURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealOutput() {
        guard let url = report?.outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func toggleFont(_ font: FontUsage) {
        guard font.isAvailable else { return }
        if selectedFonts.contains(font.name) {
            selectedFonts.remove(font.name)
        } else {
            selectedFonts.insert(font.name)
        }
    }

    private func convert(analysis: PresentationAnalysis, outputURL: URL) {
        isConverting = true
        progress = ProcessingProgress(stage: .extracting, currentSlide: 0, totalSlides: analysis.slideCount)
        let mode = conversionMode
        let fonts = selectedFonts

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { [service] in
                    try service.convert(
                        sourceURL: analysis.sourceURL,
                        outputURL: outputURL,
                        mode: mode,
                        selectedFonts: fonts
                    ) { update in
                        Task { @MainActor [weak self] in self?.progress = update }
                    }
                }.value
                report = result
                self.analysis = nil
            } catch {
                present(error)
            }
            isConverting = false
            progress = nil
        }
    }

    private func availableOutputName(for sourceURL: URL) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let directory = sourceURL.deletingLastPathComponent()
        var suffix = 1
        while true {
            let suffixText = suffix == 1 ? "" : " \(suffix)"
            let name = "\(baseName) - SlideSafe\(suffixText).pptx"
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                return name
            }
            suffix += 1
        }
    }

    private func present(_ error: Error) {
        technicalErrorDetails = error.localizedDescription
        isErrorPresented = true
    }

    private func localized(_ key: String) -> String {
        let rawLanguage = UserDefaults.standard.string(forKey: AppPreferenceKey.language)
            ?? AppLanguage.initial.rawValue
        let locale = Locale(identifier: rawLanguage)
        return String(localized: String.LocalizationValue(key), locale: locale)
    }
}
