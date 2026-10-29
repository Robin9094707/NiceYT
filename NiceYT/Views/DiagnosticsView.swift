import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var player: PlayerModel
    @State private var lines: [String] = DebugLog.shared.entries
    @State private var exported = ""
    @State private var testing = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if lines.isEmpty {
                        Text("Noch keine Einträge. Spiele ein Video ab oder tippe auf „Wiedergabe testen“.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 30)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .padding(12)
            }
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        testing = true
                        Task {
                            DebugLog.log("— Wiedergabe-Test —")
                            _ = await StreamResolver.firstPlayable("jGztGfRujSE") { _ in true }
                            testing = false
                        }
                    } label: {
                        Label(testing ? "Teste…" : "Wiedergabe testen", systemImage: "stethoscope")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(testing)
                    ShareLink(item: exported.isEmpty ? DebugLog.shared.export() : exported) {
                        Label("Senden", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.bottom, 8)
        }
        .navigationTitle("Diagnose")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Kopieren", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = DebugLog.shared.export()
                    player.showToast("Diagnose kopiert")
                }
                Button("Leeren", systemImage: "trash") { DebugLog.shared.clear() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugLogChanged).receive(on: RunLoop.main)) { _ in
            lines = DebugLog.shared.entries
            exported = DebugLog.shared.export()
        }
        .onAppear { exported = DebugLog.shared.export() }
    }

    private func color(for line: String) -> Color {
        if line.contains("✖︎") || line.contains("Fehler") || line.contains("HTTP 4") || line.contains("HTTP 5") { return .red }
        if line.contains("✔︎") { return .green }
        if line.contains("▶︎") || line.contains("—") { return .accentColor }
        return .primary
    }
}
