import SwiftUI

/// The rewrite panel.
///
/// Reads as a live agent working on your text rather than a settings sheet:
/// the source text is a quiet quoted block, the result streams into a card that
/// glows while it's thinking, and the styles are a compact grid you can hit by
/// number. Everything is system-material and accent-tinted so it inherits the
/// user's appearance instead of imposing a look.
struct PolishView: View {
    @ObservedObject var vm: PolishVM
    @ObservedObject var server: ServerManager
    var hotkeyDisplay: String
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)
            source
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(width: 470, height: 450, alignment: .top)
        .background(.ultraThinMaterial)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [Color.brand,
                                                  Color.brand.opacity(0.7)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 22, height: 22)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("Stark").font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(server.status.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        switch server.status {
        case .running: return .green
        case .starting: return .orange
        case .sleeping: return .secondary
        case .stopped, .failed: return .red
        }
    }

    // MARK: source text

    private var source: some View {
        HStack(alignment: .top, spacing: 9) {
            Capsule()
                .fill(Color.brand.opacity(0.45))
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.inPlace ? "Selection" : "Clipboard")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .kerning(0.4)
                Text(vm.input.isEmpty ? "—" : vm.input)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: body

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .empty:
            centred(icon: "text.cursor",
                    title: "Give me something to work with",
                    detail: "Select some text anywhere, then press \(hotkeyDisplay).")

        case .pickPreset:
            VStack(alignment: .leading, spacing: 10) {
                if vm.suggestOrganize {
                    Label("Looks like a list. Press 6 for bullets", systemImage: "list.bullet")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.brand)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                    GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Presets.all, id: \.key) { preset in
                        presetCard(preset)
                    }
                }
            }
            .padding(.horizontal, 16)

        case .generating, .done:
            resultCard

        case .error(let msg):
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(msg).font(.system(size: 12))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("Press \(hotkeyDisplay) to have another go, or pick a different style below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        }
    }

    /// The streamed rewrite. While generating, the border breathes in the accent
    /// colour so the panel reads as actively working rather than frozen.
    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let p = vm.activePreset {
                    Image(systemName: p.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.brand)
                    Text(p.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.brand)
                }
                Spacer()
                if vm.state == .generating {
                    ThinkingDots()
                } else {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
            }
            ScrollView {
                Text(vm.output.isEmpty ? " " : vm.output)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(vm.state == .generating
                        ? Color.brand.opacity(0.55)
                        : Color.secondary.opacity(0.18),
                        lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    private func centred(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }

    private func presetCard(_ preset: Preset) -> some View {
        Button {
            vm.run(preset)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: preset.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.brand)
                    .frame(width: 16)
                Text(preset.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(preset.key)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 15, height: 15)
                    .background(.quaternary.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.28),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 4) {
            switch vm.state {
            case .pickPreset, .empty:
                hint("1–8", "style")
            case .generating:
                Text("All local. All yours.").font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            case .done:
                hint("1–8", "another style")
            case .error:
                hint("1–8", "retry")
            }
            Spacer()
            hint("esc", "close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.18))
        .overlay(Divider(), alignment: .top)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

/// Three dots pulsing in sequence — reads as the model thinking, and costs
/// nothing next to a spinner that implies a determinate wait.
private struct ThinkingDots: View {
    final class Phase: ObservableObject { @Published var on = false }
    @StateObject private var phase = Phase()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.brand)
                    .frame(width: 4, height: 4)
                    .opacity(phase.on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.55).repeatForever()
                        .delay(Double(i) * 0.16), value: phase.on)
            }
        }
        .onAppear { phase.on = true }
    }
}
