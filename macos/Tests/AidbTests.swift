import XCTest
// 被测源文件（SqlSafety/CSV/GridValue 等）由 project.yml 直接编入本 target，无需 import

/// 核心纯逻辑单测（移植 Tauri 版 driver::tests + CSV 状态机用例）
final class AidbTests: XCTestCase {

    // MARK: SqlSafety

    func testSplitSimple() {
        XCTAssertEqual(SqlSafety.splitStatements("SELECT 1; SELECT 2;"), ["SELECT 1", "SELECT 2"])
    }

    func testSplitQuoted() {
        let v = SqlSafety.splitStatements("INSERT INTO t VALUES ('a;b''c'); SELECT 2")
        XCTAssertEqual(v.count, 2)
        XCTAssertEqual(v[0], "INSERT INTO t VALUES ('a;b''c')")
    }

    func testSplitComment() {
        let v = SqlSafety.splitStatements("-- drop; table\nSELECT 1; /* block; */ SELECT 2")
        XCTAssertEqual(v[0], "-- drop; table\nSELECT 1")
        XCTAssertEqual(v[1], "/* block; */ SELECT 2")
    }

    func testQuoteIdent() {
        XCTAssertEqual(SqlSafety.quoteIdent(kind: .sqlite, "a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(SqlSafety.quoteIdent(kind: .mysql, "a`b"), "`a``b`")
    }

    func testReadonly() {
        XCTAssertTrue(SqlSafety.isReadonlyStmt("  select 1"))
        XCTAssertTrue(SqlSafety.isReadonlyStmt("WITH a AS (SELECT 1) SELECT * FROM a"))
        XCTAssertFalse(SqlSafety.isReadonlyStmt("UPDATE t SET a=1"))
    }

    // MARK: CSV

    func testCSVParseQuotesAndNewline() {
        let text = "a,b\n\"x,1\",\"line\nbreak\"\n\"he said \"\"hi\"\"\",3"
        let rows = CSV.parse(text)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], ["x,1", "line\nbreak"])
        XCTAssertEqual(rows[2], ["he said \"hi\"", "3"])
    }

    func testCSVRoundTrip() {
        let header = ["名称,1", "b"]
        let rows = [["x\r\ny", ""], ["普通", "123"]]
        let text = CSV.serialize(header: header, rows: rows)
        let back = CSV.parse(text)
        XCTAssertEqual(back[0], header)
        XCTAssertEqual(back[1], rows[0])
        XCTAssertEqual(back[2], rows[1])
    }

    // MARK: GridValue

    func testGridValueDisplay() {
        XCTAssertEqual(GridValue.integer(-42).display, "-42")
        XCTAssertEqual(GridValue.real(3.0).display, "3")
        XCTAssertEqual(GridValue.real(3.25).display, "3.25")
        XCTAssertEqual(GridValue.null.display, "")
        XCTAssertEqual(GridValue.blob(Data([1, 2, 3])).display, "<blob 3 bytes>")
    }

    func testGridValueCodable() {
        let values: [GridValue] = [.null, .text("中文"), .integer(7), .uinteger(18), .real(1.5), .blob(Data([0xFF]))]
        let data = try! JSONEncoder().encode(values)
        let back = try! JSONDecoder().decode([GridValue].self, from: data)
        XCTAssertEqual(back, values)
    }
}
