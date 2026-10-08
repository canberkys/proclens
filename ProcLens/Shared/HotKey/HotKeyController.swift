import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon `RegisterEventHotKey` (no dependencies, no Accessibility permission needed).
/// Stored in UserDefaults as `hotKeyCode` / `hotKeyMods` (Carbon modifier mask) / `hotKeyLabel`; code -1 = disabled.
@MainActor
final class HotKeyController {
    static let shared = HotKeyController()
    static let defaultCode = Int(kVK_ANSI_P)
    static let defaultMods = Int(controlKey | optionKey | cmdKey)   // ⌃⌥⌘P (⌥⌘⎋ is system Force Quit)

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var open: (() -> Void)?

    /// Call once at launch. `open` brings up the main window.
    func start(open: @escaping () -> Void) {
        self.open = open
        installHandlerIfNeeded()
        registerStored()
    }

    /// Stores and (re)registers a new combination; `code < 0` disables the hotkey.
    func set(code: Int, mods: Int, label: String) {
        let d = UserDefaults.standard
        d.set(code, forKey: "hotKeyCode"); d.set(mods, forKey: "hotKeyMods"); d.set(label, forKey: "hotKeyLabel")
        registerStored()
    }

    static var storedCode: Int { UserDefaults.standard.object(forKey: "hotKeyCode") as? Int ?? defaultCode }
    static var storedMods: Int { UserDefaults.standard.object(forKey: "hotKeyMods") as? Int ?? defaultMods }
    static var storedLabel: String { UserDefaults.standard.string(forKey: "hotKeyLabel") ?? display(mods: defaultMods, key: "P") }

    static func display(mods: Int, key: String) -> String {
        var s = ""
        if mods & controlKey != 0 { s += "⌃" }
        if mods & optionKey != 0 { s += "⌥" }
        if mods & shiftKey != 0 { s += "⇧" }
        if mods & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    private func registerStored() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        let code = Self.storedCode
        guard code >= 0 else { return }
        let id = EventHotKeyID(signature: OSType(0x504C4E53), id: 1)   // 'PLNS'
        RegisterEventHotKey(UInt32(code), UInt32(Self.storedMods), id, GetApplicationEventTarget(), 0, &ref)
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKeyController.shared.open?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

extension NSEvent.ModifierFlags {
    var carbonMask: Int {
        var m = 0
        if contains(.command) { m |= cmdKey }
        if contains(.option) { m |= optionKey }
        if contains(.control) { m |= controlKey }
        if contains(.shift) { m |= shiftKey }
        return m
    }
}
