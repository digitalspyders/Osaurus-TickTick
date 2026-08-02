//
//  PluginConformanceTests.swift
//  OsaurusTickTickTests
//
//  Verifies the plugin's manifest is well-formed and its ABI entry point
//  returns a valid API table. Uses the shared conformance helpers from
//  OsaurusPluginTestSupport.
//

import XCTest
import OsaurusPluginABI
import OsaurusPluginTestSupport
@testable import OsaurusTickTick

final class PluginConformanceTests: XCTestCase {

    func testManifestIsConformant() throws {
        try ManifestConformance.assertConformant(ticktickManifestJSON)
    }

    func testManifestIsValidJSON() throws {
        let data = try XCTUnwrap(ticktickManifestJSON.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let dict = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(dict["plugin_id"] as? String, "osaurus.ticktick")
        XCTAssertEqual(dict["name"] as? String, "TickTick")
        XCTAssertEqual(dict["version"] as? String, "0.1.0")

        let caps = try XCTUnwrap(dict["capabilities"] as? [String: Any])
        let tools = try XCTUnwrap(caps["tools"] as? [[String: Any]])
        // 18 tools
        XCTAssertEqual(tools.count, 18)

        let ids = tools.compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(ids).count, ids.count, "tool ids must be unique")
        XCTAssertTrue(ids.contains("connect_account"))
        XCTAssertTrue(ids.contains("list_projects"))
        XCTAssertTrue(ids.contains("create_task"))
        XCTAssertTrue(ids.contains("get_overdue_tasks"))
    }

    func testSecretsDeclareOAuthCredentials() throws {
        let data = try XCTUnwrap(ticktickManifestJSON.data(using: .utf8))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let secrets = try XCTUnwrap(dict["secrets"] as? [[String: Any]])
        // 2 secrets: client_id and client_secret (redirect_uri is hardcoded)
        XCTAssertEqual(secrets.count, 2)
        let ids = Set(secrets.compactMap { $0["id"] as? String })
        XCTAssertTrue(ids.contains("client_id"))
        XCTAssertTrue(ids.contains("client_secret"))
        for s in secrets {
            XCTAssertEqual(s["required"] as? Bool, true)
        }
    }

    func testPriorityMappingRoundTrip() {
        // friendly → API → friendly
        XCTAssertEqual(mapPriorityToAPI(0), 0)
        XCTAssertEqual(mapPriorityToAPI(1), 1)
        XCTAssertEqual(mapPriorityToAPI(2), 3)
        XCTAssertEqual(mapPriorityToAPI(3), 5)
        XCTAssertEqual(mapPriorityToAPI(4), 5)

        XCTAssertEqual(mapPriorityToFriendly(0), 0)
        XCTAssertEqual(mapPriorityToFriendly(1), 1)
        XCTAssertEqual(mapPriorityToFriendly(3), 2)
        XCTAssertEqual(mapPriorityToFriendly(5), 3)
    }

    func testFlexibleDateParsingISO() throws {
        let s = try parseFlexibleDate("2026-08-01T08:00:00+00:00")
        XCTAssertNotNil(s)
        XCTAssertTrue(s?.contains("2026-08-01") == true)
    }

    func testFlexibleDateParsingDayOnly() throws {
        let s = try parseFlexibleDate("2026-08-01")
        XCTAssertNotNil(s)
        XCTAssertTrue(s?.hasPrefix("2026-08-01") == true)
    }

    func testFlexibleDateParsingNil() throws {
        XCTAssertNil(try parseFlexibleDate(nil))
        XCTAssertNil(try parseFlexibleDate(""))
        XCTAssertNil(try parseFlexibleDate("   "))
    }

    func testFlexibleDateParsingRelative() throws {
        let today = try parseFlexibleDate("today")
        XCTAssertNotNil(today)
        let tomorrow = try parseFlexibleDate("tomorrow at 8 AM")
        XCTAssertNotNil(tomorrow)
    }

    func testEntryV2ReturnsAPIPointer() {
        let ptr = osaurus_plugin_entry_v2(nil)
        XCTAssertNotNil(ptr)
    }

    func testEntryV1ReturnsAPIPointer() {
        let ptr = osaurus_plugin_entry()
        XCTAssertNotNil(ptr)
    }
}
