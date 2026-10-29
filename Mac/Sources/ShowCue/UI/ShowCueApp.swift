import SwiftUI
import AppKit

@main
struct ShowCueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("ShowCue", id: "main") {
            Themed { MainView() }
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.audio)
                .environmentObject(delegate.model.output)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1400, height: 880)
        .commands { ShowCommands(model: delegate.model) }

        Window("Lydpatch", id: "patch") {
            Themed { PatchView() }
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.audio)
        }
        .defaultSize(width: 1000, height: 620)

        Settings {
            Themed { SettingsView() }
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.audio)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        model.startup()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return KeyHandler.handle(e, model: self.model) ? nil : e
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !model.engine.active.isEmpty {
            let a = NSAlert()
            a.messageText = "Cuer spiller fortsatt. Vil du avslutte?"
            a.addButton(withTitle: "Avslutt")
            a.addButton(withTitle: "Avbryt")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        guard model.confirmDiscard() else { return .terminateCancel }
        model.engine.stopAll(fade: 0)
        model.audio.stop()
        model.settings.save()
        return .terminateNow
    }
}

/// Tastatur: Mellomrom = GO, Esc = stopp alt, piler = markør, hurtigtaster. Bare i hovedvinduet,
/// og ikke mens man skriver i et felt (unntatt Esc og F-tastene).
enum KeyHandler {
    private static let fKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    private static let numpad: [UInt16: String] = [
        82: "NUM0", 83: "NUM1", 84: "NUM2", 85: "NUM3", 86: "NUM4", 87: "NUM5", 88: "NUM6", 89: "NUM7", 91: "NUM8", 92: "NUM9",
    ]

    /// Navn på tasten slik den lagres (samme som Windows-versjonen: F1, A, 1, NUM1).
    static func keyName(_ e: NSEvent) -> String? {
        if let f = fKeys[e.keyCode] { return f }
        if let n = numpad[e.keyCode] { return n }
        guard let ch = e.charactersIgnoringModifiers?.uppercased(), ch.count == 1, let s = ch.unicodeScalars.first else { return nil }
        if ("A"..."Z").contains(String(ch)) || ("0"..."9").contains(String(ch)) { return String(s) }
        return nil
    }

    static func handle(_ e: NSEvent, model m: AppModel) -> Bool {
        guard let win = NSApp.keyWindow else { return false }
        // Hovedvinduet = alt som ikke er lydpatch, innstillinger eller utgangsvinduet.
        let wid = win.identifier?.rawValue.lowercased() ?? ""
        let isMain = !wid.hasPrefix("patch") && !wid.contains("settings") && win.title != "ShowCue – utgang" && !(win is NSPanel)
        let flags = e.modifierFlags.intersection([.command, .control, .option])
        let editing = (win.firstResponder as? NSTextView)?.isEditable ?? false

        // Venter på ny hurtigtast for en cue
        if let c = m.hotkeyCapture, isMain {
            m.hotkeyCapture = nil
            switch e.keyCode {
            case 53: break // Esc: avbryt
            case 51, 117: c.hotkey = ""
            default:
                if let name = keyName(e) {
                    if let other = m.cues.first(where: { $0 !== c && $0.hotkey == name }) {
                        other.hotkey = ""
                        m.statusText = "Hurtigtast \(name) flyttet fra cue \(other.number)."
                    }
                    c.hotkey = name
                }
            }
            return true
        }

        if e.keyCode == 53 { // Esc
            guard isMain else { return false }
            if m.router.isLearning { m.cancelLearn() }
            m.panic()
            if editing { win.makeFirstResponder(nil) }
            return true
        }
        guard isMain, flags.isEmpty else { return false }

        if editing {
            // F-tastene virker også mens man skriver.
            if let f = fKeys[e.keyCode] { return m.fireHotkey(f) }
            return false
        }

        switch e.keyCode {
        case 49: m.go(); return true                          // Mellomrom
        case 126: m.movePlayhead(-1); return true             // ↑
        case 125: m.movePlayhead(1); return true              // ↓
        case 115: m.select(m.cues.first); return true         // Home
        case 51, 117: m.deleteSelected(); return true         // ⌫ / Delete
        default: break
        }
        if let name = keyName(e) { return m.fireHotkey(name) }
        return false
    }
}

struct ShowCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nytt show") { model.newShow() }.keyboardShortcut("n")
            Button("Åpne …") { model.openDialog() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Lagre") { model.save(as: false) }.keyboardShortcut("s")
            Button("Lagre som …") { model.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandMenu("Cue") {
            Button("GO (Mellomrom)") { model.go() }
            Button("Stopp alt (Esc)") { model.panic() }
            Divider()
            Button("Ny lyd-cue …") { model.add(.audio) }.keyboardShortcut("1")
            Button("Ny video-cue …") { model.add(.video) }.keyboardShortcut("2")
            Button("Ny bilde-cue …") { model.add(.image) }.keyboardShortcut("3")
            Button("Ny PDF-cue …") { model.add(.pdf) }.keyboardShortcut("4")
            Button("Ny fade-cue") { model.add(.fade) }.keyboardShortcut("5")
            Button("Ny stopp-cue") { model.add(.stop) }.keyboardShortcut("6")
            Button("Ny OSC-cue") { model.add(.osc) }.keyboardShortcut("7")
            Button("Ny MIDI-cue") { model.add(.midi) }.keyboardShortcut("8")
            Divider()
            Button("Dupliser") { model.duplicateSelected() }.keyboardShortcut("d")
            Button("Slett") { model.deleteSelected() }.keyboardShortcut(.delete)
            Button("Flytt opp") { model.moveSelected(-1) }.keyboardShortcut(.upArrow)
            Button("Flytt ned") { model.moveSelected(1) }.keyboardShortcut(.downArrow)
            Button("Nummerer alle …") { model.renumber() }
            Divider()
            Button("Vis/skjul utgang") { model.output.toggle() }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Bytt tema") { model.settings.theme = model.settings.theme.next }.keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}
