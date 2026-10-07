import AppKit

/// Text (+ optional icon) cell with a heat-map background tint.
final class HeatCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private var heatAlpha: CGFloat = 0

    private static let regular = NSFont.systemFont(ofSize: 12)
    private static let digits = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    /// Same for every font used here (12 pt system); avoids a text measurement per layout.
    private static let labelHeight: CGFloat = ceil(NSTextField(labelWithString: "Ag").intrinsicContentSize.height)
    private static let bold = NSFont.systemFont(ofSize: 12, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        needsLayout = true
        addSubview(iconView)
        addSubview(label)
        textField = label
        imageView = iconView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = heatAlpha > 0
                ? NSColor.systemOrange.withAlphaComponent(heatAlpha).cgColor : nil
        }
    }

    private var currentAlignment: NSTextAlignment = .natural
    private var currentFont: NSFont?
    private var currentTooltip: String?
    private var currentIcon: NSImage?

    func configure(text: String, icon: NSImage?, showsIcon: Bool, heat: Float, alignment: NSTextAlignment,
                   isGroup: Bool, monospaced: Bool, tooltip: String?, accessibility: @autoclosure () -> String) {
        var relayout = false
        if label.stringValue != text {
            label.stringValue = text
            setAccessibilityLabel(accessibility())
        }
        if currentAlignment != alignment { currentAlignment = alignment; label.alignment = alignment }
        let font = isGroup ? Self.bold : (monospaced ? Self.digits : Self.regular)
        if currentFont !== font { currentFont = font; label.font = font; relayout = true }
        if currentIcon !== icon { currentIcon = icon; iconView.image = icon }
        let hasIcon = showsIcon && icon != nil
        if iconView.isHidden == hasIcon { iconView.isHidden = !hasIcon; relayout = true }
        let alpha: CGFloat = heat > 0 ? 0.10 + 0.55 * CGFloat(min(heat, 1)) : 0
        if alpha != heatAlpha {
            heatAlpha = alpha
            needsDisplay = true
        }
        if currentTooltip != tooltip { currentTooltip = tooltip; toolTip = tooltip }
        if relayout { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 4
        if !iconView.isHidden {
            iconView.frame = CGRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
            x += 20
        }
        let lh = Self.labelHeight
        label.frame = CGRect(x: x, y: (h - lh) / 2, width: max(0, bounds.width - x - 4), height: lh)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Outline view that surfaces Delete / Return key presses.
final class ActionOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?()
        case 36, 76: onReturn?()
        default: super.keyDown(with: event)
        }
    }
}

final class TableNode {
    let id: NodeID
    var data: TableRowData
    var children: [TableNode]

    init(data: TableRowData) {
        self.id = data.id
        self.data = data
        self.children = data.children.map(TableNode.init)
    }
}

/// Row view whose VoiceOver label is computed on demand from the live node (never stale, no per-tick cost).
final class SummaryRowView: NSTableRowView {
    weak var node: TableNode?
    var summarize: ((TableNode) -> String)?

    override func accessibilityLabel() -> String? {
        guard let node else { return nil }
        return summarize?(node)
    }
}
