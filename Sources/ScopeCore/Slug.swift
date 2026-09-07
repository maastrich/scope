import Foundation

/// Turns a display name into a short, file- and branch-safe slug.
///
/// `"Auth Refresh (v2)!"` → `"auth-refresh-v2"`, `"Éléphant à l'école"` → `"elephant-a-l-ecole"`,
/// `"日本語"` → `"ri-ben-yu"`, `"naïve café ÆØÅ ß"` → `"naive-cafe-aeoa-ss"`. Empty results fall back to `fallback`.
///
/// The ICU compound transform `Any-Latin; Latin-ASCII` is required: `.toLatin` + `.stripDiacritics`
/// alone leave `Æ Ø ß` untouched because they are letters, not diacritics.
public func slugify(_ name: String, maxLength: Int = 48, fallback: String = "scope") -> String {
    let ascii = name.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false)
        ?? name.applyingTransform(.stripDiacritics, reverse: false)
        ?? name

    // Lowercase, map every non-alphanumeric run to a single "-", trim leading dashes.
    var slug = ""
    var previousWasDash = true
    for scalar in ascii.lowercased().unicodeScalars {
        let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
        let isLower = scalar.value >= 0x61 && scalar.value <= 0x7A
        if isDigit || isLower {
            slug.unicodeScalars.append(scalar)
            previousWasDash = false
        } else if !previousWasDash {
            slug.append("-")
            previousWasDash = true
        }
    }

    // Cut, then trim trailing dashes (a cut can leave one).
    if slug.count > maxLength {
        slug = String(slug.prefix(max(0, maxLength)))
    }
    while slug.hasSuffix("-") {
        slug.removeLast()
    }
    return slug.isEmpty ? fallback : slug
}

/// Allocates slugs that are unique within a set (scope slugs in `config.json`, task slugs in a scope).
public enum SlugAllocator {
    /// `"acme"` → `"acme"` when free, otherwise `"acme-2"`, `"acme-3"`, … (the first suffix not in `taken`).
    /// An empty `base` is treated as `"scope"`.
    public static func unique(base: String, taken: Set<String>) -> String {
        let root = base.isEmpty ? "scope" : base
        guard taken.contains(root) else { return root }
        var counter = 2
        while taken.contains("\(root)-\(counter)") {
            counter += 1
        }
        return "\(root)-\(counter)"
    }
}
