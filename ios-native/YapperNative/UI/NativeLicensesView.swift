import SwiftUI

struct NativeLicensesView: View {
    private let notices: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Die Lizenzhinweise konnten nicht geladen werden."
        }
        return text
    }()

    var body: some View {
        ScrollView {
            Text(notices)
                .font(OriginalYapper.font(13))
                .textSelection(.enabled)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
        }
        .background(YapperPalette.background.ignoresSafeArea())
        .navigationTitle("Open-Source-Lizenzen")
        .navigationBarTitleDisplayMode(.inline)
    }
}
