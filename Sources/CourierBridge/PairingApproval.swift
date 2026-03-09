import AppKit

func requestPairingApproval(deviceName: String?, ipAddress: String?, country: String?) async -> Bool {
    await withCheckedContinuation { continuation in
        Task { @MainActor in
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
