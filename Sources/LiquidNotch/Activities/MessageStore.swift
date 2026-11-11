import Foundation
import SQLite3

/// Reads Messages' database (`~/Library/Messages/chat.db`) read-only. Needs Full Disk Access.
/// New messages keep their text in `attributedBody` (an archived NSAttributedString in the old
/// typedstream format) rather than `text`, so `MessageText` decodes that.
struct MessageStore {
    struct Message: Equatable {
        var rowID: Int64
        /// The sender's handle (phone number or email); nil for messages you sent.
        var sender: String?
        var text: String?
        var date: Date
        var fromMe: Bool
        var groupName: String?
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db")

    /// Whether the database can be read (Full Disk Access granted).
    static var readable: Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        return sqlite3_exec(db, "select 1 from message limit 1", nil, nil, nil) == SQLITE_OK
    }

    /// Row counts per table (spike readout; no content).
    static func counts() -> String {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return "open failed" }
        return ["message", "chat", "handle", "attachment"].map { t in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "select count(*), max(ROWID) from \(t)", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return "\(t)=?" }
            return "\(t)=\(sqlite3_column_int64(stmt, 0)) max \(sqlite3_column_int64(stmt, 1))"
        }.joined(separator: ", ")
    }

    /// The newest messages, newest first.
    static func latest(_ limit: Int, afterRowID: Int64 = 0) -> [Message]? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        let sql = """
            select m.ROWID, h.id, m.text, m.attributedBody, m.date, m.is_from_me, c.display_name
            from message m left join handle h on h.ROWID = m.handle_id
            left join chat_message_join j on j.message_id = m.ROWID left join chat c on c.ROWID = j.chat_id
            where m.ROWID > ? order by m.ROWID desc limit ?
            """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int64(stmt, 1, afterRowID)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [Message] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            var body: Data?
            if let blob = sqlite3_column_blob(stmt, 3) {
                body = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 3)))
            }
            // Apple's epoch (2001) in nanoseconds on current macOS.
            let raw = Double(sqlite3_column_int64(stmt, 4))
            let seconds = raw > 1e12 ? raw / 1e9 : raw
            let group = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            out.append(Message(rowID: sqlite3_column_int64(stmt, 0),
                               sender: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                               text: (text?.isEmpty == false ? text : nil) ?? body.flatMap(MessageText.decode),
                               date: Date(timeIntervalSinceReferenceDate: seconds),
                               fromMe: sqlite3_column_int(stmt, 5) != 0,
                               groupName: group?.isEmpty == false ? group : nil))
        }
        return out
    }
}

/// The text inside an `attributedBody` blob: an NSAttributedString archived as a typedstream. The
/// string follows the `NSString` class name: a `+` marker, a length (one byte, or 0x81 + two bytes,
/// or 0x82 + four, little-endian), then UTF-8.
enum MessageText {
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard let start = find(marker, in: bytes) else { return nil }
        var i = start + marker.count
        // Skip to the '+' that introduces the string (within a few bytes of the class name).
        while i < min(bytes.count, start + marker.count + 12), bytes[i] != 0x2B { i += 1 }
        guard i < bytes.count, bytes[i] == 0x2B else { return nil }
        i += 1
        guard i < bytes.count else { return nil }
        var length = Int(bytes[i])
        i += 1
        if length == 0x81 {
            guard i + 2 <= bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            i += 2
        } else if length == 0x82 {
            guard i + 4 <= bytes.count else { return nil }
            length = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
            i += 4
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }
}
