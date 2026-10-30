import SwiftUI

/// shown in place of the web view before a tab's first navigation
struct StartPage: View {
    /// the card's ink, not the system's — see ErrorPage
    @Environment(\.chromeInk) private var ink
    @AppStorage(AppIconChoice.storageKey) private var iconRaw = AppIconChoice.bundled.rawValue

    var body: some View {
        VStack(spacing: 12) {
            if let icon = (AppIconChoice(rawValue: iconRaw) ?? .bundled).image(dark: AppIconChoice.iconsAreDark) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
            }

            Text("Artemis")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(ink)

            Text("Search or enter a URL — ⌘T for a new tab")
                .font(.callout)
                .foregroundStyle(ink.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
