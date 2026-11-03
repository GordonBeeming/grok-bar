import AppKit
import GrokBarCore
import SwiftUI

@MainActor
enum MenuBarIconRenderer {
    private static let height: CGFloat = 18

    static let strongFlameColor = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        if match == .darkAqua || match == .vibrantDark {
            return NSColor(srgbRed: 0.95, green: 0.26, blue: 0.21, alpha: 1)
        }
        return NSColor(srgbRed: 0.75, green: 0.12, blue: 0.12, alpha: 1)
    }
    static let lightFlameColor = NSColor.systemOrange

    static func image(percent: Int?, severity: Severity, flameColor: NSColor?) -> NSImage {
        let symbol = mark()
        let flameSymbol = (percent != nil ? flameColor : nil).flatMap { flameImage(color: $0) }
        let isTemplate = severity == .normal && flameSymbol == nil
        let tint = tintColor(for: severity)
        let renderedSymbol = isTemplate ? symbol : tinted(symbol, color: tint)
        let text = percent.map { " \($0)%" }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let textColor: NSColor = isTemplate ? .labelColor : tint
        let attributedText = text.map {
            NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: textColor])
        }

        let symbolSize = renderedSymbol.size
        let textSize = attributedText?.size() ?? .zero
        let flameSize = flameSymbol?.size ?? .zero
        let spacing: CGFloat = attributedText == nil ? 0 : 2
        let flameSpacing: CGFloat = flameSymbol == nil ? 0 : 2
        let width = symbolSize.width + spacing + textSize.width + flameSpacing + flameSize.width

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            renderedSymbol.draw(
                at: NSPoint(x: 0, y: (height - symbolSize.height) / 2),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            attributedText?.draw(at: NSPoint(x: symbolSize.width + spacing, y: (height - textSize.height) / 2))
            flameSymbol?.draw(
                at: NSPoint(
                    x: symbolSize.width + spacing + textSize.width + flameSpacing,
                    y: (height - flameSize.height) / 2
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        image.isTemplate = isTemplate
        var description = ["Grok usage"]
        if let percent { description.append("\(percent) percent") }
        if flameSymbol != nil { description.append("ahead of pace") }
        image.accessibilityDescription = description.joined(separator: ", ")
        return image
    }

    /// Template mark for the menu bar. The Grok name and xAI logomark stay xAI's; this glyph is ours.
    private static func mark() -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Grok usage")?
            .withSymbolConfiguration(configuration)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private static func flameImage(color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let base = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Ahead of pace")?
            .withSymbolConfiguration(configuration) else { return nil }
        return tinted(base, color: color)
    }

    private static func tintColor(for severity: Severity) -> NSColor {
        switch severity {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            color.set()
            image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

struct MenuBarLabelView: View {
    let model: UsageViewModel
    let settings: AppSettings
    let celebrations: CelebrationController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let displayedLimit = menuBarLimit(
            in: model.limits,
            selectedID: settings.menuBarPercentageSelection.limitID
        )
        let percent = displayedLimit.map { Int(settings.usageDisplayMode.displayPercent(usedPercent: $0.percent).rounded()) }
        Image(nsImage: MenuBarIconRenderer.image(
            percent: percent,
            severity: displayedLimit.map { settings.thresholds.resolve(for: $0) } ?? .normal,
            flameColor: flameColor
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Grok usage")
        .accessibilityValue(menuBarValue(percent: percent))
        .onReceive(NotificationCenter.default.publisher(for: .grokBarOpenSettings)) { _ in
            openSettings()
        }
    }

    private func menuBarValue(percent: Int?) -> String {
        var parts: [String] = []
        if let percent { parts.append("\(percent) percent") }
        if flameColor != nil { parts.append("ahead of pace") }
        return parts.joined(separator: ", ")
    }

    private var flameColor: NSColor? {
        guard settings.showMenuBarFlame else { return nil }
        let now = Date()
        let overPace = model.limits.filter { UsageWindow.isAheadOfPace(for: $0, now: now) }
        guard !overPace.isEmpty else { return nil }
        return overPace.contains { $0.group == "weekly" }
            ? MenuBarIconRenderer.strongFlameColor
            : MenuBarIconRenderer.lightFlameColor
    }
}
