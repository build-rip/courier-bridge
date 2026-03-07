import Foundation

/// Sends messages using osascript subprocess (AppleScript).
public struct AppleScriptSender: Sendable {
    public init() {}

    /// Send a text message to a recipient via the Messages app scripting dictionary.
    /// - Parameters:
    ///   - text: The message text to send.
    ///   - recipient: Phone number or email address.
    ///   - service: public service alias. Defaults to the instant-message service.
    public func send(text: String, to recipient: String, service: String = ServiceAlias.instant) async throws {
        let escapedText = escapeForAppleScript(text)
        let escapedRecipient = escapeForAppleScript(recipient)
        let rawService = ServiceAlias.rawValue(service) ?? ServiceAlias.instantRawValue

        let script = """
            tell application "Messages"
                set targetService to 1st account whose service type = \(rawService == "SMS" ? "SMS" : ServiceAlias.instantRawValue)
                set targetBuddy to participant "\(escapedRecipient)" of targetService
                send "\(escapedText)" to targetBuddy
            end tell
            """

        try await runOsascript(script)
    }

    /// Send a message to an existing chat by chat identifier.
    /// This is more reliable for group chats.
    public func sendToChat(text: String, chatIdentifier: String) async throws {
        let escapedText = escapeForAppleScript(text)
        let escapedChat = escapeForAppleScript(chatIdentifier)

        let script = """
            tell application "Messages"
                set targetChat to chat id "\(escapedChat)"
                send "\(escapedText)" to targetChat
            end tell
            """

        try await runOsascript(script)
    }

    // MARK: - Private

    private func runOsascript(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice

            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: AppleScriptError.executionFailed(
                        status: process.terminationStatus,
                        message: errorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Escape a string for safe embedding in AppleScript.
    /// Prevents AppleScript injection by escaping backslashes and double quotes.
    private func escapeForAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public enum AppleScriptError: Error, CustomStringConvertible {
    case executionFailed(status: Int32, message: String)

    public var description: String {
        switch self {
        case .executionFailed(let status, let message):
            return "AppleScript failed (exit \(status)): \(message)"
        }
    }
}
