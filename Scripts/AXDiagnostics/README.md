# AX Diagnostics — Targeted Tapback Investigation

These scripts were used during development of the targeted tapback feature to
explore the Messages.app accessibility tree, test different approaches to
triggering tapbacks programmatically, and diagnose reliability issues.

## Investigation Timeline

### Phase 1: AX Tree Discovery
We started by dumping the Messages.app accessibility hierarchy to understand
its structure. Key findings:
- The transcript is an `AXGroup` with `id="TranscriptCollectionView"` (NOT an AXScrollArea)
- Message bubbles are `AXTextArea` elements with `id="CKBalloonTextView"` (NOT AXStaticText)
- Message text is in the `AXValue` attribute of these text areas

### Phase 2: AXShowMenu Testing
We tried using `AXShowMenu` on message elements to open the tapback context menu
and then selecting the reaction from it. Initial tests succeeded, but further
testing revealed inconsistent behavior:
- Some messages always got tapback menus (e.g., "Hey")
- Some messages always got TEXT-EDIT context menus (e.g., "Ping pong")
- The behavior was message-specific — NOT related to:
  - Clipping (partially off-screen messages)
  - Wait times (tested 200ms to 1200ms)
  - Emoji content (Wordle scores vs plain text)
  - Invocation target (parent row vs balloon element)
  - State contamination from prior menu operations

### Phase 3: Direct Custom Actions (Breakthrough)
A comprehensive attribute comparison revealed that every `CKBalloonTextView`
exposes custom named actions for all tapback types:
```
"Name:Heart\nTarget:0x0\nSelector:(null)"
"Name:Thumbs up\nTarget:0x0\nSelector:(null)"
"Name:Thumbs down\nTarget:0x0\nSelector:(null)"
"Name:Ha ha!\nTarget:0x0\nSelector:(null)"
"Name:Exclamation mark\nTarget:0x0\nSelector:(null)"
"Name:Question mark\nTarget:0x0\nSelector:(null)"
```

These can be invoked directly via `AXUIElementPerformAction()` — no context
menu needed. This approach is:
- 100% reliable on ALL messages (including ones where AXShowMenu failed)
- Faster (no menu open/close, no wait for items to populate)
- Simpler (no menu item search logic needed)

This is the approach used in the production implementation.

## Scripts

### `test_clipping_and_wait_times.swift`
Tests whether message clipping or insufficient wait times cause AXShowMenu to
produce the wrong menu type. Conclusion: neither is the cause.

### `test_emoji_and_message_type.swift`
Tests whether emoji-heavy messages (Wordle scores) behave differently from
plain text messages with AXShowMenu. Conclusion: the issue is message-specific,
not content-type-specific.

## Running

```bash
# Make executable
chmod +x Scripts/AXDiagnostics/*.swift

# Run (Messages.app must be open with a chat visible)
swift Scripts/AXDiagnostics/test_clipping_and_wait_times.swift
swift Scripts/AXDiagnostics/test_emoji_and_message_type.swift
```

Requires Accessibility permissions: System Settings > Privacy & Security > Accessibility.
