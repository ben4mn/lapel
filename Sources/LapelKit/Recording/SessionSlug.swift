import Foundation

/// Turns a human title into a safe single path component.
///
/// Session directories are named after what the user typed, which means arbitrary
/// text reaches the filesystem. Everything outside `a-z0-9` becomes a hyphen, so a
/// title can never introduce a path separator, a hidden dotfile, or a name the
/// filesystem will reject.
public enum SessionSlug {
    public static let defaultFallback = "untitled"
    /// Well inside the 255-byte filename limit, leaving room for a timestamp prefix,
    /// a collision suffix and an extension.
    public static let maxLength = 80

    public static func make(from title: String, fallback: String = defaultFallback) -> String {
        let folded = title
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        var slug = ""
        var pendingSeparator = false   // starts true-ish: a leading separator is simply dropped
        for scalar in folded.unicodeScalars {
            if isSlugSafe(scalar) {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
        }

        if slug.utf8.count > maxLength {
            slug = String(slug.prefix(maxLength))
        }
        while slug.hasSuffix("-") { slug.removeLast() }

        return slug.isEmpty ? fallback : slug
    }

    private static func isSlugSafe(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
    }
}
