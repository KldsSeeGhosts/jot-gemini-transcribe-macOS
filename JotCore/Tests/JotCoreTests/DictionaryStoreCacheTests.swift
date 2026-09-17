// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import XCTest
@testable import JotCore

final class DictionaryStoreCacheTests: XCTestCase {
    private let store = DictionaryStore()

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "dictionaryEntries")
        super.tearDown()
    }

    func testVocabularyAndReplacementRulesCacheAndReflectAdd() {
        // Initial empty state
        XCTAssertTrue(store.vocabulary().isEmpty)
        XCTAssertTrue(store.sanitizedVocabulary().isEmpty)
        XCTAssertTrue(store.replacementRules().isEmpty)

        // Multiple calls return identical values from cache
        XCTAssertEqual(store.vocabulary(), store.vocabulary())
        XCTAssertEqual(store.sanitizedVocabulary(), store.sanitizedVocabulary())
        XCTAssertEqual(store.replacementRules(), store.replacementRules())

        // Add new entry
        let added = store.add(term: "GraphQL", misspelling: "graph ql")
        XCTAssertTrue(added)

        // Immediately reflected in cached accessors
        XCTAssertTrue(store.vocabulary().contains("GraphQL"))
        XCTAssertTrue(store.sanitizedVocabulary().contains("GraphQL"))
        let rules = store.replacementRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.wrong, "graph ql")
        XCTAssertEqual(rules.first?.right, "GraphQL")

        // Independent DictionaryStore instance sees the same cached values
        let secondStore = DictionaryStore()
        XCTAssertEqual(secondStore.vocabulary(), ["GraphQL"])
        XCTAssertEqual(secondStore.replacementRules(), rules)

        // Add second entry and verify ordering and rules update
        let addedSecond = store.add(term: "Kubernetes", misspelling: "cooper netties")
        XCTAssertTrue(addedSecond)
        XCTAssertEqual(store.replacementRules().count, 2)
        XCTAssertTrue(store.sanitizedVocabulary().contains("Kubernetes"))
    }

    func testCacheInvalidatesOnExternalUserDefaultsWrite() throws {
        _ = store.add(term: "InitialTerm", misspelling: "initial")
        XCTAssertTrue(store.vocabulary().contains("InitialTerm"))

        // Externally simulate another process or direct defaults update
        let externalEntry = DictionaryEntry(term: "ExternalTerm", misspelling: "external")
        let data = try JSONEncoder().encode([externalEntry])
        UserDefaults.standard.set(data, forKey: "dictionaryEntries")

        // Next read detects data byte change and re-decodes
        XCTAssertEqual(store.vocabulary(), ["ExternalTerm"])
        XCTAssertEqual(store.replacementRules().first?.right, "ExternalTerm")
    }
}
