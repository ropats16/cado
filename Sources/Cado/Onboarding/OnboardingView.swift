import SwiftUI
import AppKit

/// The onboarding window (#22): one step at a time — where you are, what
/// it's for, the step's own buttons — with Back and Continue below. Every
/// word and button comes from `OnboardingViewModel` (`OnboardingContent`);
/// this only lays them out, in Settings' cards and system colours.
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    static let size = CGSize(width: 520, height: 560)

    var body: some View {
        let step = viewModel.step
        VStack(spacing: 0) {
            StepDots(steps: viewModel.content.steps, current: viewModel.current)
                .padding(.top, 18)

            // Centred; scrolls only if it can't fit (large text sizes).
            ViewThatFits(in: .vertical) {
                page(step)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView { page(step) }
            }

            Divider()
            navigation(step)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .font(Brand.Typography.body)
        .tint(Brand.Palette.accent)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Brand.Palette.background)
    }

    // MARK: - Parts

    private func page(_ step: OnboardingStep) -> some View {
        VStack(spacing: 12) {
            StepHero(step: step)
            Text(step.title)
                .font(Brand.Typography.font(.title, weight: .bold))
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
            if step.id != .ready, step.progress == nil { stepButtons(step) }
        }
        .padding(.horizontal, 40)
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
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(primary.title) { viewModel.perform(primary.action) }
                    }
                }
            }
            .controlSize(.large)
        }
    }

    /// Back, then Continue / Skip for now — or, on Ready, its own button.
    private func navigation(_ step: OnboardingStep) -> some View {
        HStack {
            if viewModel.canGoBack {
                Button("Back") { viewModel.back() }
            }
            Spacer()
            if let forward = viewModel.forwardTitle {
                let stepHasDefault = step.primary != nil && step.state == .todo
                if stepHasDefault {
                    Button(forward) { viewModel.forward() }
                } else {
                    Button(forward) { viewModel.forward() }
                        .keyboardShortcut(.defaultAction)
                }
            } else if let primary = step.primary {
                Button(primary.title) { viewModel.perform(primary.action) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    // MARK: - Model choice

    @ViewBuilder
    private var modelChoice: some View {
        VStack(spacing: 6) {
            if viewModel.showsModelPicker {
                SettingsCard {
                    ForEach(Array(viewModel.modelOptions.enumerated()), id: \.element.id) { index, option in
                        if index > 0 { CardDivider() }
                        ModelOptionRow(option: option, isSelected: option.key == viewModel.selectedModel,
                                       isEnabled: viewModel.canChooseModel) {
                            viewModel.perform(.selectModel(option.key))
                        }
                    }
                }
            }
            Button("More Models in Settings…") { viewModel.perform(.readiness(.openSettings)) }
                .buttonStyle(.link)
                .font(Brand.Typography.caption)
                // Green as text: accentText passes AA on the window (BrandTests).
                .tint(Brand.Palette.accentText)
                .foregroundStyle(Brand.Palette.accentText)
        }
    }
}

// MARK: - Step dots

/// Where you are: a dot per step, the current one long, finished ones filled.
private struct StepDots: View {
    let steps: [OnboardingStep]
    let current: OnboardingStepID

    var body: some View {
        HStack(spacing: 8) {
            ForEach(steps, id: \.id) { step in
                Capsule()
                    .fill(color(step))
                    .frame(width: step.id == current ? 22 : 8, height: 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
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
            case .microphone, .accessibility, .model, .notifications:
                symbol
            }
        }
        .accessibilityHidden(true)
    }

    private func mascot(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .frame(width: 104, height: 104)
    }

    private var symbol: some View {
        let name: String
        switch step.id {
        case .microphone: name = "mic.fill"
        case .accessibility: name = "accessibility"
        case .notifications: name = "bell.fill"
        default: name = "waveform"
        }
        return Image(systemName: name)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(Brand.Palette.accent)
            .frame(width: 64, height: 64)
            .background(Brand.Palette.surface, in: Circle())
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

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Brand.Palette.accent : Brand.Palette.inkSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(option.title).foregroundStyle(Brand.Palette.ink)
                        if option.isRecommended {
                            Text("Recommended")
                                .font(Brand.Typography.font(.caption2, weight: .semibold))
                                .foregroundStyle(Brand.Palette.accentText)   // AA on the tint (BrandTests)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Brand.Palette.accent.opacity(Brand.Palette.badgeTintOpacity), in: Capsule())
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
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled && !isSelected)   // the pick stays legible mid-download
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
