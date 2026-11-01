import SwiftUI

/// Shipped colorRole/nameStyle: highest ranked colored role, with optional second-color gradient.
struct NativeServerRoleName: View {
    let name: String
    var role: NativeServerRole?
    var bannerURL: URL? = nil

    var body: some View {
        Group {
            if let first = Color.originalProfileHex(role?.color), let second = Color.originalProfileHex(role?.color2) {
                Text(name).foregroundStyle(LinearGradient(colors: [first, second], startPoint: .leading, endPoint: .trailing))
            } else {
                Text(name).foregroundStyle(Color.originalProfileHex(role?.color) ?? YapperPalette.text)
            }
        }
        .background {
            if let bannerURL { NativeRemoteImage(url: bannerURL, maximumPixelSize: 600, mode: .fill).clipped().allowsHitTesting(false) }
        }
    }
}
