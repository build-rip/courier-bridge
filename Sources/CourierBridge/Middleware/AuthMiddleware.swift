import Vapor
import JWT

/// JWT payload for access tokens.
struct AccessTokenPayload: JWTPayload, Sendable {
    let sub: SubjectClaim
    let exp: ExpirationClaim
    let deviceID: String

    enum CodingKeys: String, CodingKey {
        case sub, exp
        case deviceID = "device_id"
    }

    func verify(using algorithm: some JWTAlgorithm) throws {
        try exp.verifyNotExpired()
    }
}

/// Middleware that validates JWT Bearer tokens on protected routes.
struct AuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let authHeader = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing authorization header")
        }

        do {
            let payload = try await request.jwt.verify(authHeader.token, as: AccessTokenPayload.self)
            // Store device ID for downstream use
            request.storage[DeviceIDKey.self] = payload.deviceID
        } catch {
            throw Abort(.unauthorized, reason: "Invalid or expired token")
        }

        return try await next.respond(to: request)
    }
}

struct DeviceIDKey: StorageKey {
    typealias Value = String
}

extension Request {
    var deviceID: String? {
        storage[DeviceIDKey.self]
    }
}
