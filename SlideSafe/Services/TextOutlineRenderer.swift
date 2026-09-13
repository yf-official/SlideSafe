import AppKit
import CoreText
import Foundation

struct TextOutlineRenderResult {
    let svgData: Data
    let pngData: Data
}

enum TextOutlineRendererError: Error {
    case invalidSize
    case fontUnavailable(String)
    case fontTraitUnavailable(String)
    case noGlyphs
    case rasterizationFailed
}

final class FontResolver {
    static let shared = FontResolver()

    private let fontManager = NSFontManager.shared
    private let availableNames: Set<String>

    private init() {
        let names = fontManager.availableFonts + fontManager.availableFontFamilies
        availableNames = Set(names.map { $0.lowercased() })
    }

    func isAvailable(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return availableNames.contains(normalized.lowercased()) || NSFont(name: normalized, size: 12) != nil
    }

    func font(name: String, size: Double, bold: Bool, italic: Bool) throws -> NSFont {
        guard isAvailable(name) else {
            throw TextOutlineRendererError.fontUnavailable(name)
        }

        let base = NSFont(name: name, size: size)
            ?? fontManager.font(withFamily: name, traits: [], weight: 5, size: size)

        guard var font = base else {
            throw TextOutlineRendererError.fontUnavailable(name)
        }

        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = fontManager.convert(font, toHaveTrait: traits)
        }
        return font
    }
}

final class TextOutlineRenderer {
    func render(body: TextBodyModel, geometry: ShapeGeometry) throws -> TextOutlineRenderResult {
        let width = geometry.widthPoints
        let height = geometry.heightPoints
        guard width > 0, height > 0 else { throw TextOutlineRendererError.invalidSize }

        let attributedString = try makeAttributedString(from: body)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)

        let isVertical = body.verticalMode != nil
        let layoutWidth = isVertical ? height : width
        let layoutHeight = isVertical ? width : height
        let marginLeft = isVertical ? body.marginTop : body.marginLeft
        let marginRight = isVertical ? body.marginBottom : body.marginRight
        let marginTop = isVertical ? body.marginRight : body.marginTop
        let marginBottom = isVertical ? body.marginLeft : body.marginBottom

        let availableWidth = max(1, layoutWidth - marginLeft - marginRight)
        let availableHeight = max(1, layoutHeight - marginTop - marginBottom)
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributedString.length),
            nil,
            CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
            nil
        )

        // CoreText may decline to create even one line when the PowerPoint text
        // box is fractionally shorter than the selected font's native metrics.
        // Lay out at the required height and let the SVG viewport perform the
        // same clipping as the original text box.
        let textHeight = max(1, ceil(suggestedSize.height) + 2)
        let verticalOffset: Double
        switch body.verticalAnchor {
        case .top:
            verticalOffset = availableHeight - textHeight
        case .center:
            verticalOffset = (availableHeight - textHeight) / 2
        case .bottom:
            verticalOffset = 0
        }

        let frameRect = CGRect(
            x: marginLeft,
            y: marginBottom + verticalOffset,
            width: availableWidth,
            height: textHeight
        )
        let framePath = CGPath(rect: frameRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributedString.length),
            framePath,
            nil
        )

        let pointTransform: (CGPoint) -> CGPoint = { [self] point in
            let oriented: CGPoint
            switch body.verticalMode {
            case "vert", "wordArtVert", "eaVert", "mongolianVert":
                oriented = CGPoint(x: point.y, y: height - point.x)
            case "vert270", "wordArtVertRtl":
                oriented = CGPoint(x: width - point.y, y: point.x)
            default:
                oriented = point
            }
            return warpedPoint(oriented, preset: body.warpPreset, width: width, height: height)
        }
        let content = makeSVGContent(from: frame, pointTransform: pointTransform)
        guard !content.elements.isEmpty else { throw TextOutlineRendererError.noGlyphs }
        let definitions = content.definitions.isEmpty
            ? ""
            : "<defs>\n    \(content.definitions.joined(separator: "\n    "))\n  </defs>"

        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(format(width))" height="\(format(height))" viewBox="0 0 \(format(width)) \(format(height))" overflow="hidden">
          \(definitions)
          <g transform="translate(0 \(format(height))) scale(1 -1)">
            \(content.elements.joined(separator: "\n    "))
          </g>
        </svg>
        """

        guard let svgData = svg.data(using: .utf8),
              let pngData = rasterize(svgData: svgData, width: width, height: height) else {
            throw TextOutlineRendererError.rasterizationFailed
        }

        return TextOutlineRenderResult(svgData: svgData, pngData: pngData)
    }

    private func makeAttributedString(from body: TextBodyModel) throws -> NSAttributedString {
        let result = NSMutableAttributedString()

        for (paragraphIndex, paragraph) in body.paragraphs.enumerated() {
            let paragraphStart = result.length

            if let bullet = paragraph.bullet, let firstRun = paragraph.runs.first {
                let bulletRun = TextRunModel(
                    text: bullet + "\t",
                    fontName: firstRun.fontName,
                    fontSize: firstRun.fontSize,
                    colorHex: firstRun.colorHex,
                    opacity: firstRun.opacity,
                    isBold: firstRun.isBold,
                    isItalic: firstRun.isItalic,
                    kerning: firstRun.kerning,
                    baseline: firstRun.baseline,
                    isUnderlined: firstRun.isUnderlined,
                    gradientStops: firstRun.gradientStops,
                    outline: firstRun.outline,
                    styleIsResolved: firstRun.styleIsResolved
                )
                try append(bulletRun, scale: body.fontScale, to: result)
            }

            for run in paragraph.runs {
                try append(run, scale: body.fontScale, to: result)
            }

            if paragraphIndex < body.paragraphs.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }

            let paragraphStyle = NSMutableParagraphStyle()
            switch paragraph.alignment {
            case .left:
                paragraphStyle.alignment = .left
            case .center:
                paragraphStyle.alignment = .center
            case .right:
                paragraphStyle.alignment = .right
            case .justified:
                paragraphStyle.alignment = .justified
            }
            if let lineSpacingMultiple = paragraph.lineSpacingMultiple {
                paragraphStyle.lineHeightMultiple = lineSpacingMultiple
            }
            paragraphStyle.paragraphSpacingBefore = paragraph.spaceBefore
            paragraphStyle.paragraphSpacing = paragraph.spaceAfter

            let paragraphLength = result.length - paragraphStart
            if paragraphLength > 0 {
                result.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: NSRange(location: paragraphStart, length: paragraphLength)
                )
            }
        }

        return result
    }

    private func append(
        _ run: TextRunModel,
        scale: Double,
        to attributedString: NSMutableAttributedString
    ) throws {
        let fontSize = max(1, run.fontSize * scale)
        let font = try FontResolver.shared.font(
            name: run.fontName,
            size: fontSize,
            bold: run.isBold,
            italic: run.isItalic
        )
        let color = NSColor(slideSafeHex: run.colorHex, opacity: run.opacity)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: run.kerning * scale,
            .baselineOffset: run.baseline * fontSize
        ]
        if run.isUnderlined {
            attributes[.slideSafeUnderline] = true
        }
        let appliedTraits = NSFontManager.shared.traits(of: font)
        if run.isBold && !appliedTraits.contains(.boldFontMask) {
            attributes[.slideSafeSyntheticBold] = max(0.55, fontSize * 0.035)
        }
        if run.isItalic && !appliedTraits.contains(.italicFontMask) {
            attributes[.slideSafeSyntheticItalic] = true
        }
        if !run.gradientStops.isEmpty {
            attributes[.slideSafeGradient] = run.gradientStops.map {
                "\($0.position),\($0.colorHex),\($0.opacity)"
            }.joined(separator: "|")
        }
        if let outline = run.outline {
            attributes[.slideSafeOutline] = "\(outline.colorHex),\(outline.opacity),\(outline.width * scale)"
        }
        attributedString.append(NSAttributedString(string: run.text, attributes: attributes))
    }

    private struct SVGContent {
        var definitions: [String] = []
        var elements: [String] = []
    }

    private func makeSVGContent(
        from frame: CTFrame,
        pointTransform: (CGPoint) -> CGPoint
    ) -> SVGContent {
        let lines = CTFrameGetLines(frame) as NSArray as? [CTLine] ?? []
        guard !lines.isEmpty else { return SVGContent() }

        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var content = SVGContent()
        for (lineIndex, line) in lines.enumerated() {
            let runs = CTLineGetGlyphRuns(line) as NSArray as? [CTRun] ?? []
            for (runIndex, run) in runs.enumerated() {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }

                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let font = attributes[kCTFontAttributeName] as! CTFont? else { continue }
                let colorValue = attributes[NSAttributedString.Key.foregroundColor]
                    ?? attributes[kCTForegroundColorAttributeName]
                let color: NSColor
                if let nativeColor = colorValue as? NSColor {
                    color = nativeColor
                } else if let colorValue,
                          CFGetTypeID(colorValue as CFTypeRef) == CGColor.typeID {
                    color = NSColor(cgColor: colorValue as! CGColor) ?? .textColor
                } else {
                    color = .textColor
                }
                let colorHex = color.slideSafeHex
                let alpha = color.alphaComponent
                let gradientID = "slidesafe-gradient-\(lineIndex)-\(runIndex)"
                let gradientToken = attributes[NSAttributedString.Key.slideSafeGradient] as? String
                if let gradientToken {
                    let stops = gradientToken.split(separator: "|").compactMap { token -> String? in
                        let fields = token.split(separator: ",", omittingEmptySubsequences: false)
                        guard fields.count == 3,
                              let position = Double(fields[0]),
                              let opacity = Double(fields[2]) else { return nil }
                        return "<stop offset=\"\(format(max(0, min(1, position)) * 100))%\" stop-color=\"#\(fields[1])\" stop-opacity=\"\(format(max(0, min(1, opacity))))\"/>"
                    }
                    if !stops.isEmpty {
                        content.definitions.append(
                            "<linearGradient id=\"\(gradientID)\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"0%\">\(stops.joined())</linearGradient>"
                        )
                    }
                }
                let fillAttribute = gradientToken == nil
                    ? "fill=\"#\(colorHex)\""
                    : "fill=\"url(#\(gradientID))\""
                let opacityAttribute = gradientToken == nil && alpha < 0.999
                    ? " fill-opacity=\"\(format(alpha))\""
                    : ""
                let outlineAttribute: String = {
                    if let token = attributes[NSAttributedString.Key.slideSafeOutline] as? String {
                        let fields = token.split(separator: ",", omittingEmptySubsequences: false)
                        guard fields.count == 3,
                              let opacity = Double(fields[1]),
                              let width = Double(fields[2]) else { return "" }
                        return " stroke=\"#\(fields[0])\" stroke-opacity=\"\(format(opacity))\" stroke-width=\"\(format(width))\" stroke-linejoin=\"round\""
                    }
                    if let width = attributes[NSAttributedString.Key.slideSafeSyntheticBold] as? Double {
                        return " stroke=\"#\(colorHex)\" stroke-opacity=\"\(format(alpha))\" stroke-width=\"\(format(width))\" stroke-linejoin=\"round\""
                    }
                    return ""
                }()

                var glyphs = Array(repeating: CGGlyph(), count: count)
                var positions = Array(repeating: CGPoint.zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

                for glyphIndex in 0..<count {
                    guard let glyphPath = CTFontCreatePathForGlyph(font, glyphs[glyphIndex], nil) else { continue }
                    let styledPath: CGPath
                    if attributes[NSAttributedString.Key.slideSafeSyntheticItalic] as? Bool == true {
                        var shear = CGAffineTransform(a: 1, b: 0, c: 0.20, d: 1, tx: 0, ty: 0)
                        styledPath = glyphPath.copy(using: &shear) ?? glyphPath
                    } else {
                        styledPath = glyphPath
                    }
                    var transform = CGAffineTransform(
                        translationX: origins[lineIndex].x + positions[glyphIndex].x,
                        y: origins[lineIndex].y + positions[glyphIndex].y
                    )
                    guard let positionedPath = styledPath.copy(using: &transform) else { continue }
                    let pathData = svgPathData(positionedPath, pointTransform: pointTransform)
                    guard !pathData.isEmpty else { continue }
                    content.elements.append("<path \(fillAttribute)\(opacityAttribute)\(outlineAttribute) d=\"\(pathData)\"/>")
                }

                if attributes[NSAttributedString.Key.slideSafeUnderline] as? Bool == true {
                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    var leading: CGFloat = 0
                    let runWidth = CTRunGetTypographicBounds(
                        run,
                        CFRange(location: 0, length: 0),
                        &ascent,
                        &descent,
                        &leading
                    )
                    let start = positions.first ?? .zero
                    let thickness = max(0.75, CTFontGetUnderlineThickness(font))
                    let underlineRect = CGRect(
                        x: origins[lineIndex].x + start.x,
                        y: origins[lineIndex].y + start.y + CTFontGetUnderlinePosition(font),
                        width: runWidth,
                        height: thickness
                    )
                    let underlinePath = CGPath(rect: underlineRect, transform: nil)
                    let pathData = svgPathData(underlinePath, pointTransform: pointTransform)
                    if !pathData.isEmpty {
                        content.elements.append("<path \(fillAttribute)\(opacityAttribute) d=\"\(pathData)\"/>")
                    }
                }
            }
        }
        return content
    }

    private func svgPathData(
        _ path: CGPath,
        pointTransform: (CGPoint) -> CGPoint = { $0 }
    ) -> String {
        var commands: [String] = []
        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                let point = pointTransform(element.points[0])
                commands.append("M\(format(point.x)) \(format(point.y))")
            case .addLineToPoint:
                let point = pointTransform(element.points[0])
                commands.append("L\(format(point.x)) \(format(point.y))")
            case .addQuadCurveToPoint:
                let control = pointTransform(element.points[0])
                let end = pointTransform(element.points[1])
                commands.append(
                    "Q\(format(control.x)) \(format(control.y)) \(format(end.x)) \(format(end.y))"
                )
            case .addCurveToPoint:
                let control1 = pointTransform(element.points[0])
                let control2 = pointTransform(element.points[1])
                let end = pointTransform(element.points[2])
                commands.append(
                    "C\(format(control1.x)) \(format(control1.y)) \(format(control2.x)) \(format(control2.y)) \(format(end.x)) \(format(end.y))"
                )
            case .closeSubpath:
                commands.append("Z")
            @unknown default:
                break
            }
        }
        return commands.joined(separator: " ")
    }

    private func warpedPoint(
        _ point: CGPoint,
        preset: String?,
        width: Double,
        height: Double
    ) -> CGPoint {
        guard let preset, width > 0, height > 0 else { return point }
        let x = max(0, min(1, point.x / width))
        let y = max(0, min(1, point.y / height))
        var result = point

        switch preset {
        case "textArchUp", "textCurveUp":
            result.y += sin(.pi * x) * height * 0.22
        case "textArchDown", "textCurveDown":
            result.y -= sin(.pi * x) * height * 0.22
        case "textWave1", "textWave2", "textWave4", "textDoubleWave1":
            let cycles = preset == "textDoubleWave1" ? 4.0 : 2.0
            result.y += sin(cycles * .pi * x) * height * 0.11
        case "textCanUp":
            result.y += (1 - pow((x - 0.5) * 2, 2)) * height * 0.16
        case "textCanDown":
            result.y -= (1 - pow((x - 0.5) * 2, 2)) * height * 0.16
        case "textInflate", "textInflateTop", "textInflateBottom":
            let strength = sin(.pi * x) * 0.18
            if preset != "textInflateBottom" { result.y += (1 - y) * height * strength }
            if preset != "textInflateTop" { result.y -= y * height * strength }
        case "textDeflate", "textDeflateTop", "textDeflateBottom":
            let strength = sin(.pi * x) * 0.14
            if preset != "textDeflateBottom" { result.y -= (1 - y) * height * strength }
            if preset != "textDeflateTop" { result.y += y * height * strength }
        case "textSlantUp":
            result.y += (x - 0.5) * height * 0.35
        case "textSlantDown":
            result.y -= (x - 0.5) * height * 0.35
        case "textTriangle":
            result.y += (1 - abs(x - 0.5) * 2) * height * 0.22
        case "textTriangleInverted":
            result.y -= (1 - abs(x - 0.5) * 2) * height * 0.22
        case "textFadeUp":
            result.x = width / 2 + (point.x - width / 2) * (0.65 + 0.35 * y)
        case "textFadeDown":
            result.x = width / 2 + (point.x - width / 2) * (1 - 0.35 * y)
        case "textFadeLeft":
            result.y = height / 2 + (point.y - height / 2) * (0.65 + 0.35 * x)
        case "textFadeRight":
            result.y = height / 2 + (point.y - height / 2) * (1 - 0.35 * x)
        default:
            break
        }
        return result
    }

    private func rasterize(svgData: Data, width: Double, height: Double) -> Data? {
        guard let image = NSImage(data: svgData) else { return nil }
        let scale = 2.0
        let pixelWidth = max(1, Int(ceil(width * scale)))
        let pixelHeight = max(1, Int(ceil(height * scale)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private func format(_ value: Double) -> String {
        let formatted = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        return formatted
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

private extension NSAttributedString.Key {
    static let slideSafeUnderline = NSAttributedString.Key("SlideSafeUnderline")
    static let slideSafeGradient = NSAttributedString.Key("SlideSafeGradient")
    static let slideSafeOutline = NSAttributedString.Key("SlideSafeOutline")
    static let slideSafeSyntheticBold = NSAttributedString.Key("SlideSafeSyntheticBold")
    static let slideSafeSyntheticItalic = NSAttributedString.Key("SlideSafeSyntheticItalic")
}

private extension NSColor {
    convenience init(slideSafeHex hex: String, opacity: Double) {
        let value = Int(hex, radix: 16) ?? 0
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: opacity)
    }

    var slideSafeHex: String {
        guard let color = usingColorSpace(.sRGB) else { return "000000" }
        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}
