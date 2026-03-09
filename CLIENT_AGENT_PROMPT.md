# Client Migration Prompt

You are updating a client that integrates with Courier Bridge.

Read `API.md` first and treat it as the source of truth for the server contract.

## Context

Courier Bridge has moved to a new sync architecture with these non-negotiable rules:

- `chat.db` on macOS is the only source of truth
- the bridge now exposes a normalized per-conversation event log
- each conversation has exactly one sync cursor: `latestEventSequence`
- each conversation also has a compatibility gate: `conversationVersion`
- clients must derive conversation state by replaying events locally
- websocket is no longer an event transport; it only notifies clients that a conversation cursor changed
- mutation endpoints no longer return event payloads and do not confirm side-effects

## Old assumptions that must be removed

Do not preserve or reintroduce any of these client behaviors:

- split sync cursors like `msgAfter`, `rxnAfter`, `readAfter`, `deliveryAfter`
- consuming raw websocket payloads like `newMessage`, `reaction`, `readReceipt`, or `deliveryReceipt`
- merging mutation-response events with websocket events
- treating mutation success as proof that the requested side-effect happened
- relying on server-provided full conversation projections as sync truth

## New client behavior

Implement the client around these rules:

1. Fetch `GET /api/conversations` and store, per conversation:
   - `conversationId`
   - `conversationVersion`
   - `latestEventSequence`

2. Maintain local per-conversation event/state storage.

3. On startup or refresh:
   - if local `conversationVersion` differs from the server's, wipe local state for that conversation and refetch events from `from=0`
   - if versions match and local sequence is behind, fetch events from the local sequence until caught up

4. On websocket `conversationCursorUpdated`:
   - compare the pushed cursor against local state
   - fetch missing events via `GET /api/conversations/:id/events`
   - never expect full event payloads on the websocket

5. Rebuild conversation UI entirely from local event replay.

## Mutation behavior

Mutation endpoints now return acceptance, not confirmation.

- `result = success` means the bridge accepted the request into its mutation lane
- it does not mean the requested change has appeared in the authoritative event log yet
- validation/precondition failures should still arrive immediately as `failed`
- some bridge automation failures may never be surfaced directly and instead appear as the expected event not arriving

For every mutation flow:

1. Apply optimistic UI if appropriate.
2. Start a client-side timer after a successful mutation request.
3. Wait for the expected authoritative event-log change.
4. If the expected change arrives in time, clear the pending state.
5. If the timer expires first, show an error and allow retry or rollback.

## Implementation goals

- keep sync logic single-path: event fetch + local reduction only
- make replay deterministic and idempotent
- ensure reconnects and app restarts resume cleanly from persisted local event cursors
- handle `409 resyncRequired` by wiping local data for that conversation and fetching from the beginning

## Deliverable expectations

When you finish, provide:

- the files you changed
- how local event storage/reduction works now
- how websocket handling changed
- how mutation UX now waits on event-log confirmation
- any follow-up risks or edge cases
