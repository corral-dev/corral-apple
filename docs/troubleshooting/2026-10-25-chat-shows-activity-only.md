# Chat shows only Agent activity for a tool-heavy session (2026-10-25)

## Symptom

The native Mac client shows a running OpenCode session as one collapsed
`Agent activity N tools` row plus `Working…`, with no visible prompt or reply.
The owner read it as "the conversation content does not render" and suspected a
client regression from the same day's memory work.

## What was measured

Two OpenCode sessions were checked on the installed host and client:

- `SessionHub.conversation_page(key, limit=200)` returned 120 messages whose
  roles were all `assistant` and **none of which carried `text`**.
- `session_message` for one of them held 277 `assistant` rows; the first content
  item was `reasoning` in 224 rows, `tool` in 52 and `text` in 1. The remaining
  text lives in a few older turns.
- `sesskit.parsers.opencode.load_conversation` returns only the text-bearing
  turns (2 messages for that session), so SessKit has not lost text.

The decisive comparison: the **same** projection counts (120 messages, 0 with
text) were produced by the commit before the memory-retention changes and by the
current tree. This is not a renderer regression.

## Cause

For a long tool-running turn the loaded tail is entirely `reasoning`/`tool`
rows. The wire payload only carries `text` when a row has user-facing text
(`richmsg.RichMessage.to_wire_dict`), so the chat correctly renders the activity
grouping with nothing else to show. The user's own prompt is older than the
loaded page and appears only after paging back.

## How to check before touching rendering

1. Ask the host for the page: `SessionHub.conversation_page(key, limit=200)` and
   count messages that have a non-empty `text`.
2. If `text` is present there but the client shows none, investigate the client.
3. If `text` is absent, inspect the native rows
   (`select type, json_extract(data,'$.content[0].type'), count(*) ...`) and
   confirm the session simply has not produced a text turn in the loaded window.

Do not add renderer fallbacks or stop collapsing tool activity to "fix" this.

## Limits

Measured on two sessions on this machine, 2026-10-25. A session whose loaded
page does contain text is not covered by this explanation.
