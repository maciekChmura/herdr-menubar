import Foundation
import Testing
@testable import HerdrMenubar

struct WebSocketTests {
    @Test func computesTheAcceptValueFromTheRFCExample() {
        // RFC 6455, section 1.3. rex answered this key with the same value.
        #expect(WebSocketConnection.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test(arguments: [0, 1, 125, 126, 127, 65535, 65536, 200_000])
    func framesSurviveEncodingAndDecoding(length: Int) throws {
        let payload = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let frame = WebSocketFrame(opcode: .text, payload: payload)

        for mask in [nil, [UInt8]([1, 2, 3, 4])] {
            let bytes = frame.encoded(maskKey: mask)
            let decoded = try #require(try WebSocketFrame.decode(bytes[...]))
            #expect(decoded.frame == frame)
            #expect(decoded.length == bytes.count)
        }
    }

    @Test func masksWhatAClientSends() {
        let bytes = WebSocketFrame(opcode: .text, payload: Array("Hi".utf8)).encoded(maskKey: [0xFF, 0, 0xFF, 0])
        #expect(bytes == [0x81, 0x82, 0xFF, 0, 0xFF, 0, UInt8(ascii: "H") ^ 0xFF, UInt8(ascii: "i")])
    }

    @Test func waitsForTheWholeFrame() throws {
        let bytes = WebSocketFrame(opcode: .text, payload: Array(repeating: 7, count: 300)).encoded()
        for cut in [0, 1, 3, 4, 299] {
            #expect(try WebSocketFrame.decode(bytes.prefix(cut)) == nil)
        }
        // A second frame behind the first stays for the next call.
        let two = bytes + WebSocketFrame(opcode: .ping, payload: []).encoded()
        let first = try #require(try WebSocketFrame.decode(two[...]))
        #expect(first.length == bytes.count)
        #expect(try WebSocketFrame.decode(two[first.length...])?.frame.opcode == .ping)
    }

    @Test func refusesUnknownOpcodesAndExtensions() {
        #expect(throws: HerdrError.self) { try WebSocketFrame.decode([0x83, 0x00][...]) }
        #expect(throws: HerdrError.self) { try WebSocketFrame.decode([0xC1, 0x00][...]) }
    }

    @Test func acceptsAnUpgradeWhateverTheHeaderCase() throws {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Sec-Websocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            "sec-websocket-protocol: rex.control.v1",
        ].joined(separator: "\r\n")
        try WebSocketConnection.validateHandshake(response: response, key: key, subprotocol: "rex.control.v1")
    }

    @Test func refusesAWrongUpgrade() {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let accept = "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        let proto = "Sec-WebSocket-Protocol: rex.control.v1"
        for response in [
            ["HTTP/1.1 404 Not Found", accept, proto],
            ["HTTP/1.1 101 Switching Protocols", "Sec-WebSocket-Accept: wrong", proto],
            ["HTTP/1.1 101 Switching Protocols", accept],
        ] {
            #expect(throws: HerdrError.self) {
                try WebSocketConnection.validateHandshake(response: response.joined(separator: "\r\n"), key: key, subprotocol: "rex.control.v1")
            }
        }
    }
}
