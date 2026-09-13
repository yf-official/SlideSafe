import Foundation

enum PPTXError: LocalizedError {
    case invalidPackage
    case commandFailed(String)
    case invalidXML(String)
    case noSlides
    case outputExists
    case cannotWriteOutput

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            return "The selected file is not a valid PowerPoint package."
        case let .commandFailed(message):
            return message
        case let .invalidXML(path):
            return "PowerPoint XML could not be read: \(path)"
        case .noSlides:
            return "The presentation contains no readable slides."
        case .outputExists:
            return "The selected output file already exists."
        case .cannotWriteOutput:
            return "The safe copy could not be written."
        }
    }
}

final class PPTXWorkspace {
    let containerURL: URL
    let packageURL: URL
    private let fileManager = FileManager.default

    init(sourceURL: URL) throws {
        let baseURL = fileManager.temporaryDirectory
            .appendingPathComponent("SlideSafe-\(UUID().uuidString)", isDirectory: true)
        let packageURL = baseURL.appendingPathComponent("Package", isDirectory: true)
        let localSource = baseURL.appendingPathComponent("Source.pptx")

        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: localSource)
        } catch {
            throw PPTXError.invalidPackage
        }

        try Self.runCommand(
            executable: "/usr/bin/unzip",
            arguments: ["-qq", localSource.path, "-d", packageURL.path]
        )

        guard fileManager.fileExists(atPath: packageURL.appendingPathComponent("[Content_Types].xml").path),
              fileManager.fileExists(atPath: packageURL.appendingPathComponent("ppt/presentation.xml").path) else {
            throw PPTXError.invalidPackage
        }

        self.containerURL = baseURL
        self.packageURL = packageURL
    }

    deinit {
        try? fileManager.removeItem(at: containerURL)
    }

    func slideURLs() throws -> [URL] {
        let presentationURL = packageURL.appendingPathComponent("ppt/presentation.xml")
        let presentationRelationshipsURL = Self.relationshipsURL(for: presentationURL)
        if let presentation = try? XMLDocument.pptxDocument(at: presentationURL),
           let relationships = try? XMLDocument.pptxDocument(at: presentationRelationshipsURL),
           let presentationRoot = presentation.rootElement(),
           let relationshipsRoot = relationships.rootElement() {
            let targetsByID = Dictionary(uniqueKeysWithValues: relationshipsRoot.childElements.compactMap { relationship -> (String, String)? in
                guard relationship.attributeValue("Type")?.hasSuffix("/slide") == true,
                      let id = relationship.attributeValue("Id"),
                      let target = relationship.attributeValue("Target") else { return nil }
                return (id, target)
            })
            let orderedURLs = presentationRoot.descendants(named: "sldId").compactMap { slideID -> URL? in
                guard let relationshipID = slideID.attribute(forName: "r:id")?.stringValue,
                      let target = targetsByID[relationshipID] else { return nil }
                return PPTXRelationship.resolvedTarget(target, from: presentationURL)
            }
            if !orderedURLs.isEmpty { return orderedURLs }
        }

        let slidesDirectory = packageURL.appendingPathComponent("ppt/slides", isDirectory: true)
        let urls = try fileManager.contentsOfDirectory(
            at: slidesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let slidePattern = try NSRegularExpression(pattern: #"^slide(\d+)\.xml$"#)
        return urls.compactMap { url -> (URL, Int)? in
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = slidePattern.firstMatch(in: name, range: range),
                  let numberRange = Range(match.range(at: 1), in: name),
                  let number = Int(name[numberRange]) else { return nil }
            return (url, number)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    private static func relationshipsURL(for partURL: URL) -> URL {
        partURL.deletingLastPathComponent()
            .appendingPathComponent("_rels", isDirectory: true)
            .appendingPathComponent(partURL.lastPathComponent + ".rels")
    }

    func createArchive(at temporaryOutputURL: URL) throws {
        if fileManager.fileExists(atPath: temporaryOutputURL.path) {
            try fileManager.removeItem(at: temporaryOutputURL)
        }

        try Self.runCommand(
            executable: "/usr/bin/zip",
            arguments: ["-q", "-r", temporaryOutputURL.path, "."],
            currentDirectory: packageURL
        )
    }

    static func copyArchive(_ archiveURL: URL, to outputURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PPTXError.outputExists
        }

        let accessed = outputURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { outputURL.stopAccessingSecurityScopedResource() }
        }

        do {
            try FileManager.default.copyItem(at: archiveURL, to: outputURL)
        } catch {
            throw PPTXError.cannotWriteOutput
        }
    }

    static func runCommand(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "PowerPoint package processing failed."
            throw PPTXError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

extension XMLDocument {
    static func pptxDocument(at url: URL) throws -> XMLDocument {
        do {
            return try XMLDocument(contentsOf: url, options: [.nodePreserveAll])
        } catch {
            throw PPTXError.invalidXML(url.lastPathComponent)
        }
    }

    func writePreservingXML(to url: URL) throws {
        try xmlData(options: []).write(to: url, options: .atomic)
    }
}

extension XMLElement {
    var pptxLocalName: String {
        if let localName, !localName.isEmpty { return localName }
        return name?.split(separator: ":").last.map(String.init) ?? ""
    }

    func directChild(named localName: String) -> XMLElement? {
        childElements.first { $0.pptxLocalName == localName }
    }

    var childElements: [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }
    }

    func descendants(named localName: String) -> [XMLElement] {
        var result: [XMLElement] = []
        for child in childElements {
            if child.pptxLocalName == localName { result.append(child) }
            result.append(contentsOf: child.descendants(named: localName))
        }
        return result
    }

    func firstDescendant(named localName: String) -> XMLElement? {
        for child in childElements {
            if child.pptxLocalName == localName { return child }
            if let match = child.firstDescendant(named: localName) { return match }
        }
        return nil
    }

    func attributeValue(_ localName: String) -> String? {
        attributes?.first(where: {
            ($0.localName ?? $0.name?.split(separator: ":").last.map(String.init)) == localName
        })?.stringValue
    }

    func setAttribute(_ name: String, value: String) {
        if let existing = attribute(forName: name) {
            existing.stringValue = value
        } else {
            addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }
    }
}

enum PPTXRelationship {
    static func resolvedTarget(_ target: String, from partURL: URL) -> URL? {
        guard let packageRoot = packageRoot(containing: partURL) else { return nil }
        let pathOnly = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
        let decoded = pathOnly.removingPercentEncoding ?? pathOnly
        let candidate: URL
        if decoded.hasPrefix("/") {
            candidate = packageRoot.appendingPathComponent(String(decoded.dropFirst()))
        } else {
            candidate = partURL.deletingLastPathComponent().appendingPathComponent(decoded)
        }
        let standardized = candidate.standardizedFileURL
        let rootPath = packageRoot.standardizedFileURL.path
        guard standardized.path == rootPath || standardized.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return standardized
    }

    private static func packageRoot(containing partURL: URL) -> URL? {
        var current = partURL.deletingLastPathComponent().standardizedFileURL
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: current.appendingPathComponent("[Content_Types].xml").path
            ) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    static func relationshipsURL(for partURL: URL) -> URL {
        partURL.deletingLastPathComponent()
            .appendingPathComponent("_rels", isDirectory: true)
            .appendingPathComponent(partURL.lastPathComponent + ".rels")
    }

    static func target(
        withTypeSuffix suffix: String,
        from partURL: URL
    ) throws -> URL? {
        let relsURL = relationshipsURL(for: partURL)
        guard FileManager.default.fileExists(atPath: relsURL.path) else { return nil }
        let document = try XMLDocument.pptxDocument(at: relsURL)
        guard let root = document.rootElement() else { return nil }

        guard let relationship = root.childElements.first(where: {
            $0.pptxLocalName == "Relationship" && ($0.attributeValue("Type")?.hasSuffix(suffix) == true)
        }), let target = relationship.attributeValue("Target") else { return nil }

        return resolvedTarget(target, from: partURL)
    }

    static func appendImageRelationships(
        to slideURL: URL,
        svgTarget: String,
        pngTarget: String
    ) throws -> (svgID: String, pngID: String) {
        let relsURL = relationshipsURL(for: slideURL)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: relsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let document: XMLDocument
        let root: XMLElement
        if fileManager.fileExists(atPath: relsURL.path) {
            document = try XMLDocument.pptxDocument(at: relsURL)
            guard let existingRoot = document.rootElement() else {
                throw PPTXError.invalidXML(relsURL.lastPathComponent)
            }
            root = existingRoot
        } else {
            root = XMLElement(name: "Relationships")
            root.addAttribute(XMLNode.attribute(
                withName: "xmlns",
                stringValue: "http://schemas.openxmlformats.org/package/2006/relationships"
            ) as! XMLNode)
            document = XMLDocument(rootElement: root)
            document.version = "1.0"
            document.characterEncoding = "UTF-8"
        }

        let usedIDs = Set(root.childElements.compactMap { $0.attributeValue("Id") })
        func nextID(startingAt start: Int) -> String {
            var number = start
            while usedIDs.contains("rId\(number)") { number += 1 }
            return "rId\(number)"
        }

        let pngID = nextID(startingAt: 1)
        var svgNumber = Int(pngID.dropFirst(3)) ?? 1
        svgNumber += 1
        var svgID = "rId\(svgNumber)"
        while usedIDs.contains(svgID) || svgID == pngID {
            svgNumber += 1
            svgID = "rId\(svgNumber)"
        }

        for (id, target) in [(pngID, pngTarget), (svgID, svgTarget)] {
            let relationship = XMLElement(name: "Relationship")
            relationship.addAttribute(XMLNode.attribute(withName: "Id", stringValue: id) as! XMLNode)
            relationship.addAttribute(XMLNode.attribute(
                withName: "Type",
                stringValue: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
            ) as! XMLNode)
            relationship.addAttribute(XMLNode.attribute(withName: "Target", stringValue: target) as! XMLNode)
            root.addChild(relationship)
        }

        try document.writePreservingXML(to: relsURL)
        return (svgID, pngID)
    }
}
