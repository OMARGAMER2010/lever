import AppKit
import LeverCore

/// El botón de Lever pegado debajo del menú lateral del emulador de Android.
///
/// Ese menú es una ventana del emulador de Google y no admite botones de nadie. Así que Lever pone
/// el suyo justo debajo, con el mismo ancho, y lo lleva pegado mirando dónde está esa ventana: una
/// vez por segundo si no hay emulador, cuatro si lo hay, y treinta mientras se mueve. Mirar no
/// pide ningún permiso: los marcos de las ventanas los da el sistema a cualquiera.
@MainActor
final class EmulatorSideButtonController: NSObject {
    private weak var model: AppModel?
    private var panel: NSPanel?
    private var button: NSButton?
    private var current: EmulatorWindows?
    private var followFastUntil = Date.distantPast
    private var activity: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func start() {
        schedule(after: 0.5)
    }

    private func schedule(after interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let listing = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = listing.compactMap { EmulatorWindowLayout.WindowInfo($0) }
        guard let emulator = EmulatorWindowLayout.emulators(in: windows).first,
              let screen = screen(containing: emulator.toolbar) else {
            hide()
            schedule(after: 1)
            return
        }
        if emulator.toolbar != current?.toolbar {
            followFastUntil = Date().addingTimeInterval(0.6)
        }
        current = emulator
        let frame = EmulatorWindowLayout.buttonFrame(for: emulator.toolbar, within: quartzFrame(of: screen))
        show(at: cocoaRect(fromQuartz: frame), above: emulator.toolbarNumber, in: windows)
        schedule(after: Date() < followFastUntil ? 1.0 / 30 : 0.25)
    }

    private func show(at frame: CGRect, above toolbarNumber: Int, in windows: [EmulatorWindowLayout.WindowInfo]) {
        let panel = self.panel ?? makePanel()
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        button?.toolTip = model?.strings[.androidFullscreenHelp]
        // El listado va de delante atrás. Si el botón quedó detrás del menú —otra app se puso en
        // medio y luego volvió el emulador—, se vuelve a poner justo encima de él.
        let behind: Bool
        if let mine = windows.firstIndex(where: { $0.number == panel.windowNumber }),
           let theirs = windows.firstIndex(where: { $0.number == toolbarNumber }) {
            behind = mine > theirs
        } else {
            behind = true
        }
        if !panel.isVisible || behind {
            panel.order(.above, relativeTo: toolbarNumber)
        }
        // Con el emulador a la vista, macOS no debe dormir a Lever: el botón se quedaría atrás.
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Lever sigue al menú lateral del emulador"
            )
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        current = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 54, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .transient]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true

        let title = model?.strings[.androidFullscreen] ?? ""
        let symbol = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        let button = FirstClickButton(image: symbol ?? NSImage(), target: self, action: #selector(pressed))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = model?.strings[.androidFullscreenHelp]
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            button.topAnchor.constraint(equalTo: background.topAnchor),
            button.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        panel.contentView = background
        self.panel = panel
        self.button = button
        return panel
    }

    @objc private func pressed() {
        guard let model, let current else { return }
        AndroidFullscreenPresenter.shared.present(model: model, emulatorPID: current.pid, screen: screen(containing: current.main))
    }

    // MARK: - Coordenadas

    /// Quartz tiene el origen arriba a la izquierda de la pantalla principal; AppKit, abajo.
    private func cocoaRect(fromQuartz rect: CGRect) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func quartzFrame(of screen: NSScreen) -> CGRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let frame = screen.frame
        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    private func screen(containing quartzRect: CGRect) -> NSScreen? {
        let rect = cocoaRect(fromQuartz: quartzRect)
        return NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
    }
}

/// Un botón que responde al primer clic aunque Lever no esté delante: sin esto, el primer clic
/// solo serviría para activar el panel.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
