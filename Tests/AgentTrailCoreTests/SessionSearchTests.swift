import XCTest
@testable import AgentTrailCore

final class SessionSearchTests: XCTestCase {
    private let fields = ["agent-trail", "Landing copy pass", "Claude · Main", "hotkeys"]

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(SessionSearch.matches("", fields: fields))
        XCTAssertTrue(SessionSearch.matches("   ", fields: []))
    }

    func testEveryWordMustMatchSomeField() {
        XCTAssertTrue(SessionSearch.matches("trail main", fields: fields))
        XCTAssertTrue(SessionSearch.matches("COPY  hot", fields: fields))
        XCTAssertFalse(SessionSearch.matches("trail second", fields: fields))
    }

    func testIgnoresCaseAccentsAndWidth() {
        XCTAssertTrue(SessionSearch.matches("cafe", fields: ["Café rewrite"]))
        XCTAssertTrue(SessionSearch.matches("ＴＲＡＩＬ", fields: fields))
        XCTAssertTrue(SessionSearch.matches("ёлка", fields: ["Ёлка"]))
    }
}
