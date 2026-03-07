import Vapor
import JWT
import CourierCore

struct PairRequest: Content {
    let code: String
    let deviceName: String?
}

struct PairResponse: Content {
    let refreshToken: String
    let deviceId: String
}

struct TokenRequest: Content {
    let refreshToken: String
}

struct TokenResponse: Content {
    let accessToken: String
    let expiresIn: Int
}

struct DeviceResponse: Content {
    let id: String
    let name: String?
    let createdAt: String
    let lastSeenAt: String?

    init(from device: PairedDevice) {
        self.id = device.id
        self.name = device.name
        self.createdAt = DeviceResponse.toISO8601(device.createdAt)
        self.lastSeenAt = device.lastSeenAt
    }

    /// Convert SQLite datetime format ("2024-01-15 10:30:00") to ISO 8601 ("2024-01-15T10:30:00Z").
    /// If already ISO 8601, returns as-is.
    private static func toISO8601(_ dateString: String) -> String {
        if dateString.contains("T") { return dateString }
        return dateString.replacingOccurrences(of: " ", with: "T") + "Z"
    }
}

struct StatusResponse: Content {
    let status: String
    let uptime: TimeInterval
    let messageCount: Int
    let connectedClients: Int
    let lastChecked: Date
}

private let startTime = Date()

func authRoutes(_ app: RoutesBuilder) {
    // POST /api/pair - exchange pairing code for refresh token
    app.post("pair") { req -> PairResponse in
        let body = try req.content.decode(PairRequest.self)

        guard try req.appState.bridgeDB.redeemPairingCode(body.code) else {
            throw Abort(.unauthorized, reason: "Invalid or expired pairing code")
        }

        let clientIP = req.headers.first(name: "CF-Connecting-IP")
            ?? req.headers.first(name: "X-Forwarded-For")
        let country = req.headers.first(name: "CF-IPCountry")

        let approved = await requestPairingApproval(
            deviceName: body.deviceName,
            ipAddress: clientIP,
            country: country
        )
        guard approved else {
            throw Abort(.forbidden, reason: "Pairing denied by bridge operator")
        }

        let deviceID = UUID().uuidString
        let refreshToken = generateRefreshToken()

        try req.appState.bridgeDB.addDevice(
            id: deviceID,
            name: body.deviceName,
            refreshToken: refreshToken
        )

        return PairResponse(refreshToken: refreshToken, deviceId: deviceID)
    }

    // POST /api/auth/token - exchange refresh token for access token
    app.post("auth", "token") { req -> TokenResponse in
        let body = try req.content.decode(TokenRequest.self)

        guard let device = try req.appState.bridgeDB.findDeviceByRefreshToken(body.refreshToken) else {
            throw Abort(.unauthorized, reason: "Invalid refresh token")
        }

        try req.appState.bridgeDB.updateLastSeen(deviceID: device.id)

        let expiresIn = 900 // 15 minutes
        let payload = AccessTokenPayload(
            sub: SubjectClaim(value: device.id),
            exp: ExpirationClaim(value: Date().addingTimeInterval(TimeInterval(expiresIn))),
            deviceID: device.id
        )
        let token = try await req.jwt.sign(payload)

        return TokenResponse(accessToken: token, expiresIn: expiresIn)
    }

    // GET /api/status - bridge health (public)
    app.get("status") { req -> StatusResponse in
        let count = try req.appState.queries.messageCount()
        let clients = await req.appState.wsController.clientCount

        return StatusResponse(
            status: "ok",
            uptime: Date().timeIntervalSince(startTime),
            messageCount: count,
            connectedClients: clients,
            lastChecked: Date()
        )
    }

}

func deviceRoutes(_ protected: RoutesBuilder) {
    // GET /api/devices - list paired devices
    protected.get("devices") { req -> [DeviceResponse] in
        let devices = try req.appState.bridgeDB.listDevices()
        return devices.map(DeviceResponse.init)
    }

    // DELETE /api/devices/:id - revoke a paired device
    protected.delete("devices", ":id") { req -> Response in
        guard let deviceID = req.parameters.get("id") else {
            throw Abort(.badRequest)
        }
        try req.appState.bridgeDB.deleteDevice(id: deviceID)
        return Response(status: .noContent)
    }
}

private func generateRefreshToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
