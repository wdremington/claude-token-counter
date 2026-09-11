import SwiftUI

extension View {
    /// The panel surface every section of the dashboard sits on.
    func card(padding: CGFloat = 14, cornerRadius: CGFloat = 10) -> some View {
        self
            .padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

/// A titled block inside a settings pane.
struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            content
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// A dollar amount that can be switched off entirely.
struct OptionalAmountField: View {
    let label: String
    @Binding var value: Double?
    var placeholder = "0.00"

    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Toggle(label, isOn: Binding(
                get: { value != nil },
                set: { value = $0 ? (Double(text) ?? 0) : nil }
            ))
            .toggleStyle(.checkbox)
            .frame(width: 90, alignment: .leading)

            Text("$")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .disabled(value == nil)
                .onSubmit(commit)
                .onChange(of: text) { _, _ in commit() }
        }
        .onAppear { text = value.map { Self.format($0) } ?? "" }
        .onChange(of: value) { _, new in
            // Only adopt an external change; echoing our own would fight typing.
            if let new, Double(text) != new { text = Self.format(new) }
        }
    }

    private func commit() {
        guard value != nil else { return }
        if let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed >= 0 {
            value = parsed
        }
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }
}
