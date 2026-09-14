import AppKit
import Foundation

final class PresentationService {
    typealias ProgressHandler = (ProcessingProgress) -> Void

    func analyze(
        sourceURL: URL,
        progress: ProgressHandler? = nil
    ) throws -> PresentationAnalysis {
        progress?(ProcessingProgress(stage: .extracting, currentSlide: 0, totalSlides: 0))
        let workspace = try PPTXWorkspace(sourceURL: sourceURL)
        let slideURLs = try workspace.slideURLs()
        guard !slideURLs.isEmpty else { throw PPTXError.noSlides }

        let theme = ThemeContext(packageURL: workspace.packageURL)
        var slideAnalyses: [SlideAnalysis] = []
        var fontCounts: [String: Int] = [:]

        for (offset, slideURL) in slideURLs.enumerated() {
            let index = offset + 1
            progress?(ProcessingProgress(stage: .analyzing, currentSlide: index, totalSlides: slideURLs.count))
            let parsed = try parseSlide(
                at: slideURL,
                index: index,
                packageURL: workspace.packageURL,
                theme: theme
            )
            let models = parsed.shapes.map(\.model) + parsed.additionalUnsupported
            for model in models {
                for name in model.textBody?.fontNames ?? [] {
                    fontCounts[name, default: 0] += 1
                }
            }
            let issues = models.compactMap { model -> OutlineIssue? in
                guard let reason = model.skipReason else { return nil }
                return OutlineIssue(slideIndex: index, shapeName: model.shapeName, reason: reason)
            }
            slideAnalyses.append(SlideAnalysis(
                index: index,
                textObjectCount: models.count,
                supportedTextCount: models.filter(\.isSupported).count,
                issues: issues
            ))
        }

        let fonts = fontCounts.map { name, count in
            FontUsage(name: name, count: count, isAvailable: FontResolver.shared.isAvailable(name))
        }.sorted {
            if $0.isAvailable != $1.isAvailable { return $0.isAvailable && !$1.isAvailable }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return PresentationAnalysis(sourceURL: sourceURL, slides: slideAnalyses, fonts: fonts)
    }

    func convert(
        sourceURL: URL,
        outputURL: URL,
        mode: ConversionMode,
        selectedFonts: Set<String>,
        progress: ProgressHandler? = nil
    ) throws -> ConversionReport {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PPTXError.outputExists
        }

        progress?(ProcessingProgress(stage: .extracting, currentSlide: 0, totalSlides: 0))
        let workspace = try PPTXWorkspace(sourceURL: sourceURL)
        let slideURLs = try workspace.slideURLs()
        guard !slideURLs.isEmpty else { throw PPTXError.noSlides }

        let theme = ThemeContext(packageURL: workspace.packageURL)
        let renderer = TextOutlineRenderer()
        let mediaDirectory = workspace.packageURL.appendingPathComponent("ppt/media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        var convertedCount = 0
        var skippedIssues: [OutlineIssue] = []

        for (offset, slideURL) in slideURLs.enumerated() {
            let slideIndex = offset + 1
            progress?(ProcessingProgress(stage: .outlining, currentSlide: slideIndex, totalSlides: slideURLs.count))
            let parsed = try parseSlide(
                at: slideURL,
                index: slideIndex,
                packageURL: workspace.packageURL,
                theme: theme
            )

            skippedIssues.append(contentsOf: parsed.additionalUnsupported.compactMap { model in
                model.skipReason.map {
                    OutlineIssue(slideIndex: slideIndex, shapeName: model.shapeName, reason: $0)
                }
            })

            var processedTableFrames: Set<ObjectIdentifier> = []
            var nextOverlayShapeID = nextAvailableShapeID(in: parsed.document)

            for parsedShape in parsed.shapes {
                if let tableCell = parsedShape.tableCell {
                    let tableKey = ObjectIdentifier(tableCell.frame)
                    guard processedTableFrames.insert(tableKey).inserted else { continue }
                    let tableShapes = parsed.shapes.filter {
                        guard let candidate = $0.tableCell else { return false }
                        return candidate.frame === tableCell.frame
                    }
                    let tableMetadata = graphicFrameNameAndID(tableCell.frame)

                    var tableMustRemainOriginal = false
                    for tableShape in tableShapes {
                        if let reason = tableShape.model.skipReason {
                            skippedIssues.append(OutlineIssue(
                                slideIndex: slideIndex,
                                shapeName: tableShape.model.shapeName,
                                reason: reason
                            ))
                            tableMustRemainOriginal = true
                        }
                    }
                    if tableMustRemainOriginal { continue }

                    let tableFonts = Set(tableShapes.flatMap {
                        $0.model.textBody?.fontNames ?? []
                    })
                    if mode == .selectedFonts {
                        guard !tableFonts.isDisjoint(with: selectedFonts) else { continue }
                        guard tableFonts.isSubset(of: selectedFonts) else {
                            skippedIssues.append(OutlineIssue(
                                slideIndex: slideIndex,
                                shapeName: tableMetadata.name,
                                reason: .unselectedMixedFonts
                            ))
                            continue
                        }
                    }

                    do {
                        guard let frameGeometry = parseGraphicFrameGeometry(from: tableCell.frame) else {
                            throw PPTXError.invalidXML(slideURL.lastPathComponent)
                        }
                        var layers: [TextOutlineCompositeLayer] = []
                        for tableShape in tableShapes {
                            guard let cell = tableShape.tableCell,
                                  let textBody = tableShape.model.textBody else { continue }
                            let renderedCell = try renderer.render(body: textBody, geometry: cell.geometry)
                            layers.append(TextOutlineCompositeLayer(
                                svgData: renderedCell.svgData,
                                xPoints: Double(cell.geometry.x - frameGeometry.x) / ShapeGeometry.emusPerPoint,
                                yPoints: Double(cell.geometry.y - frameGeometry.y) / ShapeGeometry.emusPerPoint,
                                widthPoints: cell.geometry.widthPoints,
                                heightPoints: cell.geometry.heightPoints
                            ))
                        }
                        let rendered = try renderer.renderComposite(layers: layers, geometry: frameGeometry)
                        let mediaStem = "slidesafe-s\(slideIndex)-table-\(UUID().uuidString.prefix(8))"
                        let svgName = mediaStem + ".svg"
                        let pngName = mediaStem + ".png"
                        try rendered.svgData.write(
                            to: mediaDirectory.appendingPathComponent(svgName),
                            options: .atomic
                        )
                        try rendered.pngData.write(
                            to: mediaDirectory.appendingPathComponent(pngName),
                            options: .atomic
                        )
                        let relationshipIDs = try PPTXRelationship.appendImageRelationships(
                            to: slideURL,
                            svgTarget: "../media/\(svgName)",
                            pngTarget: "../media/\(pngName)"
                        )
                        let tableModel = TextShapeModel(
                            slideIndex: slideIndex,
                            shapeID: tableMetadata.id,
                            shapeName: tableMetadata.name,
                            geometry: frameGeometry,
                            textBody: tableShapes.first?.model.textBody,
                            skipReason: nil
                        )
                        let groupShapeID = String(nextOverlayShapeID)
                        nextOverlayShapeID += 1
                        let overlayShapeID = String(nextOverlayShapeID)
                        nextOverlayShapeID += 1
                        let picture = makePictureElement(
                            from: nil,
                            model: tableModel,
                            geometry: frameGeometry,
                            svgRelationshipID: relationshipIDs.svgID,
                            pngRelationshipID: relationshipIDs.pngID,
                            pictureShapeID: overlayShapeID
                        )
                        guard let parent = tableCell.frame.parent as? XMLElement,
                              let frameIndex = parent.children?.firstIndex(where: { $0 === tableCell.frame }) else {
                            throw PPTXError.invalidXML(slideURL.lastPathComponent)
                        }
                        let group = try makeTableGroup(
                            from: tableCell.frame,
                            picture: picture,
                            geometry: frameGeometry,
                            groupShapeID: groupShapeID,
                            groupName: tableMetadata.name + " - SlideSafe"
                        )
                        parent.insertChild(group, at: frameIndex + 1)
                        tableCell.frame.detach()
                        convertedCount += 1
                    } catch {
#if DEBUG
                        fputs("SlideSafe: table rendering failed for slide \(slideIndex), table \(tableMetadata.name): \(error)\n", stderr)
#endif
                        skippedIssues.append(OutlineIssue(
                            slideIndex: slideIndex,
                            shapeName: tableMetadata.name,
                            reason: .renderingFailed
                        ))
                    }
                    continue
                }

                let model = parsedShape.model
                if let reason = model.skipReason {
                    skippedIssues.append(OutlineIssue(
                        slideIndex: slideIndex,
                        shapeName: model.shapeName,
                        reason: reason
                    ))
                    continue
                }

                guard let geometry = parsedShape.tableCell?.geometry
                        ?? parseGeometry(from: parsedShape.element)
                        ?? model.geometry,
                      let textBody = model.textBody else { continue }
                if mode == .selectedFonts {
                    let fonts = textBody.fontNames
                    guard !fonts.isDisjoint(with: selectedFonts) else { continue }
                    guard fonts.isSubset(of: selectedFonts) else {
                        skippedIssues.append(OutlineIssue(
                            slideIndex: slideIndex,
                            shapeName: model.shapeName,
                            reason: .unselectedMixedFonts
                        ))
                        continue
                    }
                }

                do {
                    let rendered = try renderer.render(body: textBody, geometry: geometry)
                    let mediaStem = "slidesafe-s\(slideIndex)-\(convertedCount + 1)-\(UUID().uuidString.prefix(8))"
                    let svgName = mediaStem + ".svg"
                    let pngName = mediaStem + ".png"
                    try rendered.svgData.write(to: mediaDirectory.appendingPathComponent(svgName), options: .atomic)
                    try rendered.pngData.write(to: mediaDirectory.appendingPathComponent(pngName), options: .atomic)

                    let relationshipIDs = try PPTXRelationship.appendImageRelationships(
                        to: slideURL,
                        svgTarget: "../media/\(svgName)",
                        pngTarget: "../media/\(pngName)"
                    )
                    let preservesOriginalShape = parsedShape.tableCell == nil
                        && shouldPreserveOriginalShape(parsedShape.element)
                    let overlayShapeID: String?
                    if preservesOriginalShape {
                        overlayShapeID = String(nextOverlayShapeID)
                        nextOverlayShapeID += 1
                    } else {
                        overlayShapeID = nil
                    }
                    let picture = makePictureElement(
                        from: parsedShape.tableCell == nil ? parsedShape.element : nil,
                        model: model,
                        geometry: geometry,
                        svgRelationshipID: relationshipIDs.svgID,
                        pngRelationshipID: relationshipIDs.pngID,
                        pictureShapeID: overlayShapeID
                    )
                    guard let parent = parsedShape.element.parent as? XMLElement,
                          let childIndex = parent.children?.firstIndex(where: { $0 === parsedShape.element }) else {
                        throw PPTXError.invalidXML(slideURL.lastPathComponent)
                    }
                    parent.insertChild(picture, at: childIndex + 1)
                    if preservesOriginalShape {
                        clearShapeText(in: parsedShape.element)
                    } else {
                        parsedShape.element.detach()
                    }
                    convertedCount += 1
                } catch {
#if DEBUG
                    fputs("SlideSafe: rendering failed for slide \(slideIndex), shape \(model.shapeName): \(error)\n", stderr)
#endif
                    skippedIssues.append(OutlineIssue(
                        slideIndex: slideIndex,
                        shapeName: model.shapeName,
                        reason: .renderingFailed
                    ))
                }
            }

            try parsed.document.writePreservingXML(to: slideURL)
        }

        if convertedCount > 0 {
            try ensureImageContentTypes(in: workspace.packageURL)
        }

        progress?(ProcessingProgress(stage: .packaging, currentSlide: slideURLs.count, totalSlides: slideURLs.count))
        let temporaryOutput = workspace.containerURL.appendingPathComponent("SlideSafe-Output.pptx")
        try workspace.createArchive(at: temporaryOutput)
        try PPTXWorkspace.copyArchive(temporaryOutput, to: outputURL)

        return ConversionReport(
            outputURL: outputURL,
            slideCount: slideURLs.count,
            convertedTextCount: convertedCount,
            skippedIssues: skippedIssues
        )
    }
}

private extension PresentationService {
    struct ParsedShape {
        let element: XMLElement
        let model: TextShapeModel
        let tableCell: TableCellContext?
    }

    struct TableCellContext {
        let cell: XMLElement
        let frame: XMLElement
        let geometry: ShapeGeometry
    }

    struct ParsedSlide {
        let document: XMLDocument
        let shapes: [ParsedShape]
        let additionalUnsupported: [TextShapeModel]
    }

    struct PlaceholderDefaults {
        var geometryByKey: [String: ShapeGeometry] = [:]
        var runSeedsByKey: [String: [Int: RunSeed]] = [:]
        var masterTitleSeeds: [Int: RunSeed] = [:]
        var masterBodySeeds: [Int: RunSeed] = [:]
        var masterOtherSeeds: [Int: RunSeed] = [:]

        func geometry(for placeholder: XMLElement?) -> ShapeGeometry? {
            guard let placeholder else { return nil }
            if let index = placeholder.attributeValue("idx"), let geometry = geometryByKey["idx:\(index)"] {
                return geometry
            }
            let type = placeholder.attributeValue("type") ?? "obj"
            return geometryByKey["type:\(type)"]
        }

        func runSeeds(for placeholder: XMLElement?) -> [Int: RunSeed] {
            let type = placeholder?.attributeValue("type") ?? "other"
            var result: [Int: RunSeed]
            switch type {
            case "title", "ctrTitle": result = masterTitleSeeds
            case "body", "obj", "subTitle": result = masterBodySeeds
            default: result = masterOtherSeeds
            }

            let specific: [Int: RunSeed]?
            if let index = placeholder?.attributeValue("idx"), let indexed = runSeedsByKey["idx:\(index)"] {
                specific = indexed
            } else {
                specific = runSeedsByKey["type:\(type)"]
            }
            for (level, seed) in specific ?? [:] {
                result[level] = (result[level] ?? RunSeed()).merging(seed)
            }
            return result
        }
    }

    struct RunSeed {
        var latinFont: String?
        var eastAsianFont: String?
        var language: String?
        var size: Double?
        var colorHex: String?
        var opacity: Double?
        var bold: Bool?
        var italic: Bool?
        var spacing: Double?
        var baseline: Double?
        var highlight: TextHighlightStyle?
        var underlineStyle: TextDecorationStyle?
        var strikethroughStyle: TextDecorationStyle?
        var gradientStops: [TextGradientStop]?
        var outline: TextOutlineStyle?
        var styleIsResolved = true

        var isEmpty: Bool {
            latinFont == nil && eastAsianFont == nil && language == nil && size == nil
                && colorHex == nil && opacity == nil && bold == nil && italic == nil
                && spacing == nil && baseline == nil && highlight == nil
                && underlineStyle == nil && strikethroughStyle == nil
                && gradientStops == nil && outline == nil
        }

        func merging(_ override: RunSeed) -> RunSeed {
            RunSeed(
                latinFont: override.latinFont ?? latinFont,
                eastAsianFont: override.eastAsianFont ?? eastAsianFont,
                language: override.language ?? language,
                size: override.size ?? size,
                colorHex: override.colorHex ?? colorHex,
                opacity: override.opacity ?? opacity,
                bold: override.bold ?? bold,
                italic: override.italic ?? italic,
                spacing: override.spacing ?? spacing,
                baseline: override.baseline ?? baseline,
                highlight: override.highlight ?? highlight,
                underlineStyle: override.underlineStyle ?? underlineStyle,
                strikethroughStyle: override.strikethroughStyle ?? strikethroughStyle,
                gradientStops: override.gradientStops ?? gradientStops,
                outline: override.outline ?? outline,
                styleIsResolved: styleIsResolved && override.styleIsResolved
            )
        }
    }

    func parseSlide(
        at slideURL: URL,
        index: Int,
        packageURL: URL,
        theme: ThemeContext
    ) throws -> ParsedSlide {
        let document = try XMLDocument.pptxDocument(at: slideURL)
        guard let root = document.rootElement(),
              let shapeTree = root.firstDescendant(named: "spTree") else {
            throw PPTXError.invalidXML(slideURL.lastPathComponent)
        }

        let slideTheme = ThemeContext.context(
            for: slideURL,
            packageURL: packageURL,
            fallback: theme
        ).applyingColorMapOverride(from: root)
        let placeholderDefaults = try loadPlaceholderDefaults(for: slideURL, theme: slideTheme)
        let advancedAnimationIDs = Set(
            root.descendants(named: "bldP").compactMap { build in
                let mode = build.attributeValue("build") ?? "p"
                return mode == "allAtOnce" ? nil : build.attributeValue("spid")
            }
        )

        var parsedShapes: [ParsedShape] = []
        var unsupported: [TextShapeModel] = []

        for child in shapeTree.childElements {
            switch child.pptxLocalName {
            case "sp":
                guard child.directChild(named: "txBody") != nil else { continue }
                let model = parseTextShape(
                    child,
                    slideIndex: index,
                    placeholderDefaults: placeholderDefaults,
                    theme: slideTheme,
                    advancedAnimationIDs: advancedAnimationIDs
                )
                if model.skipReason != .emptyText {
                    parsedShapes.append(ParsedShape(element: child, model: model, tableCell: nil))
                }
            case "grpSp":
                for groupShape in child.descendants(named: "sp") where groupShape.directChild(named: "txBody") != nil {
                    // A grouped child keeps its transform in the group's local
                    // coordinate space. Replacing that child in place preserves
                    // the parent group's scale, rotation, position, z-order, and
                    // non-text siblings (including pictures).
                    let model = parseTextShape(
                        groupShape,
                        slideIndex: index,
                        placeholderDefaults: placeholderDefaults,
                        theme: slideTheme,
                        advancedAnimationIDs: advancedAnimationIDs
                    )
                    if model.skipReason != .emptyText {
                        parsedShapes.append(ParsedShape(element: groupShape, model: model, tableCell: nil))
                    }
                }
            case "graphicFrame":
                if child.firstDescendant(named: "tbl") != nil,
                   let tableCells = parseTableCells(
                        in: child,
                        slideIndex: index,
                        theme: slideTheme,
                        advancedAnimationIDs: advancedAnimationIDs
                   ) {
                    parsedShapes.append(contentsOf: tableCells)
                } else {
                    let text = child.descendants(named: "t").compactMap(\.stringValue).joined()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let metadata = graphicFrameNameAndID(child)
                    unsupported.append(TextShapeModel(
                        slideIndex: index,
                        shapeID: metadata.id,
                        shapeName: metadata.name,
                        geometry: nil,
                        textBody: nil,
                        skipReason: .unsupportedObject
                    ))
                }
            default:
                continue
            }
        }

        return ParsedSlide(document: document, shapes: parsedShapes, additionalUnsupported: unsupported)
    }

    func parseTableCells(
        in frame: XMLElement,
        slideIndex: Int,
        theme: ThemeContext,
        advancedAnimationIDs: Set<String>
    ) -> [ParsedShape]? {
        guard let table = frame.firstDescendant(named: "tbl"),
              let frameGeometry = parseGraphicFrameGeometry(from: frame),
              frameGeometry.rotation == 0,
              !frameGeometry.flipHorizontal,
              !frameGeometry.flipVertical,
              let grid = table.directChild(named: "tblGrid") else { return nil }

        let columnWidths = grid.childElements
            .filter { $0.pptxLocalName == "gridCol" }
            .compactMap { $0.attributeValue("w").flatMap(Int64.init) }
        let rows = table.childElements.filter { $0.pptxLocalName == "tr" }
        let rowHeights = rows.compactMap { $0.attributeValue("h").flatMap(Int64.init) }
        guard !columnWidths.isEmpty, rowHeights.count == rows.count,
              columnWidths.allSatisfy({ $0 > 0 }), rowHeights.allSatisfy({ $0 > 0 }) else {
            return nil
        }

        let columnTotal = columnWidths.reduce(0, +)
        let rowTotal = rowHeights.reduce(0, +)
        guard columnTotal > 0, rowTotal > 0 else { return nil }

        let metadata = graphicFrameNameAndID(frame)
        let frameID = Int(metadata.id) ?? 0
        let tableProperties = table.directChild(named: "tblPr")
        let hasStyledFirstRow = boolean(tableProperties?.attributeValue("firstRow")) == true
        let tableStyleID = tableProperties?.directChild(named: "tableStyleId")?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let whiteHeaderStyleIDs: Set<String> = ["{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"]

        func scaledColumnOffset(_ index: Int) -> Int64 {
            let source = columnWidths.prefix(max(0, min(index, columnWidths.count))).reduce(0, +)
            return Int64((Double(source) * Double(frameGeometry.width) / Double(columnTotal)).rounded())
        }
        func scaledRowOffset(_ index: Int) -> Int64 {
            let source = rowHeights.prefix(max(0, min(index, rowHeights.count))).reduce(0, +)
            return Int64((Double(source) * Double(frameGeometry.height) / Double(rowTotal)).rounded())
        }

        var result: [ParsedShape] = []
        for (rowIndex, row) in rows.enumerated() {
            var columnIndex = 0
            for cell in row.childElements where cell.pptxLocalName == "tc" {
                let span = max(1, Int(cell.attributeValue("gridSpan") ?? "1") ?? 1)
                defer { columnIndex += span }
                guard columnIndex < columnWidths.count else { continue }
                if boolean(cell.attributeValue("hMerge")) == true
                    || boolean(cell.attributeValue("vMerge")) == true {
                    continue
                }

                let rowSpan = max(1, Int(cell.attributeValue("rowSpan") ?? "1") ?? 1)
                let lastColumn = min(columnWidths.count, columnIndex + span)
                let lastRow = min(rows.count, rowIndex + rowSpan)
                let left = scaledColumnOffset(columnIndex)
                let right = scaledColumnOffset(lastColumn)
                let top = scaledRowOffset(rowIndex)
                let bottom = scaledRowOffset(lastRow)
                guard right > left, bottom > top,
                      let textBodyElement = cell.directChild(named: "txBody") else { continue }

                var seed = RunSeed(
                    latinFont: "+mn-lt",
                    eastAsianFont: "+mn-ea",
                    size: 18,
                    colorHex: theme.textColor,
                    opacity: 1,
                    styleIsResolved: true
                )
                if rowIndex == 0, hasStyledFirstRow,
                   let tableStyleID, whiteHeaderStyleIDs.contains(tableStyleID) {
                    seed.bold = true
                    seed.colorHex = "FFFFFF"
                }

                guard let parsedBody = parseTextBody(
                    textBodyElement,
                    placeholderType: nil,
                    theme: theme,
                    inheritedSeeds: [0: seed]
                ) else { continue }
                let textBody = applyingTableCellProperties(parsedBody, from: cell)
                guard !textBody.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                let geometry = ShapeGeometry(
                    x: frameGeometry.x + left,
                    y: frameGeometry.y + top,
                    width: right - left,
                    height: bottom - top,
                    rotation: 0,
                    flipHorizontal: false,
                    flipVertical: false
                )
                let reason: OutlineSkipReason?
                if advancedAnimationIDs.contains(metadata.id) {
                    reason = .advancedAnimation
                } else if !textBody.styleIsResolved {
                    reason = .unresolvedStyle
                } else if textBody.fontNames.contains(where: { !FontResolver.shared.isAvailable($0) }) {
                    reason = .missingFont
                } else {
                    reason = nil
                }
                let pictureID = 1_000_000 + frameID * 10_000 + rowIndex * 100 + columnIndex
                let model = TextShapeModel(
                    slideIndex: slideIndex,
                    shapeID: String(pictureID),
                    shapeName: "\(metadata.name) R\(rowIndex + 1)C\(columnIndex + 1)",
                    geometry: geometry,
                    textBody: textBody,
                    skipReason: reason
                )
                result.append(ParsedShape(
                    element: cell,
                    model: model,
                    tableCell: TableCellContext(cell: cell, frame: frame, geometry: geometry)
                ))
            }
        }
        return result
    }

    func applyingTableCellProperties(_ body: TextBodyModel, from cell: XMLElement) -> TextBodyModel {
        let properties = cell.directChild(named: "tcPr")
        return TextBodyModel(
            paragraphs: body.paragraphs,
            marginLeft: emuPoints(properties?.attributeValue("marL"), defaultValue: 91_440),
            marginRight: emuPoints(properties?.attributeValue("marR"), defaultValue: 91_440),
            marginTop: emuPoints(properties?.attributeValue("marT"), defaultValue: 45_720),
            marginBottom: emuPoints(properties?.attributeValue("marB"), defaultValue: 45_720),
            verticalAnchor: properties?.attributeValue("anchor").map(verticalAnchor) ?? body.verticalAnchor,
            fontScale: body.fontScale,
            wrapsText: true,
            resizesShapeToFitText: false,
            verticalMode: properties?.attributeValue("vert").flatMap { $0 == "horz" ? nil : $0 }
                ?? body.verticalMode,
            warpPreset: body.warpPreset
        )
    }

    func parseTextShape(
        _ shape: XMLElement,
        slideIndex: Int,
        placeholderDefaults: PlaceholderDefaults,
        theme: ThemeContext,
        advancedAnimationIDs: Set<String>
    ) -> TextShapeModel {
        let metadata = shapeNameAndID(shape)
        let nonVisualProperties = shape.directChild(named: "nvSpPr")?.directChild(named: "nvPr")
        let placeholder = nonVisualProperties?.directChild(named: "ph")
        let placeholderType = placeholder?.attributeValue("type")
        let geometry = parseGeometry(from: shape)
            ?? placeholderDefaults.geometry(for: placeholder)
        let textBodyElement = shape.directChild(named: "txBody")
        let shapeStyleSeed = shapeStyleRunSeed(from: shape, theme: theme)
        let textBody = textBodyElement.flatMap {
            parseTextBody(
                $0,
                placeholderType: placeholderType,
                theme: theme,
                inheritedSeeds: placeholderDefaults.runSeeds(for: placeholder),
                shapeStyleSeed: shapeStyleSeed
            )
        }

        let reason: OutlineSkipReason?
        if textBody?.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            reason = .emptyText
        } else if geometry == nil {
            reason = .missingGeometry
        } else if advancedAnimationIDs.contains(metadata.id) {
            reason = .advancedAnimation
        } else if textBody?.styleIsResolved == false {
            reason = .unresolvedStyle
        } else if textBody?.fontNames.contains(where: { !FontResolver.shared.isAvailable($0) }) == true {
            reason = .missingFont
        } else {
            reason = nil
        }

        return TextShapeModel(
            slideIndex: slideIndex,
            shapeID: metadata.id,
            shapeName: metadata.name,
            geometry: geometry,
            textBody: textBody,
            skipReason: reason
        )
    }

    func parseTextBody(
        _ textBody: XMLElement,
        placeholderType: String?,
        theme: ThemeContext,
        inheritedSeeds: [Int: RunSeed],
        shapeStyleSeed: RunSeed = RunSeed()
    ) -> TextBodyModel? {
        let bodyProperties = textBody.directChild(named: "bodyPr")
        let listStyle = textBody.directChild(named: "lstStyle")
        let defaultFontSize: Double
        switch placeholderType {
        case "title", "ctrTitle": defaultFontSize = 44
        case "subTitle": defaultFontSize = 32
        default: defaultFontSize = 18
        }

        var paragraphs: [TextParagraphModel] = []
        for paragraph in textBody.childElements where paragraph.pptxLocalName == "p" {
            let paragraphProperties = paragraph.directChild(named: "pPr")
            let level = Int(paragraphProperties?.attributeValue("lvl") ?? "0") ?? 0
            let levelProperties = listStyle?.directChild(named: "lvl\(min(9, level + 1))pPr")
            let inheritedSeed = inheritedSeeds[level] ?? inheritedSeeds[0] ?? RunSeed()
            let listSeed = levelProperties?.directChild(named: "defRPr").map { runSeed(from: $0, theme: theme) } ?? RunSeed()
            let paragraphSeed = paragraphProperties?.directChild(named: "defRPr").map { runSeed(from: $0, theme: theme) } ?? RunSeed()
            // endParaRPr formats the paragraph mark/newly inserted text. It must not
            // override the formatting of existing runs.
            let effectiveSeed = inheritedSeed.merging(shapeStyleSeed).merging(listSeed).merging(paragraphSeed)

            var runs: [TextRunModel] = []
            for child in paragraph.childElements {
                if child.pptxLocalName == "r" || child.pptxLocalName == "fld" {
                    guard let text = child.directChild(named: "t")?.stringValue, !text.isEmpty else { continue }
                    let explicitSeed = child.directChild(named: "rPr").map { runSeed(from: $0, theme: theme) } ?? RunSeed()
                    let seed = effectiveSeed.merging(explicitSeed)
                    for segment in splitByScript(text) {
                        let font = theme.resolveFont(
                            segment.isEastAsian ? seed.eastAsianFont : seed.latinFont,
                            eastAsian: segment.isEastAsian,
                            language: seed.language,
                            text: segment.text
                        )
                        runs.append(TextRunModel(
                            text: segment.text,
                            fontName: font.name,
                            fontSize: seed.size ?? defaultFontSize,
                            colorHex: seed.colorHex ?? theme.textColor,
                            opacity: seed.opacity ?? 1,
                            isBold: seed.bold ?? false,
                            isItalic: seed.italic ?? false,
                            kerning: seed.spacing ?? 0,
                            baseline: seed.baseline ?? 0,
                            highlight: seed.highlight,
                            underlineStyle: seed.underlineStyle ?? .none,
                            strikethroughStyle: seed.strikethroughStyle ?? .none,
                            gradientStops: seed.gradientStops ?? [],
                            outline: seed.outline,
                            styleIsResolved: font.isExact && seed.styleIsResolved
                        ))
                    }
                } else if child.pptxLocalName == "br" {
                    let seed = effectiveSeed
                    runs.append(TextRunModel(
                        text: "\n",
                        fontName: theme.resolveFont(
                            seed.latinFont,
                            eastAsian: false,
                            language: seed.language,
                            text: "\n"
                        ).name,
                        fontSize: seed.size ?? defaultFontSize,
                        colorHex: seed.colorHex ?? theme.textColor,
                        opacity: seed.opacity ?? 1,
                        isBold: seed.bold ?? false,
                        isItalic: seed.italic ?? false,
                        kerning: seed.spacing ?? 0,
                        baseline: seed.baseline ?? 0,
                        highlight: seed.highlight,
                        underlineStyle: seed.underlineStyle ?? .none,
                        strikethroughStyle: seed.strikethroughStyle ?? .none,
                        gradientStops: seed.gradientStops ?? [],
                        outline: seed.outline,
                        styleIsResolved: true
                    ))
                }
            }

            guard !runs.isEmpty else { continue }
            let alignmentSource = paragraphProperties?.attributeValue("algn")
                ?? levelProperties?.attributeValue("algn")
            let alignment: TextParagraphModel.Alignment
            switch alignmentSource {
            case "ctr": alignment = .center
            case "r": alignment = .right
            case "just", "justLow", "dist", "thaiDist": alignment = .justified
            default: alignment = .left
            }

            let bullet: String?
            if paragraphProperties?.directChild(named: "buNone") != nil {
                bullet = nil
            } else {
                bullet = paragraphProperties?.directChild(named: "buChar")?.attributeValue("char")
                    ?? levelProperties?.directChild(named: "buChar")?.attributeValue("char")
            }

            paragraphs.append(TextParagraphModel(
                runs: runs,
                alignment: alignment,
                level: level,
                lineSpacingMultiple: spacingMultiple(
                    paragraphProperties?.directChild(named: "lnSpc")
                        ?? levelProperties?.directChild(named: "lnSpc")
                ),
                spaceBefore: pointSpacing(
                    paragraphProperties?.directChild(named: "spcBef")
                        ?? levelProperties?.directChild(named: "spcBef")
                ),
                spaceAfter: pointSpacing(
                    paragraphProperties?.directChild(named: "spcAft")
                        ?? levelProperties?.directChild(named: "spcAft")
                ),
                bullet: bullet
            ))
        }

        guard !paragraphs.isEmpty else { return nil }
        let fontScale = Double(bodyProperties?.directChild(named: "normAutofit")?.attributeValue("fontScale") ?? "100000") ?? 100_000
        return TextBodyModel(
            paragraphs: paragraphs,
            marginLeft: emuPoints(bodyProperties?.attributeValue("lIns"), defaultValue: 91_440),
            marginRight: emuPoints(bodyProperties?.attributeValue("rIns"), defaultValue: 91_440),
            marginTop: emuPoints(bodyProperties?.attributeValue("tIns"), defaultValue: 45_720),
            marginBottom: emuPoints(bodyProperties?.attributeValue("bIns"), defaultValue: 45_720),
            verticalAnchor: verticalAnchor(bodyProperties?.attributeValue("anchor")),
            fontScale: max(0.01, fontScale / 100_000),
            wrapsText: bodyProperties?.attributeValue("wrap") != "none",
            resizesShapeToFitText: bodyProperties?.directChild(named: "spAutoFit") != nil,
            verticalMode: bodyProperties?.attributeValue("vert").flatMap { $0 == "horz" ? nil : $0 },
            warpPreset: bodyProperties?.directChild(named: "prstTxWarp")?.attributeValue("prst")
        )
    }

    func runSeed(from properties: XMLElement, theme: ThemeContext) -> RunSeed {
        let latin = properties.directChild(named: "latin")?.attributeValue("typeface")
        let eastAsian = properties.directChild(named: "ea")?.attributeValue("typeface")
        let size = properties.attributeValue("sz").flatMap(Double.init).map { $0 / 100 }
        let spacing = properties.attributeValue("spc").flatMap(Double.init).map { $0 / 100 }
        let baseline = properties.attributeValue("baseline").flatMap(Double.init).map { $0 / 100_000 }
        let color = theme.color(from: properties.directChild(named: "solidFill"))
        let gradientStops = properties.directChild(named: "gradFill")?
            .directChild(named: "gsLst")?
            .childElements
            .compactMap { stop -> TextGradientStop? in
                guard stop.pptxLocalName == "gs",
                      let color = theme.color(fromColorChoice: stop.childElements.first) else { return nil }
                let position = (Double(stop.attributeValue("pos") ?? "0") ?? 0) / 100_000
                return TextGradientStop(position: position, colorHex: color.hex, opacity: color.opacity)
            }
        let outline: TextOutlineStyle? = {
            guard let line = properties.directChild(named: "ln"),
                  line.directChild(named: "noFill") == nil,
                  let color = theme.color(from: line.directChild(named: "solidFill")) else { return nil }
            let width = Double(line.attributeValue("w") ?? "0") ?? 0
            guard width > 0 else { return nil }
            return TextOutlineStyle(
                colorHex: color.hex,
                opacity: color.opacity,
                width: width / ShapeGeometry.emusPerPoint
            )
        }()
        let hasExplicitColor = properties.directChild(named: "solidFill") != nil
            || properties.directChild(named: "gradFill") != nil
        let highlightElement = properties.directChild(named: "highlight")
        let highlightColor = theme.color(fromColorChoice: highlightElement?.childElements.first)
        let highlight = highlightColor.map {
            TextHighlightStyle(colorHex: $0.hex, opacity: $0.opacity)
        }
        let underlineValue = properties.attributeValue("u")
        let underlineStyle: TextDecorationStyle? = underlineValue.map {
            switch $0 {
            case "none": return .none
            case "dbl", "wavyDbl": return .double
            default: return .single
            }
        }
        let strikeValue = properties.attributeValue("strike")
        let strikethroughStyle: TextDecorationStyle? = strikeValue.map {
            switch $0 {
            case "noStrike", "none": return .none
            case "dblStrike": return .double
            default: return .single
            }
        }
        return RunSeed(
            latinFont: latin,
            eastAsianFont: eastAsian,
            language: properties.attributeValue("lang"),
            size: size,
            colorHex: color?.hex,
            opacity: color?.opacity,
            bold: boolean(properties.attributeValue("b")),
            italic: boolean(properties.attributeValue("i")),
            spacing: spacing,
            baseline: baseline,
            highlight: highlight,
            underlineStyle: underlineStyle,
            strikethroughStyle: strikethroughStyle,
            gradientStops: gradientStops?.isEmpty == false ? gradientStops : nil,
            outline: outline,
            styleIsResolved: (!hasExplicitColor || color != nil || gradientStops?.isEmpty == false)
                && (highlightElement == nil || highlight != nil)
        )
    }

    func loadPlaceholderDefaults(for slideURL: URL, theme: ThemeContext) throws -> PlaceholderDefaults {
        var result = PlaceholderDefaults()
        guard let layoutURL = try PPTXRelationship.target(withTypeSuffix: "/slideLayout", from: slideURL),
              FileManager.default.fileExists(atPath: layoutURL.path) else { return result }

        if let masterURL = try PPTXRelationship.target(withTypeSuffix: "/slideMaster", from: layoutURL),
           FileManager.default.fileExists(atPath: masterURL.path) {
            try collectPlaceholderDefaults(from: masterURL, into: &result, theme: theme, includeMasterTextStyles: true)
        }
        try collectPlaceholderDefaults(from: layoutURL, into: &result, theme: theme, includeMasterTextStyles: false)
        return result
    }

    func collectPlaceholderDefaults(
        from url: URL,
        into result: inout PlaceholderDefaults,
        theme: ThemeContext,
        includeMasterTextStyles: Bool
    ) throws {
        let document = try XMLDocument.pptxDocument(at: url)
        guard let root = document.rootElement(), let shapeTree = root.firstDescendant(named: "spTree") else { return }

        if includeMasterTextStyles, let textStyles = root.firstDescendant(named: "txStyles") {
            result.masterTitleSeeds = parseLevelSeeds(from: textStyles.directChild(named: "titleStyle"), theme: theme)
            result.masterBodySeeds = parseLevelSeeds(from: textStyles.directChild(named: "bodyStyle"), theme: theme)
            result.masterOtherSeeds = parseLevelSeeds(from: textStyles.directChild(named: "otherStyle"), theme: theme)
        }

        for shape in shapeTree.childElements where shape.pptxLocalName == "sp" {
            guard let placeholder = shape.directChild(named: "nvSpPr")?
                .directChild(named: "nvPr")?
                .directChild(named: "ph") else { continue }
            let keys: [String] = [
                placeholder.attributeValue("idx").map { "idx:\($0)" },
                "type:\(placeholder.attributeValue("type") ?? "obj")"
            ].compactMap { $0 }

            if let geometry = parseGeometry(from: shape) {
                for key in keys { result.geometryByKey[key] = geometry }
            }
            let seeds = parseLevelSeeds(
                from: shape.directChild(named: "txBody")?.directChild(named: "lstStyle"),
                theme: theme
            )
            for key in keys where !seeds.isEmpty {
                var existing = result.runSeedsByKey[key] ?? [:]
                for (level, seed) in seeds {
                    existing[level] = (existing[level] ?? RunSeed()).merging(seed)
                }
                result.runSeedsByKey[key] = existing
            }

            let styleSeed = shapeStyleRunSeed(from: shape, theme: theme)
            if !styleSeed.isEmpty {
                for key in keys {
                    var existing = result.runSeedsByKey[key] ?? [:]
                    for level in 0..<9 {
                        existing[level] = styleSeed.merging(existing[level] ?? RunSeed())
                    }
                    result.runSeedsByKey[key] = existing
                }
            }
        }
    }

    func shapeStyleRunSeed(from shape: XMLElement, theme: ThemeContext) -> RunSeed {
        guard let fontReference = shape.directChild(named: "style")?.directChild(named: "fontRef") else {
            return RunSeed()
        }

        let color = theme.color(fromColorChoice: fontReference.childElements.first)
        let index = fontReference.attributeValue("idx")
        let latinFont: String?
        let eastAsianFont: String?
        switch index {
        case "major":
            latinFont = "+mj-lt"
            eastAsianFont = "+mj-ea"
        case "minor":
            latinFont = "+mn-lt"
            eastAsianFont = "+mn-ea"
        default:
            latinFont = nil
            eastAsianFont = nil
        }
        return RunSeed(
            latinFont: latinFont,
            eastAsianFont: eastAsianFont,
            colorHex: color?.hex,
            opacity: color?.opacity,
            styleIsResolved: fontReference.childElements.first != nil && color != nil
        )
    }

    func parseLevelSeeds(from container: XMLElement?, theme: ThemeContext) -> [Int: RunSeed] {
        guard let container else { return [:] }
        var seeds: [Int: RunSeed] = [:]
        for level in 0..<9 {
            guard let properties = container.directChild(named: "lvl\(level + 1)pPr"),
                  let runProperties = properties.directChild(named: "defRPr") else { continue }
            seeds[level] = runSeed(from: runProperties, theme: theme)
        }
        return seeds
    }

    func parseGeometry(from shape: XMLElement) -> ShapeGeometry? {
        guard let transform = shape.directChild(named: "spPr")?.directChild(named: "xfrm"),
              let offset = transform.directChild(named: "off"),
              let extent = transform.directChild(named: "ext"),
              let x = offset.attributeValue("x").flatMap(Int64.init),
              let y = offset.attributeValue("y").flatMap(Int64.init),
              let width = extent.attributeValue("cx").flatMap(Int64.init),
              let height = extent.attributeValue("cy").flatMap(Int64.init),
              width > 0, height > 0 else { return nil }

        return ShapeGeometry(
            x: x,
            y: y,
            width: width,
            height: height,
            rotation: Int32(transform.attributeValue("rot") ?? "0") ?? 0,
            flipHorizontal: boolean(transform.attributeValue("flipH")) ?? false,
            flipVertical: boolean(transform.attributeValue("flipV")) ?? false
        )
    }

    func parseGraphicFrameGeometry(from frame: XMLElement) -> ShapeGeometry? {
        guard let transform = frame.directChild(named: "xfrm"),
              let offset = transform.directChild(named: "off"),
              let extent = transform.directChild(named: "ext"),
              let x = offset.attributeValue("x").flatMap(Int64.init),
              let y = offset.attributeValue("y").flatMap(Int64.init),
              let width = extent.attributeValue("cx").flatMap(Int64.init),
              let height = extent.attributeValue("cy").flatMap(Int64.init),
              width > 0, height > 0 else { return nil }
        return ShapeGeometry(
            x: x,
            y: y,
            width: width,
            height: height,
            rotation: Int32(transform.attributeValue("rot") ?? "0") ?? 0,
            flipHorizontal: boolean(transform.attributeValue("flipH")) ?? false,
            flipVertical: boolean(transform.attributeValue("flipV")) ?? false
        )
    }

    func clearTableCellText(in tableCell: XMLElement) {
        guard let textBody = tableCell.directChild(named: "txBody") else { return }
        for paragraph in textBody.childElements where paragraph.pptxLocalName == "p" {
            paragraph.detach()
        }
        textBody.addChild(XMLElement(name: "a:p"))
    }

    func makeTableGroup(
        from frame: XMLElement,
        picture: XMLElement,
        geometry: ShapeGeometry,
        groupShapeID: String,
        groupName: String
    ) throws -> XMLElement {
        guard let clearedFrame = frame.copy() as? XMLElement else {
            throw PPTXError.invalidXML("table")
        }
        for cell in clearedFrame.descendants(named: "tc") {
            clearTableCellText(in: cell)
        }

        let group = XMLElement(name: "p:grpSp")
        group.setAttribute(
            "xmlns:a",
            value: "http://schemas.openxmlformats.org/drawingml/2006/main"
        )
        group.setAttribute(
            "xmlns:r",
            value: "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        )

        let nonVisual = XMLElement(name: "p:nvGrpSpPr")
        let coreProperties = XMLElement(name: "p:cNvPr")
        coreProperties.setAttribute("id", value: groupShapeID)
        coreProperties.setAttribute("name", value: groupName)
        nonVisual.addChild(coreProperties)
        nonVisual.addChild(XMLElement(name: "p:cNvGrpSpPr"))
        nonVisual.addChild(XMLElement(name: "p:nvPr"))
        group.addChild(nonVisual)

        let groupProperties = XMLElement(name: "p:grpSpPr")
        let transform = XMLElement(name: "a:xfrm")
        if geometry.rotation != 0 { transform.setAttribute("rot", value: String(geometry.rotation)) }
        if geometry.flipHorizontal { transform.setAttribute("flipH", value: "1") }
        if geometry.flipVertical { transform.setAttribute("flipV", value: "1") }
        for (name, x, y) in [
            ("a:off", geometry.x, geometry.y),
            ("a:ext", geometry.width, geometry.height),
            ("a:chOff", geometry.x, geometry.y),
            ("a:chExt", geometry.width, geometry.height)
        ] {
            let element = XMLElement(name: name)
            if name == "a:off" || name == "a:chOff" {
                element.setAttribute("x", value: String(x))
                element.setAttribute("y", value: String(y))
            } else {
                element.setAttribute("cx", value: String(x))
                element.setAttribute("cy", value: String(y))
            }
            transform.addChild(element)
        }
        groupProperties.addChild(transform)
        group.addChild(groupProperties)
        group.addChild(clearedFrame)
        group.addChild(picture)
        return group
    }

    func clearShapeText(in shape: XMLElement) {
        shape.directChild(named: "txBody")?.detach()
    }

    func shouldPreserveOriginalShape(_ shape: XMLElement) -> Bool {
        let textBoxValue = shape.directChild(named: "nvSpPr")?
            .directChild(named: "cNvSpPr")?
            .attributeValue("txBox")
        if textBoxValue != "1" { return true }
        return hasUnsupportedShapeStyle(shape) || shape.directChild(named: "style") != nil
    }

    func nextAvailableShapeID(in document: XMLDocument) -> Int {
        let used = document.rootElement()?
            .descendants(named: "cNvPr")
            .compactMap { $0.attributeValue("id").flatMap(Int.init) }
            ?? []
        return (used.max() ?? 0) + 1
    }

    func normalizeGroupCoordinates(in container: XMLElement) {
        for group in container.childElements where group.pptxLocalName == "grpSp" {
            normalizeGroupCoordinates(group)
            normalizeGroupCoordinates(in: group)
        }
    }

    func normalizeGroupCoordinates(_ group: XMLElement) {
        guard let transform = group.directChild(named: "grpSpPr")?.directChild(named: "xfrm"),
              let offset = transform.directChild(named: "off"),
              let extent = transform.directChild(named: "ext"),
              let childOffset = transform.directChild(named: "chOff"),
              let childExtent = transform.directChild(named: "chExt"),
              let groupX = offset.attributeValue("x").flatMap(Int64.init),
              let groupY = offset.attributeValue("y").flatMap(Int64.init),
              let groupWidth = extent.attributeValue("cx").flatMap(Int64.init),
              let groupHeight = extent.attributeValue("cy").flatMap(Int64.init),
              let childX = childOffset.attributeValue("x").flatMap(Int64.init),
              let childY = childOffset.attributeValue("y").flatMap(Int64.init),
              let childWidth = childExtent.attributeValue("cx").flatMap(Int64.init),
              let childHeight = childExtent.attributeValue("cy").flatMap(Int64.init),
              groupWidth > 0, groupHeight > 0, childWidth > 0, childHeight > 0 else {
            return
        }

        guard groupX != childX || groupY != childY
                || groupWidth != childWidth || groupHeight != childHeight else {
            return
        }

        let graphicalChildren = group.childElements.filter {
            !["nvGrpSpPr", "grpSpPr"].contains($0.pptxLocalName)
        }
        let childTransforms = graphicalChildren.compactMap(groupChildTransform)
        guard childTransforms.count == graphicalChildren.count else { return }

        let childGeometry = childTransforms.compactMap { childTransform -> (
            offset: XMLElement,
            extent: XMLElement,
            x: Int64,
            y: Int64,
            width: Int64,
            height: Int64
        )? in
            guard let itemOffset = childTransform.directChild(named: "off"),
                  let itemExtent = childTransform.directChild(named: "ext"),
                  let itemX = itemOffset.attributeValue("x").flatMap(Int64.init),
                  let itemY = itemOffset.attributeValue("y").flatMap(Int64.init),
                  let itemWidth = itemExtent.attributeValue("cx").flatMap(Int64.init),
                  let itemHeight = itemExtent.attributeValue("cy").flatMap(Int64.init) else {
                return nil
            }
            return (itemOffset, itemExtent, itemX, itemY, itemWidth, itemHeight)
        }
        guard childGeometry.count == childTransforms.count else { return }

        let scaleX = Double(groupWidth) / Double(childWidth)
        let scaleY = Double(groupHeight) / Double(childHeight)

        for item in childGeometry {
            item.offset.setAttribute(
                "x",
                value: String(groupX + scaled(item.x - childX, by: scaleX))
            )
            item.offset.setAttribute(
                "y",
                value: String(groupY + scaled(item.y - childY, by: scaleY))
            )
            item.extent.setAttribute("cx", value: String(scaled(item.width, by: scaleX)))
            item.extent.setAttribute("cy", value: String(scaled(item.height, by: scaleY)))
        }

        childOffset.setAttribute("x", value: String(groupX))
        childOffset.setAttribute("y", value: String(groupY))
        childExtent.setAttribute("cx", value: String(groupWidth))
        childExtent.setAttribute("cy", value: String(groupHeight))
    }

    func groupChildTransform(_ child: XMLElement) -> XMLElement? {
        switch child.pptxLocalName {
        case "sp", "pic", "cxnSp":
            return child.directChild(named: "spPr")?.directChild(named: "xfrm")
        case "grpSp":
            return child.directChild(named: "grpSpPr")?.directChild(named: "xfrm")
        case "graphicFrame":
            return child.directChild(named: "xfrm")
        default:
            return nil
        }
    }

    func scaled(_ value: Int64, by scale: Double) -> Int64 {
        Int64((Double(value) * scale).rounded())
    }

    func hasUnsupportedShapeStyle(_ shape: XMLElement) -> Bool {
        guard let properties = shape.directChild(named: "spPr") else { return false }
        let fillNames = ["solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]
        if properties.childElements.contains(where: { fillNames.contains($0.pptxLocalName) }) { return true }
        if let line = properties.directChild(named: "ln"), line.directChild(named: "noFill") == nil,
           !line.childElements.isEmpty { return true }
        if let effects = properties.directChild(named: "effectLst"), !effects.childElements.isEmpty { return true }
        return properties.directChild(named: "effectDag") != nil
    }

    func shapeNameAndID(_ shape: XMLElement) -> (name: String, id: String) {
        let properties = shape.directChild(named: "nvSpPr")?.directChild(named: "cNvPr")
        return (
            properties?.attributeValue("name") ?? "Text",
            properties?.attributeValue("id") ?? UUID().uuidString
        )
    }

    func graphicFrameNameAndID(_ frame: XMLElement) -> (name: String, id: String) {
        let properties = frame.directChild(named: "nvGraphicFramePr")?.directChild(named: "cNvPr")
        return (
            properties?.attributeValue("name") ?? "Graphic",
            properties?.attributeValue("id") ?? UUID().uuidString
        )
    }

    func makePictureElement(
        from originalShape: XMLElement?,
        model: TextShapeModel,
        geometry: ShapeGeometry,
        svgRelationshipID: String,
        pngRelationshipID: String,
        pictureShapeID: String? = nil
    ) -> XMLElement {
        let picture = XMLElement(name: "p:pic")
        // Slide roots produced by several PPTX writers declare only the `p`
        // namespace. Every generated picture uses DrawingML (`a`) and package
        // relationships (`r`), so declare both on the inserted subtree. An
        // undeclared prefix is tolerated by FoundationXML but PowerPoint repairs
        // the slide by deleting the invalid picture nodes.
        picture.setAttribute("xmlns:a", value: "http://schemas.openxmlformats.org/drawingml/2006/main")
        picture.setAttribute("xmlns:r", value: "http://schemas.openxmlformats.org/officeDocument/2006/relationships")

        let nonVisual = XMLElement(name: "p:nvPicPr")
        let coreProperties = XMLElement(name: "p:cNvPr")
        coreProperties.setAttribute("id", value: pictureShapeID ?? model.shapeID)
        coreProperties.setAttribute("name", value: model.shapeName + " - SlideSafe")
        nonVisual.addChild(coreProperties)
        let pictureProperties = XMLElement(name: "p:cNvPicPr")
        let locks = XMLElement(name: "a:picLocks")
        locks.setAttribute("noChangeAspect", value: "0")
        pictureProperties.addChild(locks)
        nonVisual.addChild(pictureProperties)
        nonVisual.addChild(XMLElement(name: "p:nvPr"))
        picture.addChild(nonVisual)

        let blipFill = XMLElement(name: "p:blipFill")
        let blip = XMLElement(name: "a:blip")
        blip.setAttribute("r:embed", value: pngRelationshipID)
        let extensionList = XMLElement(name: "a:extLst")
        let extensionElement = XMLElement(name: "a:ext")
        extensionElement.setAttribute("uri", value: "{96DAC541-7B7A-43D3-8B79-37D633B846F1}")
        let svgBlip = XMLElement(name: "asvg:svgBlip")
        svgBlip.setAttribute("xmlns:asvg", value: "http://schemas.microsoft.com/office/drawing/2016/SVG/main")
        svgBlip.setAttribute("r:embed", value: svgRelationshipID)
        extensionElement.addChild(svgBlip)
        extensionList.addChild(extensionElement)
        blip.addChild(extensionList)
        blipFill.addChild(blip)
        let stretch = XMLElement(name: "a:stretch")
        stretch.addChild(XMLElement(name: "a:fillRect"))
        blipFill.addChild(stretch)
        picture.addChild(blipFill)

        let shapeProperties = XMLElement(name: "p:spPr")
        let transform: XMLElement
        if let existing = originalShape?.directChild(named: "spPr")?.directChild(named: "xfrm")?.copy() as? XMLElement {
            transform = existing
        } else {
            transform = XMLElement(name: "a:xfrm")
            if geometry.rotation != 0 { transform.setAttribute("rot", value: String(geometry.rotation)) }
            if geometry.flipHorizontal { transform.setAttribute("flipH", value: "1") }
            if geometry.flipVertical { transform.setAttribute("flipV", value: "1") }
            let offset = XMLElement(name: "a:off")
            offset.setAttribute("x", value: String(geometry.x))
            offset.setAttribute("y", value: String(geometry.y))
            let extent = XMLElement(name: "a:ext")
            extent.setAttribute("cx", value: String(geometry.width))
            extent.setAttribute("cy", value: String(geometry.height))
            transform.addChild(offset)
            transform.addChild(extent)
        }
        if let offset = transform.directChild(named: "off"),
           let extent = transform.directChild(named: "ext") {
            offset.setAttribute("x", value: String(geometry.x))
            offset.setAttribute("y", value: String(geometry.y))
            extent.setAttribute("cx", value: String(geometry.width))
            extent.setAttribute("cy", value: String(geometry.height))
        }
        shapeProperties.addChild(transform)
        let geometryElement = XMLElement(name: "a:prstGeom")
        geometryElement.setAttribute("prst", value: "rect")
        geometryElement.addChild(XMLElement(name: "a:avLst"))
        shapeProperties.addChild(geometryElement)
        shapeProperties.addChild(XMLElement(name: "a:noFill"))
        let line = XMLElement(name: "a:ln")
        line.addChild(XMLElement(name: "a:noFill"))
        shapeProperties.addChild(line)
        picture.addChild(shapeProperties)
        return picture
    }

    func ensureImageContentTypes(in packageURL: URL) throws {
        let url = packageURL.appendingPathComponent("[Content_Types].xml")
        let document = try XMLDocument.pptxDocument(at: url)
        guard let root = document.rootElement() else { throw PPTXError.invalidXML(url.lastPathComponent) }
        let existingExtensions = Set(root.childElements.compactMap { element -> String? in
            guard element.pptxLocalName == "Default" else { return nil }
            return element.attributeValue("Extension")?.lowercased()
        })

        for (fileExtension, contentType) in [("svg", "image/svg+xml"), ("png", "image/png")]
            where !existingExtensions.contains(fileExtension) {
            let element = XMLElement(name: "Default")
            element.setAttribute("Extension", value: fileExtension)
            element.setAttribute("ContentType", value: contentType)
            root.addChild(element)
        }
        try document.writePreservingXML(to: url)
    }

    func splitByScript(_ text: String) -> [(text: String, isEastAsian: Bool)] {
        var result: [(String, Bool)] = []
        for character in text {
            let eastAsian = character.unicodeScalars.contains { scalar in
                let value = scalar.value
                return (0x2E80...0x9FFF).contains(value)
                    || (0xAC00...0xD7AF).contains(value)
                    || (0x3040...0x30FF).contains(value)
                    || (0xF900...0xFAFF).contains(value)
            }
            if let last = result.last, last.1 == eastAsian {
                result[result.count - 1].0.append(character)
            } else {
                result.append((String(character), eastAsian))
            }
        }
        return result
    }

    func spacingMultiple(_ element: XMLElement?) -> Double? {
        guard let element else { return nil }
        if let percent = element.directChild(named: "spcPct")?.attributeValue("val").flatMap(Double.init) {
            return percent / 100_000
        }
        return nil
    }

    func pointSpacing(_ element: XMLElement?) -> Double {
        guard let element else { return 0 }
        if let points = element.directChild(named: "spcPts")?.attributeValue("val").flatMap(Double.init) {
            return points / 100
        }
        return 0
    }

    func emuPoints(_ value: String?, defaultValue: Int64) -> Double {
        Double(Int64(value ?? "") ?? defaultValue) / ShapeGeometry.emusPerPoint
    }

    func verticalAnchor(_ value: String?) -> TextBodyModel.VerticalAnchor {
        switch value {
        case "ctr": return .center
        case "b": return .bottom
        default: return .top
        }
    }

    func boolean(_ value: String?) -> Bool? {
        guard let value else { return nil }
        return value == "1" || value.lowercased() == "true"
    }
}

private struct ThemeContext {
    struct ResolvedColor {
        let hex: String
        let opacity: Double
    }

    struct ResolvedFont {
        let name: String
        let isExact: Bool
    }

    var colors: [String: String] = [
        "dk1": "000000", "lt1": "FFFFFF", "dk2": "1F1F1F", "lt2": "E7E6E6",
        "accent1": "4472C4", "accent2": "ED7D31", "accent3": "A5A5A5",
        "accent4": "FFC000", "accent5": "5B9BD5", "accent6": "70AD47",
        "hlink": "0563C1", "folHlink": "954F72"
    ]
    var colorAliases: [String: String] = [
        "tx1": "dk1", "tx2": "dk2", "bg1": "lt1", "bg2": "lt2",
        "accent1": "accent1", "accent2": "accent2", "accent3": "accent3",
        "accent4": "accent4", "accent5": "accent5", "accent6": "accent6",
        "hlink": "hlink", "folHlink": "folHlink"
    ]
    var majorLatin: String?
    var minorLatin: String?
    var majorEastAsian: String?
    var minorEastAsian: String?
    var majorSupplemental: [String: String] = [:]
    var minorSupplemental: [String: String] = [:]
    var themeWasLoaded = false

    var textColor: String { colors[colorAliases["tx1"] ?? "dk1"] ?? "000000" }

    init(packageURL: URL, themeURL: URL? = nil, masterURL: URL? = nil) {
        let url = themeURL ?? packageURL.appendingPathComponent("ppt/theme/theme1.xml")
        guard let document = try? XMLDocument.pptxDocument(at: url),
              let root = document.rootElement() else { return }
        themeWasLoaded = true

        if let colorScheme = root.firstDescendant(named: "clrScheme") {
            for colorElement in colorScheme.childElements {
                if let resolved = color(fromColorChoice: colorElement.childElements.first) {
                    colors[colorElement.pptxLocalName] = resolved.hex
                }
            }
        }

        if let major = root.firstDescendant(named: "majorFont") {
            majorLatin = major.directChild(named: "latin")?.attributeValue("typeface").nonEmpty
            majorEastAsian = major.directChild(named: "ea")?.attributeValue("typeface").nonEmpty
            majorSupplemental = supplementalFonts(from: major)
        }
        if let minor = root.firstDescendant(named: "minorFont") {
            minorLatin = minor.directChild(named: "latin")?.attributeValue("typeface").nonEmpty
            minorEastAsian = minor.directChild(named: "ea")?.attributeValue("typeface").nonEmpty
            minorSupplemental = supplementalFonts(from: minor)
        }

        let resolvedMasterURL: URL? = masterURL ?? {
            let mastersDirectory = packageURL.appendingPathComponent("ppt/slideMasters", isDirectory: true)
            return (try? FileManager.default.contentsOfDirectory(
                at: mastersDirectory,
                includingPropertiesForKeys: nil
            ))?.filter({ $0.pathExtension == "xml" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first
        }()
        if let resolvedMasterURL,
           let masterDocument = try? XMLDocument.pptxDocument(at: resolvedMasterURL),
           let masterRoot = masterDocument.rootElement(),
           let colorMap = masterRoot.firstDescendant(named: "clrMap") {
            applyColorMap(colorMap)
        }
    }

    static func context(
        for slideURL: URL,
        packageURL: URL,
        fallback: ThemeContext
    ) -> ThemeContext {
        guard let layoutURL = try? PPTXRelationship.target(withTypeSuffix: "/slideLayout", from: slideURL),
              let masterURL = try? PPTXRelationship.target(withTypeSuffix: "/slideMaster", from: layoutURL) else {
            return fallback
        }
        let themeURL = try? PPTXRelationship.target(withTypeSuffix: "/theme", from: masterURL)
        return ThemeContext(packageURL: packageURL, themeURL: themeURL, masterURL: masterURL)
    }

    func applyingColorMapOverride(from slideRoot: XMLElement) -> ThemeContext {
        var copy = self
        if let override = slideRoot.firstDescendant(named: "clrMapOvr")?
            .directChild(named: "overrideClrMapping") {
            copy.applyColorMap(override)
        }
        return copy
    }

    func resolveFont(
        _ typeface: String?,
        eastAsian: Bool,
        language: String?,
        text: String
    ) -> ResolvedFont {
        if let typeface = typeface.nonEmpty, !typeface.hasPrefix("+") {
            return ResolvedFont(name: typeface, isExact: true)
        }

        let token = typeface.nonEmpty ?? (eastAsian ? "+mn-ea" : "+mn-lt")
        let script = scriptKey(language: language, text: text)
        let resolved: String?
        switch token {
        case "+mj-lt": resolved = majorLatin
        case "+mn-lt": resolved = minorLatin
        case "+mj-ea": resolved = majorEastAsian ?? script.flatMap { majorSupplemental[$0] }
        case "+mn-ea": resolved = minorEastAsian ?? script.flatMap { minorSupplemental[$0] }
        case "+mj-cs": resolved = script.flatMap { majorSupplemental[$0] }
        case "+mn-cs": resolved = script.flatMap { minorSupplemental[$0] }
        default: resolved = nil
        }
        if let resolved = resolved.nonEmpty {
            return ResolvedFont(name: resolved, isExact: themeWasLoaded)
        }
        return ResolvedFont(name: eastAsian ? "PingFang SC" : "Helvetica", isExact: false)
    }

    func color(from fill: XMLElement?) -> ResolvedColor? {
        color(fromColorChoice: fill?.childElements.first)
    }

    func color(fromColorChoice colorElement: XMLElement?) -> ResolvedColor? {
        guard let colorElement else { return nil }

        let rawHex: String?
        switch colorElement.pptxLocalName {
        case "srgbClr":
            rawHex = colorElement.attributeValue("val")
        case "schemeClr":
            rawHex = colorElement.attributeValue("val").flatMap { colors[colorAliases[$0] ?? $0] }
        case "sysClr":
            rawHex = colorElement.attributeValue("lastClr")
        case "scrgbClr":
            let red = normalizedColorComponent(colorElement.attributeValue("r"))
            let green = normalizedColorComponent(colorElement.attributeValue("g"))
            let blue = normalizedColorComponent(colorElement.attributeValue("b"))
            rawHex = [red, green, blue].map { String(format: "%02X", Int(round($0 * 255))) }.joined()
        case "prstClr":
            rawHex = presetColor(colorElement.attributeValue("val"))
        default:
            rawHex = nil
        }

        guard let rawHex else { return nil }
        var components = hexComponents(rawHex)
        var opacity = 1.0
        for transform in colorElement.childElements {
            let value = transform.attributeValue("val").flatMap(Double.init).map { $0 / 100_000 }
            switch transform.pptxLocalName {
            case "tint" where value != nil:
                components = components.map { $0 + (255 - $0) * value! }
            case "shade" where value != nil:
                components = components.map { $0 * value! }
            case "lumMod" where value != nil:
                var hsl = rgbToHSL(components)
                hsl.l = clamp(hsl.l * value!)
                components = hslToRGB(hsl)
            case "lumOff" where value != nil:
                var hsl = rgbToHSL(components)
                hsl.l = clamp(hsl.l + value!)
                components = hslToRGB(hsl)
            case "alpha" where value != nil:
                opacity = clamp(value!)
            case "alphaMod" where value != nil:
                opacity = clamp(opacity * value!)
            case "alphaOff" where value != nil:
                opacity = clamp(opacity + value!)
            default:
                continue
            }
        }
        let hex = components.map { String(format: "%02X", max(0, min(255, Int(round($0))))) }.joined()
        return ResolvedColor(hex: hex, opacity: opacity)
    }

    private mutating func applyColorMap(_ element: XMLElement) {
        for attribute in element.attributes ?? [] {
            guard let name = attribute.localName, let value = attribute.stringValue else { continue }
            colorAliases[name] = value
        }
    }

    private func supplementalFonts(from fontScheme: XMLElement) -> [String: String] {
        var result: [String: String] = [:]
        for font in fontScheme.childElements where font.pptxLocalName == "font" {
            if let script = font.attributeValue("script"),
               let typeface = font.attributeValue("typeface").nonEmpty {
                result[script] = typeface
            }
        }
        return result
    }

    private func scriptKey(language: String?, text: String) -> String? {
        if let language = language?.lowercased() {
            if language.contains("hant") || language.hasSuffix("-tw")
                || language.hasSuffix("-hk") || language.hasSuffix("-mo") { return "Hant" }
            if language.hasPrefix("zh") { return "Hans" }
            if language.hasPrefix("ja") { return "Jpan" }
            if language.hasPrefix("ko") { return "Hang" }
            if language.hasPrefix("ar") { return "Arab" }
            if language.hasPrefix("he") { return "Hebr" }
            if language.hasPrefix("th") { return "Thai" }
        }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF: return "Jpan"
            case 0xAC00...0xD7AF: return "Hang"
            case 0x2E80...0x9FFF, 0xF900...0xFAFF: return "Hans"
            default: continue
            }
        }
        return nil
    }

    private func normalizedColorComponent(_ value: String?) -> Double {
        clamp((Double(value ?? "0") ?? 0) / 100_000)
    }

    private func presetColor(_ name: String?) -> String? {
        let values = [
            "black": "000000", "white": "FFFFFF", "red": "FF0000",
            "green": "008000", "blue": "0000FF", "yellow": "FFFF00",
            "orange": "FFA500", "purple": "800080", "gray": "808080",
            "grey": "808080", "brown": "A52A2A", "darkRed": "8B0000"
        ]
        return name.flatMap { values[$0] }
    }

    private func rgbToHSL(_ rgb: [Double]) -> (h: Double, s: Double, l: Double) {
        let red = rgb[0] / 255, green = rgb[1] / 255, blue = rgb[2] / 255
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        guard maximum != minimum else { return (0, 0, lightness) }
        let delta = maximum - minimum
        let saturation = lightness > 0.5
            ? delta / (2 - maximum - minimum)
            : delta / (maximum + minimum)
        let hue: Double
        if maximum == red {
            hue = ((green - blue) / delta + (green < blue ? 6 : 0)) / 6
        } else if maximum == green {
            hue = ((blue - red) / delta + 2) / 6
        } else {
            hue = ((red - green) / delta + 4) / 6
        }
        return (hue, saturation, lightness)
    }

    private func hslToRGB(_ hsl: (h: Double, s: Double, l: Double)) -> [Double] {
        guard hsl.s != 0 else { return [hsl.l * 255, hsl.l * 255, hsl.l * 255] }
        let q = hsl.l < 0.5 ? hsl.l * (1 + hsl.s) : hsl.l + hsl.s - hsl.l * hsl.s
        let p = 2 * hsl.l - q
        func hue(_ offset: Double) -> Double {
            var value = offset
            if value < 0 { value += 1 }
            if value > 1 { value -= 1 }
            if value < 1 / 6.0 { return p + (q - p) * 6 * value }
            if value < 1 / 2.0 { return q }
            if value < 2 / 3.0 { return p + (q - p) * (2 / 3.0 - value) * 6 }
            return p
        }
        return [hue(hsl.h + 1 / 3.0) * 255, hue(hsl.h) * 255, hue(hsl.h - 1 / 3.0) * 255]
    }

    private func clamp(_ value: Double) -> Double {
        max(0, min(1, value))
    }

    private func hexComponents(_ hex: String) -> [Double] {
        let value = Int(hex, radix: 16) ?? 0
        return [Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF)]
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
