import AppKit

/// Keep the document untouched: this material is only for window chrome and floating controls.
@MainActor
final class NativeGlassView: NSView {
    enum MaterialKind: Equatable { case liquidGlass, visualEffect, opaque }

    let contentView = NSView()
    private(set) var materialKind: MaterialKind?
    private let cornerRadius: CGFloat
    private let interactive: Bool
    private let legacyMaterial: NSVisualEffectView.Material
    private let allowsLiquidGlass: Bool
    private let reduceTransparency: () -> Bool
    private var backdrop: NSView?
    private var accessibilityObserver: NSObjectProtocol?

    init(cornerRadius: CGFloat = 20, interactive: Bool = true,
         legacyMaterial: NSVisualEffectView.Material = .hudWindow,
         allowsLiquidGlass: Bool = true,
         reduceTransparency: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }) {
        self.cornerRadius = cornerRadius
        self.interactive = interactive
        self.legacyMaterial = legacyMaterial
        self.allowsLiquidGlass = allowsLiquidGlass
        self.reduceTransparency = reduceTransparency
        super.init(frame: .zero)
        refreshMaterial()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMaterial() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    func refreshMaterial() {
        let kind: MaterialKind
        if reduceTransparency() { kind = .opaque }
        else if #available(macOS 26.0, *), allowsLiquidGlass { kind = .liquidGlass }
        else { kind = .visualEffect }
        guard materialKind != kind else { updateOpaqueColor(); return }

        contentView.removeFromSuperview()
        backdrop?.removeFromSuperview()
        let background: NSView
        if #available(macOS 26.0, *), kind == .liquidGlass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            if #available(macOS 27.0, *) { glass.effectIsInteractive = interactive }
            glass.contentView = contentView
            background = glass
        } else if kind == .visualEffect {
            let effect = NSVisualEffectView()
            effect.material = legacyMaterial
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.addSubview(contentView)
            background = effect
        } else {
            background = NSView()
            background.wantsLayer = true
            background.layer?.cornerRadius = cornerRadius
            background.layer?.masksToBounds = true
            background.addSubview(contentView)
        }
        addSubview(background)
        background.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: background.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        backdrop = background
        materialKind = kind
        updateOpaqueColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateOpaqueColor()
    }

    private func updateOpaqueColor() {
        guard materialKind == .opaque else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backdrop?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

@MainActor
enum NativeUI {
    static func styleAction(_ button: NSButton, prominent: Bool = false) {
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.tintProminence = prominent ? .primary : .none
        }
        else { button.bezelStyle = .rounded }
        button.controlSize = .large
        if prominent { button.bezelColor = .controlAccentColor }
        button.setAccessibilityLabel(button.title)
    }

    static func symbol(_ name: String, description: String? = nil) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: description)!)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        view.contentTintColor = .secondaryLabelColor
        view.setAccessibilityElement(description != nil)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    static func prepareWindow(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
