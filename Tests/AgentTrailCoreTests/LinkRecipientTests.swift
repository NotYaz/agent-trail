import XCTest
@testable import AgentTrailCore

final class LinkRecipientTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_500_000)

    private func instance(_ pid: Int32, after seconds: TimeInterval?) -> LinkRecipient.Instance {
        LinkRecipient.Instance(pid: pid, launchDate: seconds.map { start.addingTimeInterval($0) })
    }

    /// The real layout on 2026-11-05: Second (4120) started six seconds before Main
    /// (4269), and every link went to Second, even with Main in front.
    func testInstanceLaunchedFirstReceivesLinks() {
        XCTAssertEqual(LinkRecipient.pid(among: [instance(4120, after: 0), instance(4269, after: 6)]), 4120)
        XCTAssertEqual(LinkRecipient.pid(among: [instance(4269, after: 6), instance(4120, after: 0)]), 4120)
    }

    /// Launch order decides, not pid order.
    func testLaunchOrderWinsOverPidOrder() {
        XCTAssertEqual(LinkRecipient.pid(among: [instance(900, after: 30), instance(70_000, after: 1), instance(500, after: 12)]),
                       70_000)
    }

    func testSoleInstanceReceivesLinks() {
        XCTAssertEqual(LinkRecipient.pid(among: [instance(4269, after: 6)]), 4269)
    }

    func testUnknownOrderNamesNoInstance() {
        XCTAssertNil(LinkRecipient.pid(among: []))
        XCTAssertNil(LinkRecipient.pid(among: [instance(4120, after: 0), instance(4269, after: nil)]))
        XCTAssertNil(LinkRecipient.pid(among: [instance(4269, after: nil)]))
        XCTAssertNil(LinkRecipient.pid(among: [instance(4120, after: 3), instance(4269, after: 3)]))
    }

    /// A tie for a later place does not hide the instance launched first.
    func testLaterTieStillNamesEarliest() {
        XCTAssertEqual(LinkRecipient.pid(among: [instance(10, after: 5), instance(11, after: 5), instance(12, after: 1)]), 12)
        XCTAssertEqual(LinkRecipient.pid(among: [instance(12, after: 1), instance(10, after: 5), instance(11, after: 5)]), 12)
    }
}
