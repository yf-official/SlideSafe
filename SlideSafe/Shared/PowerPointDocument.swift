import UniformTypeIdentifiers

enum PowerPointDocument {
    static let fileType = UTType(filenameExtension: "pptx") ?? .data

    static func isSupported(_ url: URL) -> Bool {
        !url.hasDirectoryPath && url.pathExtension.lowercased() == "pptx"
    }
}
