import Vapor

func registerRoutes(_ app: Application) throws {
    let api = app.grouped("api")

    // Public routes (no auth)
    authRoutes(api)

    // Protected routes (require JWT)
    let protected = api.grouped(AuthMiddleware())
    chatRoutes(protected)
    messageRoutes(protected)
    attachmentRoutes(protected)
    deviceRoutes(protected)
    adminRoutes(protected)

    // WebSocket route (auth via query param)
    app.webSocket("ws") { req, ws in
        await req.appState.wsController.connect(req: req, ws: ws)
    }

    // Root redirect to web UI
    app.get { req -> Response in
        req.redirect(to: "/index.html")
    }
}
