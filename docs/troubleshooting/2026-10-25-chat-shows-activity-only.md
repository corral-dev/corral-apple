# Chat shows only Agent activity for a tool-heavy session (2026-10-25)

## Symptom

The native Mac client showed a running OpenCode session as one collapsed `Agent activity N tools` row plus `Working…`, with no prompt or reply. The owner read it as "conversation content does not render" and suspected a client regression from the same day's memory work.

## Measured

Two OpenCode sessions on the installed host and client:

- `SessionHub.conversation_page(key, limit=200)` returned 120 messages, all `assistant`, **none carrying `text`**.
- `session_message` for one held 277 `assistant` rows; first content item was `reasoning` in 224, `tool` in 52, `text` in 1. The remaining text sits in a few older turns.
- `sesskit.parsers.opencode.load_conversation` returns only text-bearing turns (2 messages for that session), so SessKit lost nothing.

Decisive comparison: the **same** projection (120 messages, 0 with text) is produced by the commit before the memory-retention changes and by the current tree. Not a renderer regression.

## Cause

A long tool-running turn leaves the loaded tail entirely `reasoning`/`tool` rows. The wire payload carries `text` only when a row has user-facing text (`richmsg.RichMessage.to_wire_dict`), so the chat correctly renders the activity grouping with nothing else to show; the user's own prompt is older than the loaded page and appears only after paging back.

## Check before touching rendering

1. Ask the host for the page: `SessionHub.conversation_page(key, limit=200)`; count messages with non-empty `text`.
2. Text present but nothing shown → investigate the client.
3. Text absent → inspect native rows (`select type, json_extract(data,'$.content[0].type'), count(*) ...`) and confirm the session has no text turn in the loaded window.

Do not add renderer fallbacks or stop collapsing tool activity to "fix" this.

## Limits

Two sessions on this machine, 2026-10-25. A session whose loaded page does contain text is not covered by this explanation.

<!-- 该文档整理/压缩于 2026-11-15 -->
