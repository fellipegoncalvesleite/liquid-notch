import XCTest
@testable import LiquidNotch

/// The text inside a Messages `attributedBody` (typedstream): "NSString", a few bytes, '+', a length, UTF-8.
final class MessageTextTests: XCTestCase {
    private func blob(_ text: String) -> Data {
        let utf8 = Array(text.utf8)
        var length: [UInt8] = utf8.count < 0x80 ? [UInt8(utf8.count)]
            : [0x81, UInt8(utf8.count & 0xFF), UInt8(utf8.count >> 8)]
        if utf8.count > 0xFFFF { length = [] }
        let head: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
            + Array("NSMutableAttributedString".utf8) + [0x00, 0x84, 0x84] + Array("NSAttributedString".utf8)
            + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
        return Data(head + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B] + length + utf8 + [0x86, 0x84])
    }

    func testShortText() {
        XCTAssertEqual(MessageText.decode(blob("On my way!")), "On my way!")
        XCTAssertEqual(MessageText.decode(blob("Jantar às 8? 🍝")), "Jantar às 8? 🍝")
    }

    func testLongText() {
        let long = String(repeating: "a long message ", count: 30)
        XCTAssertEqual(MessageText.decode(blob(long)), long)
    }

    func testGarbage() {
        XCTAssertNil(MessageText.decode(Data([1, 2, 3])))
        XCTAssertNil(MessageText.decode(Data("NSString".utf8)))
    }
}
