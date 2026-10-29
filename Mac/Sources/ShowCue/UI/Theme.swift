import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Fargetema (samme paletter som Windows-versjonen).
struct Theme {
    let bg, panel, panel2, panel3, line, text, muted, faint: Color
    let go, goText, running, runningRow, wait, danger, playhead, playheadRow, rowAlt, gridLine: Color
    let tints: [CueColor: Color]
    let stripes: [CueColor: Color]
    let scheme: ColorScheme

    func tint(_ c: CueColor) -> Color? { tints[c] }
    func stripe(_ c: CueColor) -> Color? { stripes[c] }

    private static func colors(_ tint: [UInt32], _ stripe: [UInt32]) -> ([CueColor: Color], [CueColor: Color]) {
        let keys: [CueColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]
        var t: [CueColor: Color] = [:], s: [CueColor: Color] = [:]
        for (i, k) in keys.enumerated() { t[k] = Color(hex: tint[i]); s[k] = Color(hex: stripe[i]) }
        return (t, s)
    }

    static func of(_ t: AppTheme) -> Theme {
        switch t {
        case .dark:
            let (ti, st) = colors([0x4A2427, 0x4B3220, 0x46401F, 0x213D2B, 0x1F3450, 0x34284D, 0x33353A],
                                  [0xE5484D, 0xF0883E, 0xE8C547, 0x3FB66B, 0x4A8DF5, 0x9B6BF2, 0x8E9099])
            return Theme(bg: Color(hex: 0x1B1C1F), panel: Color(hex: 0x232428), panel2: Color(hex: 0x2B2D31), panel3: Color(hex: 0x35373C),
                         line: Color(hex: 0x3C3F45), text: Color(hex: 0xE9E9EB), muted: Color(hex: 0x9A9CA3), faint: Color(hex: 0x686B73),
                         go: Color(hex: 0x30B566), goText: Color(hex: 0x08160E), running: Color(hex: 0x34C46F), runningRow: Color(hex: 0x1E3A2A),
                         wait: Color(hex: 0xE8A33D), danger: Color(hex: 0xE5484D), playhead: Color(hex: 0x3D7EF5), playheadRow: Color(hex: 0x223556),
                         rowAlt: Color(hex: 0x26272B), gridLine: Color(hex: 0x2E3035), tints: ti, stripes: st, scheme: .dark)
        case .light:
            let (ti, st) = colors([0xF8D9DA, 0xFBE3CF, 0xF8F0C6, 0xD7F0DF, 0xD7E5FA, 0xE7DDF8, 0xE4E5E8],
                                  [0xD93A3F, 0xE07320, 0xCFA717, 0x2BA65C, 0x2F6FE4, 0x8452E0, 0x7C7F87])
            return Theme(bg: Color(hex: 0xE9EAEE), panel: Color(hex: 0xF6F6F8), panel2: Color(hex: 0xFFFFFF), panel3: Color(hex: 0xE6E7EB),
                         line: Color(hex: 0xD3D5DB), text: Color(hex: 0x1D1E22), muted: Color(hex: 0x5F636B), faint: Color(hex: 0x92969E),
                         go: Color(hex: 0x2BA65C), goText: .white, running: Color(hex: 0x239A55), runningRow: Color(hex: 0xDDF2E4),
                         wait: Color(hex: 0xB97510), danger: Color(hex: 0xD93A3F), playhead: Color(hex: 0x2F6FE4), playheadRow: Color(hex: 0xD9E6FD),
                         rowAlt: Color(hex: 0xF7F8FA), gridLine: Color(hex: 0xE6E7EB), tints: ti, stripes: st, scheme: .light)
        case .night:
            let (ti, st) = colors([0x2A1517, 0x2B1D12, 0x282412, 0x13241A, 0x121E2F, 0x1F182D, 0x1E1E22],
                                  [0xA8363A, 0xB06A30, 0xA8923A, 0x2F8A52, 0x3A6AB8, 0x7452B0, 0x6A6A72])
            return Theme(bg: Color(hex: 0x0A0A0B), panel: Color(hex: 0x101012), panel2: Color(hex: 0x151518), panel3: Color(hex: 0x1C1C20),
                         line: Color(hex: 0x232328), text: Color(hex: 0xA9A9AE), muted: Color(hex: 0x6E6E75), faint: Color(hex: 0x4A4A50),
                         go: Color(hex: 0x1F7A45), goText: Color(hex: 0x050B07), running: Color(hex: 0x2A9A57), runningRow: Color(hex: 0x12241A),
                         wait: Color(hex: 0xB07A2C), danger: Color(hex: 0xA8363A), playhead: Color(hex: 0x2F5DB8), playheadRow: Color(hex: 0x131E33),
                         rowAlt: Color(hex: 0x121214), gridLine: Color(hex: 0x18181B), tints: ti, stripes: st, scheme: .dark)
        }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.of(.dark)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Setter tema og fargeskjema ut fra innstillingene.
struct Themed<Content: View>: View {
    @EnvironmentObject var model: AppModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        let t = Theme.of(model.settings.theme)
        content()
            .environment(\.theme, t)
            .preferredColorScheme(t.scheme)
            .foregroundColor(t.text)
            .tint(t.playhead)
    }
}

// MARK: - Felles stiler

struct ToolButtonStyle: ButtonStyle {
    @Environment(\.theme) var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed ? theme.panel3 : Color.clear))
            .contentShape(Rectangle())
    }
}

struct PanelButtonStyle: ButtonStyle {
    @Environment(\.theme) var theme
    var fill: Color? = nil
    var foreground: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundColor(foreground ?? theme.text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(fill ?? theme.panel3))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(fill ?? theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

struct SectionHeader: View {
    @Environment(\.theme) var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.muted)
    }
}

struct FieldLabel: View {
    @Environment(\.theme) var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundColor(theme.muted).padding(.top, 8).padding(.bottom, 1)
    }
}

struct Hint: View {
    @Environment(\.theme) var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundColor(theme.faint).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
    }
}

/// Tekstfelt i temaets stil. Enter avslutter redigering (så Mellomrom igjen betyr GO).
struct StyledField: ViewModifier {
    @Environment(\.theme) var theme
    var mono = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 13))
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.line, lineWidth: 1))
            .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

extension View {
    func styledField(mono: Bool = false) -> some View { modifier(StyledField(mono: mono)) }
}

struct TextInput: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    init(_ text: Binding<String>, placeholder: String = "", mono: Bool = false) {
        _text = text; self.placeholder = placeholder; self.mono = mono
    }
    var body: some View { TextField(placeholder, text: $text).styledField(mono: mono) }
}

struct NumberInput: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = -1_000_000...1_000_000
    var body: some View {
        TextField("", value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
                  format: .number.precision(.fractionLength(0...2)))
            .styledField()
    }
}

struct IntInput: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = Int.min...Int.max
    var body: some View {
        TextField("", value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, $0)) }),
                  format: .number.grouping(.never))
            .styledField()
    }
}
