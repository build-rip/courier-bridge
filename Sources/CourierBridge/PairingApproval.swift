import AppKit

func requestPairingApproval(deviceName: String?, ipAddress: String?, country: String?) async -> Bool {
    await withCheckedContinuation { continuation in
        // Must use RunLoop.main.perform — @MainActor hops and DispatchQueue.main.async
        // are not serviced while NSApp.run() owns the main thread.
        RunLoop.main.perform {
            guard let controller = statusBarController else {
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
