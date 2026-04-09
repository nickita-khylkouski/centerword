import Foundation

enum CenterWordDiagnostics {
    private static let queue = DispatchQueue(label: "CenterWordDiagnostics")

    static var logURL: URL {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CenterWord", isDirectory: true)
        return logsDirectory.appendingPathComponent("hotkey.log")
    }

    static func record(_ message: String) {
        queue.async {
            let fileManager = FileManager.default
            let directory = logURL.deletingLastPathComponent()

            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateIfNeeded()

            let line = "[\(Date().ISO8601Format())] \(message)\n"
            let data = Data(line.utf8)

            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: data)
                return
            }

            guard let handle = try? FileHandle(forWritingTo: logURL) else {
                return
            }

            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        }
    }

    private static func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 200_000 else {
            return
        }

        try? FileManager.default.removeItem(at: logURL)
    }
}
