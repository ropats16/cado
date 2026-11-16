import SwiftUI

// The Settings window's building blocks in Cado's brand (#18): a titled
// card per section, a label-and-control row, and the tone of a status line.

/// A section: a rounded headline with its symbol, over a `surface` card.
struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(Brand.Palette.accent)
                    .frame(width: 20)   // titles line up whatever the symbol's width
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(Brand.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            .font(Brand.Typography.headline)
            .padding(.leading, 2)

            SettingsCard { content }
        }
    }
}

/// A section's `surface` card on its own, without the headline.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Brand.Palette.ink.opacity(contrast == .increased ? 0.45 : 0.1)))
    }
}

/// One line of a card: the label on the left, its control on the right.
/// The label is for sight only; the control keeps its own (identical)
/// accessibility label, so VoiceOver reads each setting once.
struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(Brand.Palette.ink)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            control.labelsHidden()
        }
        .settingsRowPadding()
    }
}

/// A hairline between a card's rows.
struct CardDivider: View {
    var body: some View { Divider().overlay(Brand.Palette.ink.opacity(0.06)) }
}

/// A hint or status line under a setting. Problems carry a symbol as well as
/// the colour, so they don't rely on colour alone.
struct StatusLine: View {
    enum Tone { case note, problem, live }

    let text: String
    var tone: Tone = .note

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch tone {
            case .note: EmptyView()
            case .problem: Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
            case .live: Image(systemName: "record.circle").accessibilityHidden(true)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Brand.Typography.caption)
        .foregroundStyle(tone == .note ? Brand.Palette.inkSecondary : Brand.Palette.pulse)
        .textSelection(.enabled)
    }
}

extension View {
    /// A card row's vertical rhythm.
    func settingsRowPadding() -> some View { padding(.vertical, 8) }
}
