import SwiftUI

nonisolated enum NativeEmbedURLs {
    static func link(_ value: NativeJSON) -> URL? {
        guard let raw = value.string, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func image(_ value: NativeJSON) -> URL? {
        let raw = value.string ?? value["url"].string
        guard let raw, raw.utf8.count <= 2048, let url = URL(string: raw), url.scheme == "https", url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        let allowed: Set<String> = ["files.yapper.website", "pub-f2aa8df0443d41d3882353e43988c5bb.r2.dev", NativeConfiguration.apiHost, "yapin.gg", "www.yapin.gg", "i.imgur.com", "media.tenor.com", "media.giphy.com", "i.giphy.com", "upload.wikimedia.org", "raw.githubusercontent.com", "avatars.githubusercontent.com", "user-images.githubusercontent.com", "i.ytimg.com", "cdn.discordapp.com", "media.discordapp.net", "pbs.twimg.com", "i.redd.it", "static-cdn.jtvnw.net", "i.scdn.co", "s4.anilist.co", "cdn.myanimelist.net", "nekos.best", "cdn.weeb.sh"]
        guard allowed.contains(host) || host == "klipy.com" || host.hasSuffix(".klipy.com") || host == "rbxcdn.com" || host.hasSuffix(".rbxcdn.com") else { return nil }
        return url
    }
}

struct NativeMessageEmbed: View {
    let embed: NativeJSON
    @AppStorage("native.showImages") private var showImages = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let author = embed["author"]["name"].string {
                HStack(spacing: 8) {
                    if showImages, let icon = NativeEmbedURLs.image(embed["author"]["icon_url"]) {
                        NativeRemoteImage(url: icon, maximumPixelSize: 66, mode: .fill)
                            .frame(width: 22, height: 22).clipShape(.circle)
                    }
                    Text(author).font(OriginalYapper.font(12, weight: .semibold))
                }
            }
            if let title = embed["title"].string {
                if let url = NativeEmbedURLs.link(embed["url"]) { Link(title, destination: url).font(OriginalYapper.font(14, weight: .semibold)) }
                else { Text(title).font(OriginalYapper.font(14, weight: .semibold)) }
            }
            if let description = embed["description"].string {
                Text(.init(description)).font(OriginalYapper.font(14)).textSelection(.enabled)
            }
            ForEach(Array(embed["fields"].array.prefix(25).enumerated()), id: \.offset) { _, field in
                VStack(alignment: .leading, spacing: 4) {
                    if let name = field["name"].string { Text(name).font(OriginalYapper.font(14, weight: .semibold)) }
                    if let value = field["value"].string { Text(.init(value)).font(OriginalYapper.font(14)).textSelection(.enabled) }
                }
            }
            if showImages, let image = NativeEmbedURLs.image(embed["image"]) ?? NativeEmbedURLs.image(embed["thumbnail"]) {
                NativeRemoteImage(url: image, maximumPixelSize: 1080)
                    .frame(maxWidth: 360, maxHeight: 300).clipShape(.rect(cornerRadius: 8))
            }
            if let footer = embed["footer"]["text"].string { Text(footer).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
            if let timestamp = embed["timestamp"].string, let date = try? NativeDate.parse(timestamp) { Text(date.formatted(date: .abbreviated, time: .shortened)).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(12)
        .background(YapperPalette.input, in: .rect(cornerRadius: 10))
        .environment(\.openURL, OpenURLAction { url in NativeEmbedURLs.link(.string(url.absoluteString)) == nil ? .discarded : .systemAction })
    }
}
