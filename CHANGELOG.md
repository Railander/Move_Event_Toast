# Move Event Toast Changelog

## v2.0.0
- Rewritten around the same design as Move FPS Counter and Move Raid Manager: `/moveet` now opens a configuration window with X/Y boxes, a clickthrough checkbox and a disable checkbox, plus a move mode with a green drag box. `/moveet reset` restores every setting to the game's defaults; any other input opens the window. The old slash subcommands (coordinates, `preview`, `clickthrough yes/no`, `disable yes/no`, `print`) are gone.
- Fixed: the saved position is now applied at login — previously the first toast of a session always used the game's placement until something re-triggered the move.
- Fixed: the addon no longer hooks the game's toast display, so it can't interfere with the toast itself anymore.
- Combat-safe rewrite: changes made while fighting (or in Mythic+ / rated PvP) are remembered quietly and applied when the fight ends. The addon also keeps working after a UI reload mid-fight.
- New toasts arriving while clickthrough is on are clickthrough too, including their title mouseover areas.
- Disabling now hides toasts immediately, and toasts arriving while disabled stay hidden until re-enabled.
- Existing settings carry over automatically: your saved position, clickthrough and disable choices keep working exactly as before.
