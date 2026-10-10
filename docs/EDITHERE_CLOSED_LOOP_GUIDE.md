# EditHere Debug closed-loop (host)

**Must read** before implementing or reviewing Debug-only EditHere integration in Corral iOS, or before claiming a mark→agent→code-change loop works. Skipping it will put Corral types into the EditHere package, skip PNG→JPEG, or treat Submit as proof of a correct source edit.

Authoritative adapter design (ownership, binding, submit order, image path-paste semantics, verification bar, out-of-scope list):

`~/Codes/EditHere/sdk-swift/docs/CORRAL_CLOSED_LOOP_ADAPTER_DESIGN.md`

The generated Agent prompt (numbered pages + structured request list) is EditHere’s **core capability**, owned in EditHere Core — **must read** `~/Codes/EditHere/sdk-swift/docs/design/AGENT_PROMPT_CORE_DESIGN.md` before wrapping Submit for Corral. Skipping it replaces the canonical prompt, drops screenshot catalog/hints, or starts one session per mark.

Status on 2026-09-12: design written; **implementation paused** by request. Do not invent a different ownership model without updating that document first.

<!-- 该文档整理/压缩于 2026-09-29 -->
