import CoreGraphics
import Foundation
import ImageCraftCore

/// 基于公开 Foundation XMLParser + Core Graphics 的严格 SVG v1 子集参考实现。
///
/// v1 必须有 `viewBox`，只支持 `svg`/`g` 容器、fill-only `rect`/`circle`/`ellipse`/`path`，
/// path 命令限定 M/L/H/V/C/S/Q/T/Z。DTD/entity、脚本、CSS、文本、外部引用、image、
/// font、stroke、transform、gradient/filter/mask/clip、animation 和 arc 均失败关闭。
public struct CoreGraphicsSVGRasterizer: SVGSingleDocumentRasterizing, Sendable {
    public let rasterizerDescriptor: SVGRasterizerDescriptor

    public init() {
        self.rasterizerDescriptor = SVGRasterizerDescriptor(
            identifier: ImageCodecIdentifier(rawValue: "dev.imagecraft.coregraphics-svg-v1"),
            implementationVersion: 2
        )
    }

    public func probe(
        data: Data,
        limits: SVGRasterizationLimits
    ) throws -> SVGDocumentProbe {
        try SVGDocumentParser.parse(data: data, limits: limits, context: nil)
    }

    public func rasterize(
        data: Data,
        probe: SVGDocumentProbe,
        request: SVGRasterizationRequest,
        limits: SVGRasterizationLimits
    ) throws -> DecodedImage {
        try SVGRasterizationGeometry.validateTarget(request.target, limits: limits)
        let currentProbe = try SVGDocumentParser.parse(data: data, limits: limits, context: nil)
        guard currentProbe == probe else {
            throw SVGRasterizationError.probeMismatch
        }

        let output = try SVGRasterizationGeometry.outputSize(probe: probe, request: request)
        let rowBytes = SVGRasterizationGeometry.saturatedProduct(output.width, 4)
        let byteCount = SVGRasterizationGeometry.saturatedProduct(rowBytes, output.height)
        guard rowBytes != Int.max, byteCount != Int.max else {
            throw SVGRasterizationError.targetPixelCountExceeded
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw SVGRasterizationError.renderFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        var pixels = [UInt8](repeating: 0, count: byteCount)

        let renderedProbe = try pixels.withUnsafeMutableBytes { bytes -> SVGDocumentProbe in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: output.width,
                height: output.height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                throw SVGRasterizationError.renderFailed
            }
            let outputRect = CGRect(x: 0, y: 0, width: output.width, height: output.height)
            context.clear(outputRect)
            context.clip(to: outputRect)

            let viewBox = probe.viewBox
            let widthScale = CGFloat(output.width) / CGFloat(viewBox.width)
            let heightScale = CGFloat(output.height) / CGFloat(viewBox.height)
            let scale: CGFloat
            switch request.contentMode {
            case .fit:
                scale = min(widthScale, heightScale)
            case .fill:
                scale = max(widthScale, heightScale)
            }
            guard scale.isFinite, scale > 0 else {
                throw SVGRasterizationError.viewBoxInvalid
            }
            let renderedWidth = CGFloat(viewBox.width) * scale
            let renderedHeight = CGFloat(viewBox.height) * scale
            let offsetX = (CGFloat(output.width) - renderedWidth) / 2
            let offsetY = (CGFloat(output.height) - renderedHeight) / 2

            // SVG 用户空间 y 轴向下；裸 Core Graphics bitmap context 的 y 轴向上。
            context.translateBy(x: offsetX, y: offsetY + renderedHeight)
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -CGFloat(viewBox.minX), y: -CGFloat(viewBox.minY))

            return try SVGDocumentParser.parse(data: data, limits: limits, context: context)
        }
        guard renderedProbe == probe else {
            throw SVGRasterizationError.probeMismatch
        }

        let rasterData = Data(pixels)
        guard let provider = CGDataProvider(data: rasterData as CFData),
            let image = CGImage(
                width: output.width,
                height: output.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw SVGRasterizationError.renderFailed
        }

        let estimate = try resourceEstimate(probe: probe, request: request, limits: limits)
        let result = DecodedImage(cgImage: image, sourceColorProfile: .standardSRGB)
        guard result.estimatedByteCost <= estimate.workingSetBytes else {
            throw SVGRasterizationError.renderFailed
        }
        return result
    }
}

private enum SVGDocumentParser {
    static func parse(
        data: Data,
        limits: SVGRasterizationLimits,
        context: CGContext?
    ) throws -> SVGDocumentProbe {
        guard data.count <= limits.maximumEncodedBytes else {
            throw SVGRasterizationError.encodedBytesExceeded
        }
        // XML 1.0 本身不允许 NUL；拒绝它也排除了 UTF-16/32 交错零字节绕过 ASCII
        // markup 预检。其他 XML 编码仍必须保留 ASCII markup 字节，因此 DTD/entity
        // 声明可以在进入 XMLParser 前按原始字节失败关闭。不能只依赖
        // shouldResolveExternalEntities=false：外部声明可能被静默忽略而不触发 delegate。
        guard !data.contains(0) else {
            throw SVGRasterizationError.malformedDocument
        }
        let doctype = Data("<!DOCTYPE".utf8)
        let entity = Data("<!ENTITY".utf8)
        guard data.range(of: doctype) == nil, data.range(of: entity) == nil else {
            throw SVGRasterizationError.unsafeMarkup
        }

        let delegate = SVGXMLDelegate(limits: limits, context: context)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if let failure = delegate.failure {
            throw failure
        }
        guard parsed else {
            throw SVGRasterizationError.malformedDocument
        }
        return try delegate.finish(encodedByteCount: data.count)
    }
}

private final class SVGXMLDelegate: NSObject, XMLParserDelegate {
    private static let svgNamespace = "http://www.w3.org/2000/svg"

    private enum ElementKind {
        case svg
        case group
        case leaf
    }

    private enum FillRule {
        case nonzero
        case evenOdd
    }

    private enum Paint {
        case none
        case rgba(CGFloat, CGFloat, CGFloat, CGFloat)
    }

    private struct Style {
        var paint: Paint = .rgba(0, 0, 0, 1)
        var fillOpacity: CGFloat = 1
        var fillRule: FillRule = .nonzero
    }

    private let limits: SVGRasterizationLimits
    private let context: CGContext?
    private var elementStack: [ElementKind] = []
    private var styleStack: [Style] = []
    private var viewBox: SVGViewBox?
    private var elementCount = 0
    private var pathCommandCount = 0
    private var rootClosed = false
    fileprivate var failure: SVGRasterizationError?

    init(limits: SVGRasterizationLimits, context: CGContext?) {
        self.limits = limits
        self.context = context
    }

    fileprivate func finish(encodedByteCount: Int) throws -> SVGDocumentProbe {
        guard failure == nil, elementStack.isEmpty, styleStack.isEmpty, rootClosed else {
            throw failure ?? SVGRasterizationError.malformedDocument
        }
        guard let viewBox else {
            throw SVGRasterizationError.missingViewBox
        }
        return SVGDocumentProbe(
            encodedByteCount: encodedByteCount,
            viewBox: viewBox,
            elementCount: elementCount,
            pathCommandCount: pathCommandCount
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        guard namespaceURI == nil || namespaceURI == "" || namespaceURI == Self.svgNamespace else {
            reject(.unsupportedDocumentSemantics, parser)
            return
        }
        elementCount += 1
        guard elementCount <= limits.maximumElements else {
            reject(.elementLimitExceeded, parser)
            return
        }
        guard elementStack.count + 1 <= limits.maximumNestingDepth else {
            reject(.nestingDepthExceeded, parser)
            return
        }
        guard attributeDict.count <= 16 else {
            reject(.unsupportedDocumentSemantics, parser)
            return
        }
        if rootClosed {
            reject(.malformedDocument, parser)
            return
        }
        if elementStack.last == .leaf {
            reject(.unsupportedDocumentSemantics, parser)
            return
        }

        let inherited = styleStack.last ?? Style()
        do {
            switch elementName {
            case "svg":
                guard elementStack.isEmpty, viewBox == nil else {
                    throw SVGRasterizationError.unsupportedDocumentSemantics
                }
                let parsedViewBox = try parseRoot(attributes: attributeDict)
                viewBox = parsedViewBox.viewBox
                elementStack.append(.svg)
                styleStack.append(parsedViewBox.style)
            case "g":
                guard !elementStack.isEmpty else {
                    throw SVGRasterizationError.malformedDocument
                }
                let style = try parseStyle(
                    attributes: attributeDict,
                    allowedGeometry: [],
                    inherited: inherited
                ).style
                elementStack.append(.group)
                styleStack.append(style)
            case "rect":
                try startRect(attributes: attributeDict, inherited: inherited)
                elementStack.append(.leaf)
                styleStack.append(inherited)
            case "circle":
                try startCircle(attributes: attributeDict, inherited: inherited)
                elementStack.append(.leaf)
                styleStack.append(inherited)
            case "ellipse":
                try startEllipse(attributes: attributeDict, inherited: inherited)
                elementStack.append(.leaf)
                styleStack.append(inherited)
            case "path":
                try startPath(attributes: attributeDict, inherited: inherited)
                elementStack.append(.leaf)
                styleStack.append(inherited)
            default:
                throw SVGRasterizationError.unsupportedDocumentSemantics
            }
        } catch let error as SVGRasterizationError {
            reject(error, parser)
        } catch {
            reject(.malformedDocument, parser)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else { return }
        guard !elementStack.isEmpty, !styleStack.isEmpty else {
            reject(.malformedDocument, parser)
            return
        }
        let ended = elementStack.removeLast()
        styleStack.removeLast()
        if ended == .svg {
            guard elementStack.isEmpty, elementName == "svg" else {
                reject(.malformedDocument, parser)
                return
            }
            rootClosed = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard string.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            reject(.unsupportedDocumentSemantics, parser)
            return
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        reject(.unsafeMarkup, parser)
    }

    func parser(
        _ parser: XMLParser,
        foundProcessingInstructionWithTarget target: String,
        data: String?
    ) {
        reject(.unsafeMarkup, parser)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        reject(.unsafeMarkup, parser)
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        reject(.unsafeMarkup, parser)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil {
            failure = .malformedDocument
        }
    }

    private func reject(_ error: SVGRasterizationError, _ parser: XMLParser) {
        guard failure == nil else { return }
        failure = error
        parser.abortParsing()
    }

    private func parseRoot(attributes: [String: String]) throws -> (viewBox: SVGViewBox, style: Style) {
        let allowed: Set<String> = [
            "viewBox", "width", "height", "version", "xmlns", "id",
            "fill", "fill-opacity", "fill-rule",
        ]
        try rejectUnknownAttributes(attributes, allowed: allowed)
        guard let rawViewBox = attributes["viewBox"] else {
            throw SVGRasterizationError.missingViewBox
        }
        let values = try numberList(rawViewBox, exactCount: 4)
        guard values[2] > 0, values[3] > 0 else {
            throw SVGRasterizationError.viewBoxInvalid
        }
        try validateCoordinate(values[0])
        try validateCoordinate(values[1])
        try validateCoordinate(values[2])
        try validateCoordinate(values[3])
        try validateCoordinate(values[0] + values[2])
        try validateCoordinate(values[1] + values[3])
        if let width = attributes["width"] {
            guard try parseLength(width) > 0 else { throw SVGRasterizationError.viewBoxInvalid }
        }
        if let height = attributes["height"] {
            guard try parseLength(height) > 0 else { throw SVGRasterizationError.viewBoxInvalid }
        }
        if let version = attributes["version"], !["1.0", "1.1", "2.0"].contains(version) {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        if let xmlns = attributes["xmlns"], xmlns != Self.svgNamespace {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        let style = try parseStyle(
            attributes: attributes,
            allowedGeometry: ["viewBox", "width", "height", "version", "xmlns"],
            inherited: Style()
        ).style
        return (
            SVGViewBox(minX: values[0], minY: values[1], width: values[2], height: values[3]),
            style
        )
    }

    private func startRect(attributes: [String: String], inherited: Style) throws {
        let parsed = try parseStyle(
            attributes: attributes,
            allowedGeometry: ["x", "y", "width", "height"],
            inherited: inherited
        )
        guard let widthRaw = attributes["width"], let heightRaw = attributes["height"] else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        let x = try parseNumber(attributes["x"] ?? "0")
        let y = try parseNumber(attributes["y"] ?? "0")
        let width = try parseNumber(widthRaw)
        let height = try parseNumber(heightRaw)
        guard width >= 0, height >= 0 else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        try validateRect(x: x, y: y, width: width, height: height)
        guard let context, width > 0, height > 0 else { return }
        try apply(style: parsed.style, to: context) {
            context.fill(CGRect(x: x, y: y, width: width, height: height))
        }
    }

    private func startCircle(attributes: [String: String], inherited: Style) throws {
        let parsed = try parseStyle(
            attributes: attributes,
            allowedGeometry: ["cx", "cy", "r"],
            inherited: inherited
        )
        guard let radiusRaw = attributes["r"] else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        let cx = try parseNumber(attributes["cx"] ?? "0")
        let cy = try parseNumber(attributes["cy"] ?? "0")
        let radius = try parseNumber(radiusRaw)
        guard radius >= 0 else { throw SVGRasterizationError.unsupportedDocumentSemantics }
        try validateRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
        guard let context, radius > 0 else { return }
        try apply(style: parsed.style, to: context) {
            context.fillEllipse(in: CGRect(
                x: cx - radius,
                y: cy - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }

    private func startEllipse(attributes: [String: String], inherited: Style) throws {
        let parsed = try parseStyle(
            attributes: attributes,
            allowedGeometry: ["cx", "cy", "rx", "ry"],
            inherited: inherited
        )
        guard let rxRaw = attributes["rx"], let ryRaw = attributes["ry"] else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        let cx = try parseNumber(attributes["cx"] ?? "0")
        let cy = try parseNumber(attributes["cy"] ?? "0")
        let rx = try parseNumber(rxRaw)
        let ry = try parseNumber(ryRaw)
        guard rx >= 0, ry >= 0 else { throw SVGRasterizationError.unsupportedDocumentSemantics }
        try validateRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        guard let context, rx > 0, ry > 0 else { return }
        try apply(style: parsed.style, to: context) {
            context.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        }
    }

    private func startPath(attributes: [String: String], inherited: Style) throws {
        let parsed = try parseStyle(
            attributes: attributes,
            allowedGeometry: ["d"],
            inherited: inherited
        )
        guard let pathData = attributes["d"], !pathData.isEmpty else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        var parser = SVGPathDataParser(
            text: pathData,
            maximumCoordinateMagnitude: limits.maximumCoordinateMagnitude,
            remainingCommandBudget: limits.maximumPathCommands - pathCommandCount
        )
        let path = try parser.parse()
        pathCommandCount += parser.commandCount
        guard pathCommandCount <= limits.maximumPathCommands else {
            throw SVGRasterizationError.pathCommandLimitExceeded
        }
        guard let context else { return }
        try apply(style: parsed.style, to: context) {
            context.addPath(path)
            switch parsed.style.fillRule {
            case .nonzero:
                context.drawPath(using: .fill)
            case .evenOdd:
                context.drawPath(using: .eoFill)
            }
        }
    }

    private func parseStyle(
        attributes: [String: String],
        allowedGeometry: Set<String>,
        inherited: Style
    ) throws -> (style: Style, geometry: [String: String]) {
        let styleAttributes: Set<String> = ["fill", "fill-opacity", "fill-rule", "id"]
        try rejectUnknownAttributes(attributes, allowed: allowedGeometry.union(styleAttributes))
        var style = inherited
        if let fill = attributes["fill"] {
            style.paint = try parsePaint(fill)
        }
        if let opacity = attributes["fill-opacity"] {
            let value = try parseNumber(opacity)
            guard (0...1).contains(value) else {
                throw SVGRasterizationError.unsupportedDocumentSemantics
            }
            style.fillOpacity = CGFloat(value)
        }
        if let rule = attributes["fill-rule"] {
            switch rule {
            case "nonzero": style.fillRule = .nonzero
            case "evenodd": style.fillRule = .evenOdd
            default: throw SVGRasterizationError.unsupportedDocumentSemantics
            }
        }
        return (style, attributes.filter { allowedGeometry.contains($0.key) })
    }

    private func rejectUnknownAttributes(
        _ attributes: [String: String],
        allowed: Set<String>
    ) throws {
        guard attributes.keys.allSatisfy({ allowed.contains($0) }) else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        if let id = attributes["id"], id.utf8.count > 256 {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
    }

    private func parsePaint(_ raw: String) throws -> Paint {
        switch raw {
        case "none": return .none
        case "black": return .rgba(0, 0, 0, 1)
        case "white": return .rgba(1, 1, 1, 1)
        case "red": return .rgba(1, 0, 0, 1)
        case "green": return .rgba(0, 0.5, 0, 1)
        case "blue": return .rgba(0, 0, 1, 1)
        case "transparent": return .rgba(0, 0, 0, 0)
        default:
            guard raw.first == "#" else {
                throw SVGRasterizationError.unsupportedDocumentSemantics
            }
            let hex = String(raw.dropFirst())
            if hex.count == 3 {
                let values = try hex.map { try hexNibble($0) }
                return .rgba(
                    CGFloat(values[0] * 17) / 255,
                    CGFloat(values[1] * 17) / 255,
                    CGFloat(values[2] * 17) / 255,
                    1
                )
            }
            if hex.count == 6 {
                let chars = Array(hex)
                let r = try hexByte(chars[0], chars[1])
                let g = try hexByte(chars[2], chars[3])
                let b = try hexByte(chars[4], chars[5])
                return .rgba(CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1)
            }
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
    }

    private func hexNibble(_ character: Character) throws -> UInt8 {
        guard let value = character.hexDigitValue, value < 16 else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        return UInt8(value)
    }

    private func hexByte(_ high: Character, _ low: Character) throws -> UInt8 {
        try hexNibble(high) * 16 + hexNibble(low)
    }

    private func apply(style: Style, to context: CGContext, draw: () -> Void) throws {
        switch style.paint {
        case .none:
            return
        case .rgba(let red, let green, let blue, let alpha):
            let finalAlpha = alpha * style.fillOpacity
            guard finalAlpha.isFinite, finalAlpha >= 0, finalAlpha <= 1 else {
                throw SVGRasterizationError.unsupportedDocumentSemantics
            }
            context.setFillColor(red: red, green: green, blue: blue, alpha: finalAlpha)
            draw()
        }
    }

    private func parseLength(_ raw: String) throws -> Double {
        if raw.hasSuffix("px") {
            return try parseNumber(String(raw.dropLast(2)))
        }
        return try parseNumber(raw)
    }

    private func parseNumber(_ raw: String) throws -> Double {
        guard !raw.isEmpty, raw.utf8.count <= 128, let value = Double(raw), value.isFinite else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        try validateCoordinate(value)
        return value
    }

    private func numberList(_ raw: String, exactCount: Int) throws -> [Double] {
        let tokens = raw.split { character in
            character == "," || character.isWhitespace
        }
        guard tokens.count == exactCount else {
            throw SVGRasterizationError.viewBoxInvalid
        }
        return try tokens.map { try parseNumber(String($0)) }
    }

    private func validateRect(x: Double, y: Double, width: Double, height: Double) throws {
        try validateCoordinate(x)
        try validateCoordinate(y)
        try validateCoordinate(width)
        try validateCoordinate(height)
        try validateCoordinate(x + width)
        try validateCoordinate(y + height)
    }

    private func validateCoordinate(_ value: Double) throws {
        guard value.isFinite, abs(value) <= limits.maximumCoordinateMagnitude else {
            throw SVGRasterizationError.coordinateLimitExceeded
        }
    }
}

private struct SVGPathDataParser {
    private enum PreviousSegment {
        case other
        case cubic
        case quadratic
    }

    private let bytes: [UInt8]
    private let maximumCoordinateMagnitude: Double
    private let remainingCommandBudget: Int
    private var index = 0
    private var currentCommand: UInt8?
    private var currentPoint = CGPoint.zero
    private var subpathStart = CGPoint.zero
    private var hasMove = false
    private var lastCubicControl: CGPoint?
    private var lastQuadraticControl: CGPoint?
    private var previousSegment: PreviousSegment = .other
    private let path = CGMutablePath()
    private(set) var commandCount = 0

    init(text: String, maximumCoordinateMagnitude: Double, remainingCommandBudget: Int) {
        self.bytes = Array(text.utf8)
        self.maximumCoordinateMagnitude = maximumCoordinateMagnitude
        self.remainingCommandBudget = max(0, remainingCommandBudget)
    }

    mutating func parse() throws -> CGPath {
        guard bytes.allSatisfy({ $0 < 0x80 }) else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        while true {
            skipSeparators()
            guard index < bytes.count else { break }
            let byte = bytes[index]
            if isCommand(byte) {
                currentCommand = byte
                index += 1
            } else if currentCommand == nil {
                throw SVGRasterizationError.unsupportedDocumentSemantics
            }
            guard let command = currentCommand else {
                throw SVGRasterizationError.unsupportedDocumentSemantics
            }
            try execute(command)
        }
        guard hasMove, commandCount > 0 else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        return path.copy() ?? path
    }

    private mutating func execute(_ command: UInt8) throws {
        let relative = command >= 0x61 && command <= 0x7A
        switch command | 0x20 {
        case 0x6D: // m
            let first = try readPoint(relative: relative)
            try countCommand()
            path.move(to: first)
            currentPoint = first
            subpathStart = first
            hasMove = true
            resetControls()
            while hasNumberAhead() {
                let point = try readPoint(relative: relative)
                try countCommand()
                path.addLine(to: point)
                currentPoint = point
                resetControls()
            }
            currentCommand = relative ? 0x6C : 0x4C // subsequent coordinate pairs are lineto
        case 0x6C: // l
            try requireMove()
            try requireAtLeastOneNumberGroup()
            repeat {
                let point = try readPoint(relative: relative)
                try countCommand()
                path.addLine(to: point)
                currentPoint = point
                resetControls()
            } while hasNumberAhead()
        case 0x68: // h
            try requireMove()
            try requireAtLeastOneNumberGroup()
            repeat {
                let value = try readNumber()
                let x = try coordinate(relative ? Double(currentPoint.x) + value : value)
                let point = CGPoint(x: x, y: currentPoint.y)
                try countCommand()
                path.addLine(to: point)
                currentPoint = point
                resetControls()
            } while hasNumberAhead()
        case 0x76: // v
            try requireMove()
            try requireAtLeastOneNumberGroup()
            repeat {
                let value = try readNumber()
                let y = try coordinate(relative ? Double(currentPoint.y) + value : value)
                let point = CGPoint(x: currentPoint.x, y: y)
                try countCommand()
                path.addLine(to: point)
                currentPoint = point
                resetControls()
            } while hasNumberAhead()
        case 0x63: // c
            try requireMove()
            try requireAtLeastOneNumberGroup()
            repeat {
                let c1 = try readPoint(relative: relative)
                let c2 = try readPoint(relative: relative)
                let end = try readPoint(relative: relative)
                try countCommand()
                path.addCurve(to: end, control1: c1, control2: c2)
                currentPoint = end
                lastCubicControl = c2
                lastQuadraticControl = nil
                previousSegment = .cubic
            } while hasNumberAhead()
        case 0x73: // s
            try requireMove()
            try requireAtLeastOneNumberGroup()
            repeat {
                let reflected = try reflectedCubicControl()
                let c2 = try readPoint(relative: relative)
                let end = try readPoint(relative: relative)
                try countCommand()
                path.addCurve(to: end, control1: reflected, control2: c2)
                currentPoint = end
                lastCubicControl = c2
                lastQuadraticControl = nil
                previousSegment = .cubic
            } while hasNumberAhead()
        case 0x71: // q
            try requireMove()
            try requireAtLeastOneNumberGroup()
            repeat {
                let control = try readPoint(relative: relative)
                let end = try readPoint(relative: relative)
                try countCommand()
                path.addQuadCurve(to: end, control: control)
                currentPoint = end
                lastQuadraticControl = control
                lastCubicControl = nil
                previousSegment = .quadratic
            } while hasNumberAhead()
        case 0x74: // t
            try requireMove()
            try requireAtLeastOneNumberGroup()
            repeat {
                let control = try reflectedQuadraticControl()
                let end = try readPoint(relative: relative)
                try countCommand()
                path.addQuadCurve(to: end, control: control)
                currentPoint = end
                lastQuadraticControl = control
                lastCubicControl = nil
                previousSegment = .quadratic
            } while hasNumberAhead()
        case 0x7A: // z
            try requireMove()
            try countCommand()
            path.closeSubpath()
            currentPoint = subpathStart
            resetControls()
            currentCommand = nil
        default:
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
    }

    private mutating func readPoint(relative: Bool) throws -> CGPoint {
        let xValue = try readNumber()
        let yValue = try readNumber()
        let x = try coordinate(relative ? Double(currentPoint.x) + xValue : xValue)
        let y = try coordinate(relative ? Double(currentPoint.y) + yValue : yValue)
        return CGPoint(x: x, y: y)
    }

    private mutating func readNumber() throws -> Double {
        skipSeparators()
        let start = index
        if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
        var digits = 0
        while index < bytes.count, isDigit(bytes[index]) {
            index += 1
            digits += 1
        }
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            while index < bytes.count, isDigit(bytes[index]) {
                index += 1
                digits += 1
            }
        }
        guard digits > 0 else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            let exponentStart = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            guard index > exponentStart else {
                throw SVGRasterizationError.unsupportedDocumentSemantics
            }
        }
        guard let raw = String(bytes: bytes[start..<index], encoding: .utf8),
            let value = Double(raw), value.isFinite
        else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
        _ = try coordinate(value)
        return value
    }

    private mutating func requireAtLeastOneNumberGroup() throws {
        guard hasNumberAhead() else {
            throw SVGRasterizationError.unsupportedDocumentSemantics
        }
    }

    private mutating func hasNumberAhead() -> Bool {
        let saved = index
        skipSeparators()
        defer { index = saved }
        guard index < bytes.count else { return false }
        let byte = bytes[index]
        return isDigit(byte) || byte == 0x2B || byte == 0x2D || byte == 0x2E
    }

    private mutating func skipSeparators() {
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x2C || byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            } else {
                break
            }
        }
    }

    private mutating func countCommand() throws {
        guard commandCount < remainingCommandBudget else {
            throw SVGRasterizationError.pathCommandLimitExceeded
        }
        commandCount += 1
    }

    private func requireMove() throws {
        guard hasMove else { throw SVGRasterizationError.unsupportedDocumentSemantics }
    }

    private mutating func resetControls() {
        lastCubicControl = nil
        lastQuadraticControl = nil
        previousSegment = .other
    }

    private func reflectedCubicControl() throws -> CGPoint {
        guard previousSegment == .cubic, let previous = lastCubicControl else {
            return currentPoint
        }
        return try reflectedControl(previous: previous)
    }

    private func reflectedQuadraticControl() throws -> CGPoint {
        guard previousSegment == .quadratic, let previous = lastQuadraticControl else {
            return currentPoint
        }
        return try reflectedControl(previous: previous)
    }

    private func reflectedControl(previous: CGPoint) throws -> CGPoint {
        CGPoint(
            x: try boundedReflectedCoordinate(current: currentPoint.x, previous: previous.x),
            y: try boundedReflectedCoordinate(current: currentPoint.y, previous: previous.y)
        )
    }

    private func boundedReflectedCoordinate(current: CGFloat, previous: CGFloat) throws -> CGFloat {
        let reflected = Double(current) * 2 - Double(previous)
        return try coordinate(reflected)
    }

    private func coordinate(_ value: Double) throws -> CGFloat {
        guard value.isFinite, abs(value) <= maximumCoordinateMagnitude else {
            throw SVGRasterizationError.coordinateLimitExceeded
        }
        let result = CGFloat(value)
        guard result.isFinite else { throw SVGRasterizationError.coordinateLimitExceeded }
        return result
    }

    private func isCommand(_ byte: UInt8) -> Bool {
        switch byte | 0x20 {
        case 0x6D, 0x6C, 0x68, 0x76, 0x63, 0x73, 0x71, 0x74, 0x7A:
            return true
        default:
            return false
        }
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }
}
