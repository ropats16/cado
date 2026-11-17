import SwiftUI
import AppKit

/// The onboarding window (#22): one step at a time — where you are, what
/// it's for, the step's own buttons — with Back and Continue below. Every
/// word and button comes from `OnboardingViewModel` (`OnboardingContent`);
/// this only lays them out, in Settings' cards and brand colours.
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    static let size = CGSize(width: 560, height: 560)

    var body: some View {
        let step = viewModel.step
        VStack(spacing: 0) {
            StepDots(steps: viewModel.content.steps, current: viewModel.current)
                .padding(.top, 28)

            // Centred; scrolls only if it can't fit (large text sizes).
            ViewThatFits(in: .vertical) {
                page(step)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView { page(step) }
            }

            navigation(step)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
                .padding(.top, 18)
        }
        .font(Brand.Typography.body)
        .tint(Brand.Palette.accent)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Brand.Palette.surface)
    }

    // MARK: - Parts

    private func page(_ step: OnboardingStep) -> some View {
        VStack(spacing: 12) {
            StepHero(step: step)
            Text(step.title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Brand.Palette.ink)
                .accessibilityAddTraits(.isHeader)
            if step.id == .ready, step.state == .done {
                readyLines(step)
                usagePingChoice
            } else {
                Text(step.detail)
                    .font(Brand.Typography.font(.body))
                    .foregroundStyle(Brand.Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !step.jumps.isEmpty { jumps(step) }
            if step.id == .ready, step.state != .done { usagePingChoice }
            if step.id == .model { modelChoice }
            status(step)
            if step.id != .ready, step.progress == nil,
               step.id != .model || step.primary == nil { stepButtons(step) }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }

    /// Ready's how-to, a line per row in a card.
    private func readyLines(_ step: OnboardingStep) -> some View {
        let lines = step.detail.split(separator: "\n").map(String.init)
        return SettingsCard {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if index > 0 { CardDivider() }
                Text(line)
                    .foregroundStyle(Brand.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowPadding()
            }
        }
    }

    /// Almost there: a row per step still needed, each back to it.
    private func jumps(_ step: OnboardingStep) -> some View {
        SettingsCard {
            ForEach(Array(step.jumps.enumerated()), id: \.offset) { index, jump in
                if index > 0 { CardDivider() }
                Button { viewModel.perform(jump.action) } label: {
                    HStack {
                        Text(jump.title).foregroundStyle(Brand.Palette.ink)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Brand.Palette.inkSecondary)
                            .accessibilityHidden(true)
                    }
                    .settingsRowPadding()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Ready's optional, off-by-default usage-count choice (#26).
    private var usagePingChoice: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A switch, as in Settings › General.
            Toggle(UsagePingCopy.title, isOn: Binding(
                get: { viewModel.usagePing },
                set: { viewModel.setUsagePing($0) }))
                .toggleStyle(.switch)
                .foregroundStyle(Brand.Palette.ink)
            Text(UsagePingCopy.onboardingDetail)
                .font(Brand.Typography.caption)
                .foregroundStyle(Brand.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// A download's progress beside its button (Cancel); what's happening
    /// (a spinner while it finishes by itself), or why it failed.
    @ViewBuilder
    private func status(_ step: OnboardingStep) -> some View {
        if let progress = step.progress {
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .frame(maxWidth: 240)
                    .accessibilityHidden(true)   // the note says it
                stepButtons(step)
            }
        }
        if let note = step.note {
            HStack(spacing: 8) {
                if step.state == .settling { ProgressView().controlSize(.small) }
                StatusLine(text: note, tone: viewModel.noteIsProblem ? .problem : .note)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func stepButtons(_ step: OnboardingStep) -> some View {
        if step.primary != nil || step.secondary != nil {
            HStack(spacing: 10) {
                if let secondary = step.secondary {
                    Button(secondary.title) { viewModel.perform(secondary.action) }
                }
                if let primary = step.primary {
                    // Prominent (and Return) while it's the thing to do.
                    if step.state == .todo {
                        Button(primary.title) { viewModel.perform(primary.action) }
                            .buttonStyle(OnboardingButtonStyle(primary: true))
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(primary.title) { viewModel.perform(primary.action) }
                    }
                }
            }
            .controlSize(.large)
            .buttonStyle(OnboardingButtonStyle())
        }
    }

    /// Back, then Continue / Skip for now — or, on Ready, its own button.
    private func navigation(_ step: OnboardingStep) -> some View {
        HStack {
            if viewModel.canGoBack {
                Button("Back") { viewModel.back() }
            }
            Spacer()
            if step.id == .model, step.progress == nil, let primary = step.primary {
                if let forward = viewModel.forwardTitle {
                    Button(forward) { viewModel.forward() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.Palette.inkSecondary)
                }
                Button(primary.title) { viewModel.perform(primary.action) }
                    .buttonStyle(OnboardingButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            } else if let forward = viewModel.forwardTitle {
                let stepHasDefault = step.primary != nil && step.state == .todo
                if stepHasDefault {
                    Button(forward) { viewModel.forward() }
                } else {
                    Button(forward) { viewModel.forward() }
                        .keyboardShortcut(.defaultAction)
                }
            } else if let primary = step.primary {
                Button(primary.title) { viewModel.perform(primary.action) }
                    .buttonStyle(OnboardingButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .buttonStyle(OnboardingButtonStyle())
    }

    // MARK: - Model choice

    @ViewBuilder
    private var modelChoice: some View {
        VStack(spacing: 8) {
            if viewModel.showsModelPicker {
                VStack(spacing: 8) {
                    ForEach(viewModel.modelOptions) { option in
                        ModelOptionRow(option: option, isSelected: option.key == viewModel.selectedModel,
                                       isEnabled: viewModel.canChooseModel) {
                            viewModel.perform(.selectModel(option.key))
                        }
                    }
                }
            }
            Button("More Models in Settings…") { viewModel.perform(.readiness(.openSettings(.speechModel))) }
                .buttonStyle(.link)
                .font(Brand.Typography.caption)
                // Green as text: accentText passes AA on the window (BrandTests).
                .tint(Brand.Palette.accentText)
                .foregroundStyle(Brand.Palette.accentText)
        }
    }
}

/// The mockup's compact rectangular controls, keeping native Button keyboard
/// handling and accessibility while making the shape and emphasis explicit.
private struct OnboardingButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? (scheme == .dark ? Brand.Palette.background : Color.white)
                             : Brand.Palette.inkSecondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(primary ? Brand.Palette.accent : Brand.Palette.surface,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(primary ? Brand.Palette.accent : Brand.Palette.outline(contrast))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Step dots

/// Where you are: a slim bar per real step, the current one green.
private struct StepDots: View {
    let steps: [OnboardingStep]
    let current: OnboardingStepID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.id) { step in
                Capsule()
                    .fill(color(step))
                    .frame(width: 22, height: 4)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(steps.count)")
    }

    private func color(_ step: OnboardingStep) -> Color {
        if step.id == current { return Brand.Palette.accent }
        return step.state.isFinished && step.id != .ready
            ? Brand.Palette.accent.opacity(0.45) : Brand.Palette.ink.opacity(0.15)
    }
}

// MARK: - Hero

/// The mascot on Welcome and Ready; elsewhere the step's symbol, with a
/// badge once it's done (or when it can't be).
private struct StepHero: View {
    let step: OnboardingStep
    @Environment(\.colorSchemeContrast) private var contrast

    /// Parsed once: `Brand.Art.mascot` builds a new image from the SVG per call.
    private static let idle = Brand.Art.mascot(.idle)
    private static let done = Brand.Art.mascot(.done)

    var body: some View {
        Group {
            switch step.id {
            case .welcome:
                mascot(Self.idle)
            case .ready:
                mascot(step.state == .done ? Self.done : Self.idle)
            case .model:
                Image(nsImage: Self.idle)
                    .resizable()
                    .frame(width: 72, height: 72)
            case .microphone, .accessibility, .notifications, .calendar:
                symbol
            }
        }
        .accessibilityHidden(true)
    }

    private func mascot(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: 116, height: 116)
    }

    private var symbol: some View {
        let name: String
        switch step.id {
        case .microphone: name = "mic.fill"
        case .accessibility: name = "accessibility"
        case .notifications: name = "bell.fill"
        case .calendar: name = "calendar"
        default: name = "waveform"
        }
        return Image(systemName: name)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(Brand.Palette.accent)
            .frame(width: 64, height: 64)
            .background(Brand.Palette.surfaceSecondary, in: Circle())
            .overlay(Circle().strokeBorder(Brand.Palette.outline(contrast)))
            .overlay(alignment: .bottomTrailing) { badge.offset(x: 4, y: 4) }
    }

    @ViewBuilder
    private var badge: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white, Brand.Palette.accent)
                .background(Circle().fill(Brand.Palette.background).padding(-2))
        case .blocked:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white, Brand.Palette.pulse)
                .background(Circle().fill(Brand.Palette.background).padding(-2))
        case .todo, .waiting, .settling, .declined:
            EmptyView()
        }
    }
}

// MARK: - Model option

/// One model on offer: a radio-style row with its size, the recommended
/// one marked, an installed one said so.
private struct ModelOptionRow: View {
    let option: OnboardingModelOption
    let isSelected: Bool
    let isEnabled: Bool
    let select: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Brand.Palette.accent : Brand.Palette.inkSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .fontWeight(.semibold)
                            .foregroundStyle(Brand.Palette.ink)
                        if option.isRecommended {
                            Text("Recommended")
                                .font(Brand.Typography.font(.caption2, weight: .semibold))
                                .foregroundStyle(Brand.Palette.accentText)   // AA on the tint (BrandTests)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(isSelected ? Brand.Palette.surface
                                            : Brand.Palette.accent.opacity(Brand.Palette.badgeTintOpacity), in: Capsule())
                        }
                    }
                    Text(option.detail)
                        .font(Brand.Typography.caption)
                        .foregroundStyle(Brand.Palette.inkSecondary)
                }
                Spacer(minLength: 8)
                if option.isInstalled {
                    Label("Installed", systemImage: "checkmark")
                        .font(Brand.Typography.caption)
                        .foregroundStyle(Brand.Palette.inkSecondary)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(isSelected ? Brand.Palette.leaf : Brand.Palette.surfaceSecondary,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Brand.Palette.accentText : Brand.Palette.outline(contrast),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled && !isSelected)   // the pick stays legible mid-download
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
