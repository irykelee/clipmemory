import XCTest
@testable import ClipMemory

/// ID-REVIEW-1028 follow-up（2026-10-25）：把「`UserDefaults` 的读路径是搜索链，
/// 不是字典」这件事**钉成本地可跑的测试**。
///
/// 为什么需要它：v2.9.6 的 CI 全量测试红了 1 个
/// （`IsolationSeamConsolidationTests.testLanguageManagerWritesOnlyIntoTheInjectedSuite`），
/// 根因是那条断言用 `suite.stringArray(forKey:)` 读 `AppleLanguages` ——
/// 而 `xcodebuild -testLanguage zh-Hans` 会把 `AppleLanguages` 放进**argument domain**
/// （搜索链里优先级最高的一层），于是读回 "zh-Hans"，把注入套件里真正的 "ko" 遮蔽了。
/// 写进套件自己域里的值一直是 "ko"（生产代码从头到尾是对的）。
///
/// **为什么这条测试存在**：修好的断言改用 `suite.persistentDomain(forName:)`
/// （域本体读法）—— 但那个读法**只有 CI 的 zh-Hans run 才咬得住**：
/// 本地不带 `-testLanguage` 时，旧的脆弱读法同样是绿的 ⇒ 下一个人完全可能
/// 在不知情的情况下把读法改回去，而且本地怎么跑都发现不了。
///
/// 本文件把那条机制本身钉住：搜索链读法**可能回答不属于这个套件的内容**
/// （用「空套件 + 全局域的 AppleLanguages」在本地就能证明），
/// 而域本体读法**始终报告套件自己持有什么**。
final class UserDefaultsSearchListTests: XCTestCase {

    /// 唯一套件名 + 清理。固定名会让「域本体里有残留」变成跨次运行的假象。
    private func makeFreshSuite() -> (name: String, suite: UserDefaults) {
        let name = "UserDefaultsSearchList-\(UUID().uuidString)"
        let suite = TestSuiteCleanup.makeSuite(named: name)
        // ID-REVIEW-1040 follow-up: this clear was a NO-OP — a suite whose
        // name carries a fresh UUID cannot have a domain yet — and it queued
        // a **pending write** in cfprefsd, which is exactly the mechanism
        // that writes an empty shell back to disk (measured 5/40).
        return (name, suite)
    }

    /// 搜索链读法会回答**不属于这个套件**的内容。
    ///
    /// 证据链（本地可复现，不依赖 CI 的 `-testLanguage`）：
    /// 1. macOS 的全局域里始终有 `AppleLanguages`（系统语言偏好）；
    /// 2. 自定义 suite 的搜索链**包含全局域** ⇒ 一个**空**套件读
    ///    `AppleLanguages` 也会得到全局域的那个值；
    /// 3. 而同一个空套件**自己的域**里根本没有这个 key。
    ///
    /// ⇒ `stringArray(forKey:)` 回答的可能是「外面某个域的值」。
    /// 这就是为什么「写入有没有落进这个套件」不能用它来判断。
    func testSearchListReadCanAnswerWithContentFromOutsideTheSuite() throws {
        let globalLanguages = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
        try XCTSkipIf(globalLanguages?.isEmpty ?? true,
                      "全局域没有 AppleLanguages（非常规环境）——本断言的前提不成立")

        let (name, suite) = makeFreshSuite()

        // 套件自己的域里：什么都没有
        XCTAssertNil(
            suite.persistentDomain(forName: name)?["AppleLanguages"],
            "刚建的套件自己的域里不该有 AppleLanguages"
        )

        // 搜索链读法：却能读到一个值 —— 它来自套件之外（全局域；
        // CI 的 zh-Hans run 下则来自 argument domain）
        let viaSearchList = suite.stringArray(forKey: "AppleLanguages")
        XCTAssertNotNil(
            viaSearchList,
            "搜索链读法会回答套件之外的内容（全局域/argument domain）"
        )
        XCTAssertNotEqual(
            viaSearchList,
            suite.persistentDomain(forName: name)?["AppleLanguages"] as? [String],
            "搜索链读法与域本体读法是**两回事** —— 这正是 ID-REVIEW-1028 的根因"
        )
    }

    /// 域本体读法始终报告套件自己持有什么，**不受任何高优先级域影响**。
    ///
    /// 这条是 `IsolationSeamConsolidationTests` 里那条修好的断言所依赖的性质，
    /// 在本地就能验，不需要 CI 的 `-testLanguage`。
    func testDomainBodyReadAlwaysReportsWhatTheSuiteItselfHolds() throws {
        let (name, suite) = makeFreshSuite()
        let written = ["ko"]

        suite.set(written, forKey: "AppleLanguages")

        let domainBody = suite.persistentDomain(forName: name)?["AppleLanguages"] as? [String]
        XCTAssertEqual(
            domainBody,
            written,
            "域本体读法必须看到套件自己写进去的值（这是判断「写入有没有落进套件」的唯一依据）"
        )
    }

    /// 生产路径复述：服务通过注入的 seam 写入后，域本体读法能看到它。
    ///
    /// 把机制钉在**真实生产代码**上，而不只是一个裸 `UserDefaults` ——
    /// 避免将来有人把「注入的 seam 指向了别的地方」也一起改掉。
    @MainActor
    func testInjectedSeamWriteIsVisibleInTheDomainBodyOfTheInjectedSuite() throws {
        let (name, suite) = makeFreshSuite()
        let saved = TestIsolation.defaults
        defer { TestIsolation.defaults = saved }
        TestIsolation.setDefaults(suite)

        let manager = LanguageManager.shared
        let original = manager.selectedLanguage
        defer { manager.selectedLanguage = original }

        manager.selectedLanguage = "ko"

        let domainBody = suite.persistentDomain(forName: name)?["AppleLanguages"] as? [String]
        XCTAssertEqual(
            domainBody?.first,
            "ko",
            "经注入 seam 写入的 AppleLanguages 必须落在注入套件自己的域里"
        )
    }

    /// 防止有人把 `IsolationSeamConsolidationTests` 里那条断言的读法改回搜索链读法。
    ///
    /// 上面两条测的是**机制**；这条测的是**那处修复本身还在不在**。
    /// 因为修好后的断言（`persistentDomain(forName:)`）**只有 CI 的 zh-Hans run
    /// 才咬得住**（本地不带 `-testLanguage` 时两种读法答案一样），所以需要一条
    /// 本地可跑的源码级守卫把这条规矩钉住。
    ///
    /// 源码级守卫在本仓库有先例（`IsolationSeamConsolidationTests` 自己就断言
    /// `docs/SWIFT6_MIGRATION.md` §8 的 roster 行号仍指向真实声明）。
    func testTheInjectedSuiteAssertionDoesNotFallBackToTheSearchListRead() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClipMemoryTests/
            .appendingPathComponent("IsolationSeamConsolidationTests.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("persistentDomain(forName:"),
            "IsolationSeamConsolidationTests 必须用 persistentDomain(forName:) 读 AppleLanguages"
        )
        XCTAssertFalse(
            source.contains("stringArray(forKey: UserDefaultsKey.appleLanguages"),
            "不得用搜索链读法读 AppleLanguages（argument domain 会遮蔽它 —— ID-REVIEW-1028）"
        )
    }
}
