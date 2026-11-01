import SwiftUI

struct NativePluginsView: View {
    @AppStorage(NativePluginPreferences.characterCounter) private var characterCounter = true
    @AppStorage(NativePluginPreferences.imageZoom) private var imageZoom = true
    @AppStorage(NativePluginPreferences.pictureInPicture) private var pictureInPicture = true
    @AppStorage(NativePluginPreferences.clearURLs) private var clearURLs = false
    @AppStorage(NativePluginPreferences.textReplace) private var textReplace = false
    @State private var rules = NativePluginPreferences.rules()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Yapinplugger").font(OriginalYapper.font(20, weight: .bold))
                OriginalSettingsSection("Nachrichten") {
                    pluginToggle("Zeichenzähler", value: $characterCounter)
                    pluginToggle("Tracking-Parameter aus Links entfernen", value: $clearURLs)
                    pluginToggle("Textersetzung", value: $textReplace)
                }
                OriginalSettingsSection("Medien") {
                    pluginToggle("Bild-Zoom", value: $imageZoom)
                    pluginToggle("Bild-in-Bild für Videos", value: $pictureInPicture)
                }
                OriginalSettingsSection("Textersetzungen") {
                    ForEach($rules) { $rule in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Regel").font(OriginalYapper.font(12, weight: .bold)).foregroundStyle(YapperPalette.secondary)
                                Spacer()
                                Button { rules.removeAll { $0.id == rule.id } } label: { OriginalYapperIcon("close", size: 16).frame(width: 36, height: 36) }.accessibilityLabel("Regel entfernen").buttonStyle(.plain)
                            }
                            OriginalSettingsField("Ersetzen") { TextField("Ersetzen", text: $rule.from).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(OriginalYapperTextFieldStyle()) }
                            OriginalSettingsField("Durch") { TextField("Durch", text: $rule.to, axis: .vertical).lineLimit(1...4).textFieldStyle(OriginalYapperTextFieldStyle()) }
                        }.padding(14).background(YapperPalette.sidebar, in: .rect(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(YapperPalette.border, lineWidth: 1))
                    }
                    if rules.count < 30 {
                        Button { rules.append(NativeTextRule(from: "", to: "")) } label: { HStack(spacing: 8) { OriginalYapperIcon("plus", size: 16); Text("Regel hinzufügen") } }.buttonStyle(OriginalYapperButtonStyle())
                    }
                    Text("Längere Treffer haben Vorrang. Ersetzungen werden einmal ausgeführt, bevor du die Nachricht sendest.").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                }
            }.padding(16).padding(.bottom, 28)
        }
        .font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.text)
        .background(YapperPalette.background.ignoresSafeArea())
        .navigationTitle("Yapinplugger")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: rules) { _, values in
            let safe = Array(values.prefix(30)).map { NativeTextRule(id: $0.id, from: String($0.from.prefix(100)), to: String($0.to.prefix(1000))) }
            if let data = try? JSONEncoder().encode(safe) { UserDefaults.standard.set(data, forKey: NativePluginPreferences.rulesKey) }
        }
    }
    private func pluginToggle(_ title: String, value: Binding<Bool>) -> some View {
        Toggle(title, isOn: value).toggleStyle(OriginalYapperToggleStyle()).padding(.vertical, 4)
    }
}
