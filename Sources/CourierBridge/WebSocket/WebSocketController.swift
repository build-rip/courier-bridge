import Vapor
import CourierCore
import Foundation

/// Manages WebSocket connections and broadcasts events to all connected clients.
actor WebSocketController {
    private var clients: [UUID: WebSocket] = [:]
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    var clientCount: Int {
        clients.count
    }

    func connect(req: Request, ws: WebSocket) async {
        guard let token = req.query[String.self, at: "token"] else {
            try? await ws.close(code: .policyViolation)
            return
        }

        do {
            let _ = try await req.jwt.verify(token, as: AccessTokenPayload.self)
        } catch {
            try? await ws.close(code: .policyViolation)
            return
        }

        let id = UUID()
        clients[id] = ws

        print("[WS] Client connected: \(id) (total: \(clients.count))")

        ws.onClose.whenComplete { [weak self] _ in
            Task { await self?.disconnect(id: id) }
        }

    }

    func disconnect(id: UUID) {
        clients.removeValue(forKey: id)
        print("[WS] Client disconnected: \(id) (total: \(clients.count))")
    }

    func broadcast(cursorUpdate: ConversationCursorUpdate) {
        let envelope = ConversationCursorUpdateEnvelope(payload: cursorUpdate)
        guard let data = try? encoder.encode(envelope) else { return }
        guard let json = String(data: data, encoding: .utf8) else { return }

        for (id, ws) in clients {
            if ws.isClosed {
                clients.removeValue(forKey: id)
                continue
            }
            ws.send(json)
        }
    }
}
