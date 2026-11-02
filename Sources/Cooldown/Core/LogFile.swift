import Foundation

/// Appends to Cooldown's own small logs in Application Support. Each is kept to `limit` bytes
/// in two files: when the current one grows past it, it becomes `<name>.1.log`.
enum LogFile {
    static func append(_ text: String, to name: String, limit: UInt64) {
        let url = Settings.appSupport.appendingPathComponent("\(name).log")
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? Data(text.utf8).write(to: url)
            return
        }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        let size = handle.offsetInFile
        try? handle.close()
        if size > limit {
            let old = Settings.appSupport.appendingPathComponent("\(name).1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
    }
}
