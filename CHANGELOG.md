# Move Event Toast Changelog

## v2.0.0
- New: `/moveet` now opens a configuration window with X/Y boxes, a clickthrough checkbox and a disable checkbox, plus a move mode with a green drag box. `/moveet reset` restores every setting to the game's defaults; any other input opens the window. The old slash subcommands (coordinates, `preview`, `clickthrough yes/no`, `disable yes/no`, `print`) are gone.
- Fixed: the saved position is now applied at login — previously the first toast of a session always used the game's placement until something re-triggered the move.
- Fixed: moving the toast can no longer disturb the toast itself (sticky score popups work normally again).
- Changing settings while fighting (or in Mythic+ / rated PvP) no longer risks errors — changes are remembered quietly and applied when the fight ends. The addon also keeps working after a UI reload mid-fight.
- New toasts arriving while clickthrough is on are clickthrough too, including their title areas.
- Disabling now hides toasts immediately, and toasts arriving while disabled stay hidden until re-enabled.
- Existing settings carry over automatically: your saved position, clickthrough and disable choices keep working exactly as before.
