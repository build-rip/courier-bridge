# Courier Bridge API

This document describes the bridge contract that external clients should implement.

## Principles

- `chat.db` is the only source of truth
- clients derive conversation state by replaying events
- websocket is only a cursor notification channel
- mutation endpoints never return event payloads
- `conversationVersion` is a compatibility gate, not a cursor
- `latestEventSequence` is the only incremental sync cursor per conversation

## Auth

### `POST /api/pair`

Request:

```json
{
  "code": "ABC123",
  "deviceName": "Pixel 9"
}
```

Response:

```json
{
  "refreshToken": "...",
  "deviceId": "..."
}
```

### `POST /api/auth/token`

Request:

```json
{
  "refreshToken": "..."
}
```

Response:

```json
{
  "accessToken": "...",
  "expiresIn": 900
}
```

Use `Authorization: Bearer <accessToken>` for protected HTTP routes.

## Health

### `GET /api/status`

Response:

```json
{
  "online": true
}
```

## Conversations

### `GET /api/conversations`

Returns the current bridge view of all conversations.

Response:

```json
{
  "conversations": [
    {
      "conversationId": "iMessage;-;+15555550100",
      "chatGuid": "iMessage;-;+15555550100",
      "chatIdentifier": "+15555550100",
      "displayName": "Alex",
      "serviceName": "iMessage",
      "conversationVersion": 1,
      "latestEventSequence": 42,
      "indexedAt": "2026-03-09T00:00:00Z",
      "indexStatus": "ready"
    }
  ]
}
```

Client behavior:

- if local `conversationVersion` differs, wipe local state for that conversation and fetch from `1`
- if versions match and local sequence is behind, fetch events from the local sequence

### `GET /api/conversations/:id/events?conversationVersion=X&from=Y&limit=Z`

- `conversationVersion` is required
- `from` is the last event sequence the client already has; use `0` for an initial fetch
- `limit` defaults to `500` and is capped at `1000`

Success response:

```json
{
  "conversationId": "iMessage;-;+15555550100",
  "conversationVersion": 1,
  "latestEventSequence": 42,
  "from": 20,
  "nextFrom": 42,
  "hasMore": false,
  "events": [
    {
      "conversationID": "iMessage;-;+15555550100",
      "conversationVersion": 1,
      "eventSequence": 21,
      "eventType": "messageCreated",
      "payload": {
        "messageID": "A1B2C3",
        "senderID": "+15555550100",
        "isFromMe": false,
        "service": "iMessage",
        "sentAt": "2026-03-09T00:00:00Z",
        "text": "hello",
        "richText": null,
        "attachments": [],
        "replyToMessageID": null
      }
    }
  ]
}
```

Version mismatch response:

- status: `409 Conflict`

```json
{
  "resyncRequired": true,
  "conversationId": "iMessage;-;+15555550100",
  "conversationVersion": 2,
  "latestEventSequence": 57
}
```

Client behavior on `409`:

- wipe local data for that conversation
- refetch from `from=0` using the returned `conversationVersion`

## WebSocket

### `GET /ws?token=<access-token>`

The websocket only sends cursor notifications.

Message shape:

```json
{
  "type": "conversationCursorUpdated",
  "payload": {
    "conversationID": "iMessage;-;+15555550100",
    "conversationVersion": 1,
    "latestEventSequence": 42
  },
  "timestamp": "2026-03-09T00:00:00Z"
}
```

Client behavior:

- compare the pushed cursor with local state
- fetch missing events from `GET /api/conversations/:id/events`
- do not expect event payloads on the websocket

## Event Types

Current normalized `eventType` values:

- `messageCreated`
- `messageEdited`
- `messageDeleted`
- `reactionSet`
- `reactionRemoved`
- `messageReadUpdated`
- `messageDeliveredUpdated`

Event payloads intentionally contain normalized app meaning only. They do not expose Apple raw fields like `associated_message_type`.

## Mutations

Mutations are effect requests. They do not create events directly. The bridge validates the request, accepts it into a serialized mutation lane, and returns immediately. Authoritative results appear later through the conversation event log.

Response shape for all mutation endpoints:

```json
{
  "result": "success",
  "conversationVersion": 1,
  "latestEventSequence": 42,
  "failureReason": null
}
```

`result` is one of:

- `success`: the request was accepted by the bridge
- `failed`: the bridge rejected the request immediately; inspect `failureReason`

Important client behavior:

- treat `success` as acceptance only, not proof that the requested side-effect happened
- start a client-side timer after a successful mutation request and wait for the expected event-log change to arrive
- if the expected event(s) do not appear within your timeout window, show an error in the UI and allow retry
- expect immediate validation/precondition errors to come back as `failed`
- do not expect unknown bridge automation failures to be returned to the client; those are logged server-side and may only be visible as missing event-log updates

`latestEventSequence` in the mutation response is only the bridge's current cursor at acceptance time. It is not confirmation of the requested mutation.

### `POST /api/conversations/:id/messages`

Request:

```json
{
  "text": "hello",
  "conversationVersion": 1,
  "fromEventSequence": 42
}
```

Optional `recipient` is also accepted for direct-send flows, but the normal contract is to send within the route conversation.

### `POST /api/conversations/:id/tapback`

Adds a tapback if it is not already present.

Request:

```json
{
  "type": "love",
  "messageGUID": "A1B2C3",
  "partIndex": 0,
  "conversationVersion": 1,
  "fromEventSequence": 42
}
```

For emoji tapbacks:

```json
{
  "type": "emoji",
  "messageGUID": "A1B2C3",
  "partIndex": 0,
  "emoji": "🔥",
  "conversationVersion": 1,
  "fromEventSequence": 42
}
```

### `DELETE /api/conversations/:id/tapback`

Removes a tapback if it is currently present.

Request body matches `POST /api/conversations/:id/tapback`.

### `POST /api/conversations/:id/read`

Marks the conversation as read.

Request:

```json
{
  "conversationVersion": 1,
  "fromEventSequence": 42
}
```

## Devices

### `GET /api/devices`

Lists paired devices.

### `DELETE /api/devices/:id`

Revokes a paired device.

## Attachments

### `GET /api/attachments/:id`

Streams the attachment file by attachment ID. Clients should prefer the normalized
attachment GUID from conversation events; numeric attachment row IDs are still
accepted for compatibility.

### `GET /api/messages/:id/attachments`

Lists attachments for a message by message row ID.

## Admin

### `POST /api/admin/index-emoji?chat=<chatRowID>`

Refreshes cached custom emoji picker positions for UI automation.

### `GET /api/admin/emoji-index-status`

Returns whether an emoji picker index has been built.

## Removed Contracts

These old sync contracts should not be used anymore:

- `GET /api/sync`
- `GET /api/chats/:id/sync`
- per-chat split cursors like `msgAfter`, `rxnAfter`, `readAfter`, `deliveryAfter`
- raw websocket event payloads like `newMessage`, `reaction`, `readReceipt`, `deliveryReceipt`
