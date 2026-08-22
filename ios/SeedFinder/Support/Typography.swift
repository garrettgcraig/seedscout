import SwiftUI
import UIKit

/// Shared type scale, so the two surfaces look like one product.
///
/// Fraunces for the wordmark, section headings and species names; Inter for
/// everything dense. Both are the same variable fonts the web client
/// self-hosts, bundled here so the app does not depend on a network.
enum Typography {
    static let serif = "Fraunces"
    static let sans = "Inter"

    /// Call once at launch. Registration is idempotent per process, and failure
    /// is non-fatal - the app falls back to the system face.
    ///
    /// Note that registering is only half the job. A UINavigationBarAppearance
    /// was tried for the title and had no effect on SwiftUI's navigation stack
    /// even with the font registered and UIFont(name:) resolving correctly, so
    /// the wordmark is a toolbar item that SwiftUI renders directly instead.
    static func register() {
        for name in [serif, sans] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf",
                                            subdirectory: "Fonts")
                    ?? Bundle.main.url(forResource: name, withExtension: "ttf") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func display(_ size: CGFloat) -> Font { .custom(serif, size: size).weight(.bold) }
    static func heading(_ size: CGFloat) -> Font { .custom(serif, size: size).weight(.semibold) }
    static func body(_ size: CGFloat) -> Font { .custom(sans, size: size) }
}
