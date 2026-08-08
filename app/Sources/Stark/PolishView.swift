import SwiftUI

struct PolishView: View {
    @ObservedObject var vm: PolishVM
    @ObservedObject var server: ServerManager
    var hotkeyDisplay: String
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            clipboardPreview
            Divider()
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 460, height: 440, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.circle.fill").foregroundStyle(.yellow)
            Text("Stark").font(.headline)
            Spacer()
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(server.status.label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .running: return .green
        case .starting: return .orange
        case .stopped, .failed: return .red
        }
    }

    private var clipboardPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(vm.inPlace ? "SELECTION" : "CLIPBOARD").font(.caption2).foregroundStyle(.tertiary)
            Text(vm.input.isEmpty ? "—" : vm.input)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .empty:
            VStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard").font(.title2).foregroundStyle(.tertiary)
                Text("Nothing to rewrite. Select or copy some text, then press \(hotkeyDisplay).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .pickPreset:
            VStack(alignment: .leading, spacing: 2) {
                if vm.suggestOrganize {
                    Label("Looks like a list — press B to organize", systemImage: "list.bullet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.bottom, 4)
                }
                ForEach(Presets.all, id: \.key) { preset in
                    presetRow(preset)
                }
                Text("Press 1–7 or click · Esc to close")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }

        case .generating, .done:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let p = vm.activePreset {
                        Image(systemName: p.icon).font(.caption)
                        Text(p.name).font(.caption.weight(.semibold))
                    }
                    Spacer()
                    if vm.state == .generating {
                        ProgressView().controlSize(.small)
                    }
                }
                ScrollView {
                    Text(vm.output.isEmpty ? " " : vm.output)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
                if vm.state == .done {
                    HStack {
                        Label(vm.inPlace ? "Replacing selection…" : "Copied to clipboard",
                              systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                        Spacer()
                        Text("1–7 to try another style · Esc to close")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                Text("Check that the model server is running (menu bar → Restart Server), then press \(hotkeyDisplay) again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func presetRow(_ preset: Preset) -> some View {
        Button {
            vm.run(preset)
        } label: {
            HStack(spacing: 10) {
                Text(preset.key)
                    .font(.caption.monospaced().weight(.semibold))
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                Image(systemName: preset.icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(preset.name).font(.callout)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}
