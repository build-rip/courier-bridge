import AppKit

@MainActor
func requestPairingApproval(deviceName: String?, ipAddress: String?, country: String?) async -> Bool {
    await withCheckedContinuation { continuation in
        RunLoop.main.perform { [continuation] in
            guard let controller = (NSApp.delegate as? AppDelegate)?.statusBarController else {
                continuation.resume(returning: false)
                return
            }
            controller.handleApprovalRequest(
                deviceName: deviceName,
                ipAddress: ipAddress,
                country: country,
                continuation: continuation
            )
        }
    }
}
