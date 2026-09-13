import Foundation

struct PresentationAnalysis: Sendable {
    let sourceURL: URL
    let slides: [SlideAnalysis]
    let fonts: [FontUsage]

    var slideCount: Int { slides.count }
    var textObjectCount: Int { slides.reduce(0) { $0 + $1.textObjectCount } }
    var supportedTextCount: Int { slides.reduce(0) { $0 + $1.supportedTextCount } }
    var needsReviewCount: Int { textObjectCount - supportedTextCount }
}

struct SlideAnalysis: Identifiable, Sendable {
    let index: Int
    let textObjectCount: Int
    let supportedTextCount: Int
    let issues: [OutlineIssue]

    var id: Int { index }
}

struct FontUsage: Identifiable, Hashable, Sendable {
    let name: String
    let count: Int
    let isAvailable: Bool

    var id: String { name }
}

struct OutlineIssue: Identifiable, Hashable, Sendable {
    let slideIndex: Int
    let shapeName: String
    let reason: OutlineSkipReason

    var id: String { "\(slideIndex)-\(shapeName)-\(reason.rawValue)" }
}

enum OutlineSkipReason: String, Hashable, Sendable {
    case missingGeometry
    case missingFont
    case unresolvedStyle
    case advancedAnimation
    case unsupportedWordArt
    case unsupportedVerticalText
    case unsupportedShapeStyle
    case unsupportedGroup
    case unsupportedObject
    case hyperlink
    case emptyText
    case unselectedMixedFonts
    case renderingFailed

    var localizationKey: String {
        "issue.\(rawValue)"
    }
}

enum ConversionMode: String, CaseIterable, Identifiable, Sendable {
    case allText
    case selectedFonts

    var id: String { rawValue }
    var localizationKey: String { "conversion.mode.\(rawValue)" }
}

struct ProcessingProgress: Sendable {
    enum Stage: Sendable {
        case extracting
        case analyzing
        case outlining
        case packaging
    }

    let stage: Stage
    let currentSlide: Int
    let totalSlides: Int
}

struct ConversionReport: Sendable {
    let outputURL: URL
    let slideCount: Int
    let convertedTextCount: Int
    let skippedIssues: [OutlineIssue]

    var skippedCount: Int { skippedIssues.count }
    var warningCount: Int { Set(skippedIssues.map(\.reason)).count }
}

struct ShapeGeometry: Sendable {
    let x: Int64
    let y: Int64
    let width: Int64
    let height: Int64
    let rotation: Int32
    let flipHorizontal: Bool
    let flipVertical: Bool

    static let emusPerPoint = 12_700.0

    var widthPoints: Double { Double(width) / Self.emusPerPoint }
    var heightPoints: Double { Double(height) / Self.emusPerPoint }
}

struct TextRunModel: Sendable {
    let text: String
    let fontName: String
    let fontSize: Double
    let colorHex: String
    let opacity: Double
    let isBold: Bool
    let isItalic: Bool
    let kerning: Double
    let baseline: Double
    let isUnderlined: Bool
    let gradientStops: [TextGradientStop]
    let outline: TextOutlineStyle?
    let styleIsResolved: Bool
}

struct TextGradientStop: Sendable {
    let position: Double
    let colorHex: String
    let opacity: Double
}

struct TextOutlineStyle: Sendable {
    let colorHex: String
    let opacity: Double
    let width: Double
}

struct TextParagraphModel: Sendable {
    enum Alignment: Sendable {
        case left
        case center
        case right
        case justified
    }

    let runs: [TextRunModel]
    let alignment: Alignment
    let level: Int
    let lineSpacingMultiple: Double?
    let spaceBefore: Double
    let spaceAfter: Double
    let bullet: String?
}

struct TextBodyModel: Sendable {
    enum VerticalAnchor: Sendable {
        case top
        case center
        case bottom
    }

    let paragraphs: [TextParagraphModel]
    let marginLeft: Double
    let marginRight: Double
    let marginTop: Double
    let marginBottom: Double
    let verticalAnchor: VerticalAnchor
    let fontScale: Double
    let verticalMode: String?
    let warpPreset: String?

    var fontNames: Set<String> {
        Set(paragraphs.flatMap(\.runs).map(\.fontName))
    }

    var styleIsResolved: Bool {
        paragraphs.allSatisfy { paragraph in
            paragraph.runs.allSatisfy(\.styleIsResolved)
        }
    }

    var plainText: String {
        paragraphs.map { paragraph in
            (paragraph.bullet ?? "") + paragraph.runs.map(\.text).joined()
        }.joined(separator: "\n")
    }
}

struct TextShapeModel: Sendable {
    let slideIndex: Int
    let shapeID: String
    let shapeName: String
    let geometry: ShapeGeometry?
    let textBody: TextBodyModel?
    let skipReason: OutlineSkipReason?

    var isSupported: Bool { skipReason == nil && geometry != nil && textBody != nil }
}
