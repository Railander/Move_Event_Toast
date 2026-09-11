# Move_Event_Toast — addon notes

Repositions Blizzard's `EventToastManagerFrame` (mainline only). One file `Move_Event_Toast.lua`; `/moveet` opens the config window, `/moveet reset` restores defaults. Workspace conventions live in `../AGENTS.md` (read first — layout, testing, taint rules, publishing).

## Why mainline-only

The toast manager lives in `Blizzard_FrameXML` with `AllowLoadGameType mainline` (`EventToastManager.lua` / `.xml`); classic FrameXML ships no toast files at all (only the `C_EventToastManager` data docs, which need no frame). One flavor toc is correct — there is no classic layout to support and no classic sim section.

## Retail 12.x combat-restriction audit (2026-09-11, vs the 12.1 dump)

Per-function gates for everything this addon touches (`SimpleFrame` / `SimpleScriptRegion` / `SimpleScriptRegionResizing` / `SimpleRegion` docs + `EventToastManager.lua`):

- **Gated** (`AllowedWhenUntainted`, blocked from tainted execution while ANY of the six restriction types is Active): `SetPoint` (Resizing-region, `IsProtectedFunction`), `SetScript`/`HookScript`/`GetScript`, `RegisterEvent`/`UnregisterEvent`, `RegisterForDrag`, `GetPoint` (`ConstSecretAccessor`, `SecretWhenAnchoringSecret` — even the reads), `C_Timer.After`. The whole options build + capture + hook install defers as one.
- **Gated harder** (`NotAllowed`): `EnableMouse` (the entire clickthrough switch).
- **Safe** (`AllowedWhenTainted`): `SetAlpha` (the disable fade works even mid-protection).
- **Unproven** (no gate annotation — sim-clean, needs the in-game seal like everything else): `Show`/`Hide` (all visibility toggles), `ClearAllPoints` (used only inside guarded appliers + the anchor lock).
- **Blizzard's own `DisplayToast` re-anchors on EVERY toast** (`UpdateAnchor`: `ClearAllPoints` + `SetPoint` back to `TOP 0 -190`, including per-texture-kit custom offsets) — that re-anchor is what the anchor lock neutralizes.
- Chat/`print` is best-effort while locked: lock paths are fully silent, the first-run greet queues for the lift. Matches RTL/MFC/MRM.

## Design (v2 rewrite, RTL/MFC/MRM lessons applied)

- **`MoveET_LoadState` (pure Lua, safe anytime) vs `MoveET_EnsureGatedInit` (gated, idempotent, deferred)** — the MFC/MRM split. File scope resolves the frame only (the v1 file-scope `GetPoint` crashed the whole addon when the manager wasn't ready); the lock is checked before ANY install, so a `/reload`-in-combat boots with zero violations, fully deaf, and self-heals via restriction-lift confirm, `PLAYER_REGEN_ENABLED`, zone re-checks, or the next slash use.
- **Anchor lock (MFC pattern), zero `hooksecurefunc`** — v1's `hooksecurefunc(EventToastManagerFrame, "DisplayToast")` is the exact flagged taint pattern (taints Blizzard's own toast path). Replaced by: privately kept `ClearAllPoints`/`SetPoint` originals + no-op lock (no-ops make no gated calls, so a Blizzard re-anchor landing mid-protection silently does nothing), plus an `OnShow` post-hook (every `DisplayToast` ends in Show-or-Hide through untainted Blizzard execution) that re-applies position, re-hides while disabled, and applies the mouse state to each newly pooled toast. v1's stale-toast gap (only the current toast went clickthrough) is gone by construction.
- **Disable = `SetAlpha(0)` + `Hide`** (both safe while locked) + guarded `EnableMouse(false)`; clickthrough = guarded `EnableMouse(false)` on the manager + current toast + both mouseover frames. Every applier self-guards on the six-type lock FIRST and queues (`pendingPosition/Clickable/Greet/Win`) for the lift flush.
- **v1 import**: the old slash addon saved exactly `{ x, y, clickthrough, disable }` under this same name — all four carry over verbatim, `win` backfills, no re-greet (covered by the carryover tests).
- **Move mode (MFC/MRM pattern)**: green 50% `BACKGROUND` box (418×72, the manager's `fixedWidth`/`minimumHeight`) + transparent `TOOLTIP` input as UIParent siblings, so the spot is marked even while the manager is hidden (no toast showing). Cursor-driven math from `db` (exact grab, `TOP`-anchor units: `ax = pw/2 + x`, `ay = ph + y`), `OnUpdate` only while dragging. Entering refuses silently while locked; mid-drag lock ends the gesture; window close leaves move mode.
- **Round every layout-derived value at the boundary** (`MoveET_Round2`, declared above all storers): capture, reset, sanitize (heals old float saves), drags, inputs.
- **Locals-prefix + locals-order discipline**: `MoveET_`-prefixed state declared above all readers, forward declarations for the restriction/drag entry points; `tests/test_moveet.lua` asserts via `luac -l -p` that `SLASH_MOVEET1` is the only `SETGLOBAL` and no `GETGLOBAL` references any `MoveET_` name.
- **Suite**: `tests/lib.lua` (toast world mirroring the 12.1 XML: stock anchor, `SimDisplayToast` replaying the per-toast re-anchor), `test_moveet.lua` (69), `sim_mainline.lua` (15), `sim_restrictions.lua` on the shared harness (R1–R8 mainline max: silent deaf boot, silent slash self-heal, slash-heal lift, locked-toast containment, queued inputs + flush, mid-drag cancel, refused move-mode entry, zone re-checks + final audit — 43 checks). Determinism: 5× green.
- Sim gaps this design covers by construction (not by assertion): `GetPoint`/`ClearAllPoints` are ungated in the sim but treated as gated in the addon.

## TODO (12.x): in-game seal

1. `/reload` in combat on retail, then toast-generating actions + spot/checkbox changes while still in combat; confirm no errors and everything snaps into place after combat.
2. Rated PvP / M+ spot-check (restrictions held out of combat): config changes queue silently and apply on lift.
3. Confirm a live toast keeps the saved spot across chained toasts (animation `OnFinished` → `ToastingEnded` → `DisplayToast` path, which the lock covers without needing the event).

Residual: any other toast mover still fights this one (shared frame, last writer wins).
