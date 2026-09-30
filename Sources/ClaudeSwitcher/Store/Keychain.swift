import Foundation

/// Thin wrapper over `/usr/bin/security`, the same tool Claude Code uses for its own
/// credentials item. Going through it keeps the item's ACL exactly as Claude Code expects
/// and avoids Keychain prompts every time this app is rebuilt with a new ad-hoc signature.
enum Keychain {
    enum Failure: Error, LocalizedError {
        case commandFailed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let code, let message):
                return "Keychain command failed (\(code)): \(message)"
            }
        }
    }

    /// `security` exits with 44 when the item does not exist.
    static let itemNotFound: Int32 = 44
    /// Payloads longer than this go through argv instead of `security -i` (stdin line limit).
    private static let interactiveLimit = 4000

    /// Returns the stored secret, or nil when no such item exists.
    static func read(service: String, account: String? = nil) throws -> Data? {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        let result = run(args)
        if result.status == itemNotFound { return nil }
        guard result.status == 0 else { throw Failure.commandFailed(result.status, result.stderr) }
        var out = result.stdout
        if out.last == UInt8(ascii: "\n") { out.removeLast() }
        // `-w` prints non-printable secrets as hex; our payloads are JSON, but decode just in case.
        if let text = String(data: out, encoding: .utf8), !text.hasPrefix("{"), let decoded = Data(hex: text) {
            return decoded
        }
        return out
    }

    static func write(service: String, account: String, data: Data) throws {
        let hex = data.hexString
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        let result: (status: Int32, stdout: Data, stderr: String)
        if line.utf8.count <= interactiveLimit {
            result = run(["-i"], stdin: Data(line.utf8))
        } else {
            result = run(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        }
        guard result.status == 0 else { throw Failure.commandFailed(result.status, result.stderr) }
    }

    static func delete(service: String, account: String) {
        _ = run(["delete-generic-password", "-s", service, "-a", account])
    }

    private static func run(_ args: [String], stdin: Data? = nil) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        do {
            try process.run()
        } catch {
            return (-1, Data(), error.localizedDescription)
        }
        if let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, out, String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
