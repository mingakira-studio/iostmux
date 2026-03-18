import SwiftUI

struct KeySetupView: View {
    @State private var keyText = ""
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Paste SSH Private Key") {
                    TextEditor(text: $keyText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                }
                Section {
                    Button("Paste from Clipboard") {
                        keyText = UIPasteboard.general.string ?? ""
                    }
                }
                Section {
                    Button("Save Key") {
                        guard let data = keyText.data(using: .utf8) else { return }
                        try? KeychainHelper.save(privateKey: data)
                        onSave()
                    }
                    .disabled(keyText.isEmpty)
                }
                Section {
                    Text("After saving, add the corresponding public key to Mac Studio's ~/.ssh/authorized_keys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SSH Key Setup")
        }
    }
}
