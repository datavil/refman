import AppKit
import SwiftUI

struct BrowserPairingView: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var copied = false
    @State private var copyFeedbackTask: Task<Void, Never>?

    var body: some View {
        VStack {
            HStack {
                Image(nsImage: AppIcon.mark)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .padding(6)
                    .background(
                        .background,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.primary.opacity(0.12))
                    }
                VStack(alignment: .leading) {
                    Text("Pair Chrome Extension")
                        .font(.title2)
                        .bold()
                    Text("Connect the extension directly to this Mac.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let code = model.browserBridge.pairingCode {
                VStack {
                    Text("Enter this code in the extension")
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(.largeTitle.monospacedDigit())
                        .bold()
                        .textSelection(.enabled)
                        .accessibilityLabel("Pairing code \(code)")
                    Text("The code works once and expires in five minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("New Code", systemImage: "arrow.clockwise") {
                        model.browserBridge.createPairingCode()
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            } else {
                ContentUnavailableView {
                    Label("Extension Paired", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } description: {
                    Text("You can close this window and start saving articles.")
                }
            }

            HStack {
                if let code = model.browserBridge.pairingCode {
                    Button(
                        copied ? "Copied" : "Copy Code",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    ) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        copied = true
                        copyFeedbackTask?.cancel()
                        copyFeedbackTask = Task {
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            copied = false
                        }
                    }
                }
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 420)
        .onDisappear { copyFeedbackTask?.cancel() }
    }
}
