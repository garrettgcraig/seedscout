import SwiftUI
import UIKit

/// Shared type scale, so the two surfaces look like one product.
///
/// Fraunces for the wordmark, section headings and species names; Inter for
/// everything dense. Both are the same variable fonts the web client
/// self-hosts. Registered from the bundle at launch rather than declared in
/// Info.plist under UIAppFonts, because a variable TTF exposes one family name
/// and the weight is selected at use, which the plist route handles poorly.
enum Typography {
    static let serif = "Fraunces"
    static let sans = "Inter"

    /// Call once at launch. CoreText registration is idempotent per process, and
    /// failures are non-fatal - the app falls back to the system face.
    static func register() {
        for name in [serif, sans] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf",
                                            subdirectory: "Fonts")
                    ?? Bundle.main.url(forResource: name, withExtension: "ttf") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        applyNavigationAppearance()
    }

    /// SwiftUI's navigationTitle draws with the system face regardless of any
    /// .font() applied to the view, so the bar has to be styled through UIKit.
    /// Registering the font is not enough on its own - that only makes the
    /// family available to .custom().
    private static func applyNavigationAppearance() {
        guard let large = UIFont(name: serif, size: 34),
              let inline = UIFont(name: serif, size: 17) else { return }
        // Variable fonts default to Regular; ask for the weight explicitly.
        let largeBold = UIFontDescriptor(fontAttributes: [
            .family: serif,
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold],
        ])
        let inlineSemi = UIFontDescriptor(fontAttributes: [
            .family: serif,
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold],
        ])

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.largeTitleTextAttributes = [
            .font: UIFont(descriptor: largeBold, size: 34) ?? large
        ]
        appearance.titleTextAttributes = [
            .font: UIFont(descriptor: inlineSemi, size: 17) ?? inline
        ]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    static func display(_ size: CGFloat) -> Font { .custom(serif, size: size).weight(.bold) }
    static func heading(_ size: CGFloat) -> Font { .custom(serif, size: size).weight(.semibold) }
    static func body(_ size: CGFloat) -> Font { .custom(sans, size: size) }
}

extension View {
    /// Inter as the default face for a subtree, leaving Fraunces to be applied
    /// explicitly where it belongs.
    func seedFinderTypography() -> some View {
        self.font(.custom(Typography.sans, size: 17))
    }
}
