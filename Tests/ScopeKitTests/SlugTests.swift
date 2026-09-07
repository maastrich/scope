import Testing
@testable import ScopeCore

@Suite struct SlugTests {
    @Test func punctuationAndCase() {
        #expect(slugify("Auth Refresh (v2)!") == "auth-refresh-v2")
    }

    @Test func diacriticsAreFolded() {
        #expect(slugify("Éléphant à l'école") == "elephant-a-l-ecole")
    }

    @Test func separatorRunsCollapseAndTrim() {
        #expect(slugify("  --Hello__World--  ") == "hello-world")
    }

    @Test func nonLatinScriptsAreTransliterated() {
        #expect(slugify("日本語 テスト") == "ri-ben-yu-tesuto")
        #expect(slugify("Привет мир") == "privet-mir")
    }

    @Test func lettersThatAreNotDiacritics() {
        #expect(slugify("naïve café ÆØÅ ß") == "naive-cafe-aeoa-ss")
    }

    @Test func emptyResultUsesFallback() {
        #expect(slugify("") == "scope")
        #expect(slugify("!!!") == "scope")
        #expect(slugify("!!!", fallback: "task") == "task")
        #expect(slugify("!!!", fallback: "") == "")
    }

    @Test func longNamesAreCutWithoutTrailingDash() {
        let long = Array(repeating: "ab", count: 45).joined(separator: "-")   // 134 chars
        let slug = slugify(long)
        #expect(slug.count == 47)                                             // cut at 48 lands on a dash
        #expect(!slug.hasSuffix("-"))
        #expect(slugify(long, maxLength: 10) == "ab-ab-ab-a")
        #expect(slugify("abc", maxLength: 0) == "scope")
    }

    @Test func digitsAreKept() {
        #expect(slugify("v1.2.3") == "v1-2-3")
    }
}

@Suite struct SlugAllocatorTests {
    @Test func freeBaseIsReturnedAsIs() {
        #expect(SlugAllocator.unique(base: "acme", taken: []) == "acme")
        #expect(SlugAllocator.unique(base: "acme", taken: ["other"]) == "acme")
    }

    @Test func suffixesStartAtTwo() {
        #expect(SlugAllocator.unique(base: "acme", taken: ["acme"]) == "acme-2")
        #expect(SlugAllocator.unique(base: "acme", taken: ["acme", "acme-2"]) == "acme-3")
    }

    @Test func skipsTakenSuffixes() {
        #expect(SlugAllocator.unique(base: "acme", taken: ["acme", "acme-2", "acme-3", "acme-5"]) == "acme-4")
    }

    @Test func emptyBaseBecomesScope() {
        #expect(SlugAllocator.unique(base: "", taken: []) == "scope")
        #expect(SlugAllocator.unique(base: "", taken: ["scope"]) == "scope-2")
    }
}
