-- Move Event Toast
-- Moves the game's Event Toast window (EventToastManagerFrame) and remembers
-- the spot, with clickthrough and disable switches. Mainline only: the toast
-- manager lives in Blizzard_FrameXML with AllowLoadGameType mainline (classic
-- FrameXML ships no toast files at all), so one flavor toc is correct.
--
-- Blizzard re-anchors the manager inside every DisplayToast (UpdateAnchor does
-- ClearAllPoints + SetPoint back to TOP 0 -190, including per-texture-kit
-- custom offsets), and only there. Once positioned, the manager's own anchor
-- methods become no-ops (the originals are kept privately and every apply
-- goes through them), so no Blizzard re-anchor, UI reload pass or other
-- toast mover can displace it -- the MFC anchor-lock pattern. A post-hook on
-- the manager's OnShow (fired at the end of every DisplayToast, which always
-- ends in Show-or-Hide) re-applies the saved position and the clickthrough
-- state onto each newly pooled toast. There is zero hooksecurefunc anywhere:
-- hooking Blizzard's DisplayToast Lua method would taint Blizzard's own
-- toast path and degrade restricted calls made from it while protected.
-- Everything is event driven: no polling and no per-frame code. /moveet
-- opens the config window (with a move mode that makes the toast spot
-- drag-movable), /moveet reset restores the defaults.
--
-- Midnight (12.x) restriction discipline: while any addon restriction is
-- active (Combat/Encounter/ChallengeMode/PvPMatch/Map/Chat -- rated PvP and
-- Mythic+ hold them out of combat, so the combat flag alone is the wrong
-- check) every gated call (SetPoint, EnableMouse, SetScript/HookScript,
-- RegisterEvent, even anchor reads like GetPoint) silently refuses or queues
-- instead of attempting, active drags cancel, and a /reload landing
-- mid-protection defers all gated setup until the lift is confirmed
-- out-of-dispatch. Safe while locked and never guarded: SetAlpha
-- (AllowedWhenTainted) and Show/Hide (house rule 3 -- sim-clean, sealed
-- in game like every other addon here).

local ADDON_NAME = "Move_Event_Toast";

-- Blizzard's EventToastManagerFrame loads from FrameXML before user addons,
-- so it normally exists at file scope; on an unknown layout stay inert (the
-- slash handler retries, so a late-loading manager still boots). Nothing is
-- read from the frame here: a file-scope GetPoint crashed the whole v1 addon
-- whenever the manager wasn't ready yet.
local manager = EventToastManagerFrame;
if not manager then
	return;
end

-- ingame instructions, in the same scheme as the other Move_* addons
local exitColor = "|r";
local colorOrange = "|cFFDF9F1F";
local function MoveET_instructions()
	-- commands sit outside the color spans, so they render in the chat's
	-- default white while the surrounding text stays orange
	print(colorOrange .. "Use " .. exitColor .. "/moveet" .. colorOrange .. " to open the configuration window." .. exitColor);
	print(colorOrange .. "Use " .. exitColor .. "/moveet reset" .. colorOrange .. " to restore the defaults." .. exitColor);
end

-- the game's own placement (EventToastManager.xml: TOP 0 -190), used until
-- the stock layout is captured while clear and as the reset target
local STOCK_X, STOCK_Y = 0, -190;
local MAX_COORD = 100000;
local BOX_W, BOX_H = 418, 72; -- the manager's fixedWidth/minimumHeight from the XML

-- Rounds to 2 decimals (declared HERE, above every storer: stock capture,
-- reset and sanitize all persist coordinates, and the client's float32
-- layout math hands GetPoint values like -140.00001525879 back -- without
-- rounding that 16-char string overflows a 9-char coordinate box, which then
-- shows its scrolled tail while GetText still reads fine).
local function MoveET_Round2(v)
	return math.floor(v * 100 + 0.5) / 100;
end

local db; -- alias for the Move_Event_Toast SavedVariables table, set on ADDON_LOADED
local options, refreshWindow; -- config window and its refresher, built below

-- Restriction state (Midnight 12.x). Declared HERE, above every function
-- that reads or writes them: Lua upvalues bind at closure creation, so a
-- later `local` would leave earlier paths writing to a same-named global
-- instead. Classic flavors never lock (no gate system -- the queries below
-- always read false there), so one code path serves all.
local MoveET_restrictionsActive = false;
local MoveET_restrictedTypes = {}; -- per-type marks from ADDON_RESTRICTION_STATE_CHANGED payloads
local MoveET_gatedInitDeferred = false;
local MoveET_stateLoaded = false; -- db backfilled (pure Lua, safe anytime)
local MoveET_initDone = false; -- gated apply finished (capture/build/position/hooks)
local MoveET_hooksInstalled = false; -- OnShow post-hook (HookScript is gated)
local MoveET_captured = false; -- stock placement + anchor methods captured while clear
local MoveET_anchored = false; -- the manager's own anchor methods are no-ops (MFC lock)
local MoveET_pendingPosition = false; -- position re-apply skipped while locked
local MoveET_pendingClickable = false; -- mouse-state apply skipped while locked
local MoveET_pendingGreet = false; -- first-run tutorial skipped while locked (chat is best-effort)
local MoveET_pendingWin = false; -- options-window re-anchor skipped while locked
local MoveET_moveModeOn = false; -- move mode: the green box + drag input are shown
local MoveET_moveDragging = false; -- a drag gesture is in flight (OnUpdate early-returns without it)
local MoveET_moveBox; -- green 50% box over the toast spot, marking its rect
local MoveET_moveInput; -- transparent drag input above the spot
local MoveET_grabDX, MoveET_grabDY; -- cursor offset from the anchor point at grab time
-- Forward declarations: assigned further below, called from early restriction
-- paths and mid-file appliers (bound here so they resolve correctly).
local MoveET_EnsureGatedInit;
local MoveET_FlushPending;
local MoveET_RegisterAddonEvents;
local MoveET_DetachDrag;
local MoveET_DragUpdate;
local MoveET_SetMoveMode;
local MoveET_BeginDrag;
local MoveET_EndDrag;
local MoveET_SyncMoveBox;
local MoveET_IsInteractionLocked;
local MoveET_EventFrame; -- listener frame, created at file load below

-- stock layout, captured while clear (every read below is gated, so
-- capturing defers as one with the rest of gated init)
local stockX, stockY = STOCK_X, STOCK_Y; -- the game's own toast placement
-- the manager's own anchor methods, kept privately once captured: every
-- apply below goes through these, so the no-op lock never blocks us
local origClear, origSetPoint;

-- Capture the stock layout: the game's own placement plus the anchor
-- methods the lock later swaps out. Gated reads (GetPoint most of all), so
-- this runs only while clear, inside gated init.
local function MoveET_CaptureStock()
	if MoveET_captured then
		return;
	end
	origClear, origSetPoint = manager.ClearAllPoints, manager.SetPoint;
	local ok, point, relativeTo, relativePoint, x, y = pcall(manager.GetPoint, manager, 1);
	if ok and x ~= nil and y ~= nil then
		stockX, stockY = MoveET_Round2(x), MoveET_Round2(y);
	end
	MoveET_captured = true;
end

-- ----------------------------------------------------------------------------
-- Restriction state (Midnight 12.x): lock taint-able work while protected
-- ----------------------------------------------------------------------------
-- Six restriction types (Enum.AddOnRestrictionType, identical in every dump):
-- Combat, Encounter, ChallengeMode (M+), PvPMatch, Map, Chat. While ANY type
-- is active, gated calls from addon execution fail silently -- so while
-- locked this addon refuses or queues instead of attempting: every applier
-- below checks the lock FIRST (before even its gated reads like GetPoint)
-- and remembers the work for the lift. Chat notices never emit on lock paths
-- (they neither render while protected nor get read in combat -- blocked
-- input just does nothing). Safe while locked and never guarded: SetAlpha,
-- Show/Hide, db table work.
local MoveET_RESTRICTION_FALLBACK = { 0, 1, 2, 3, 4, 5 }; -- Combat..Chat
local MoveET_RESTRICTION_STATE = { inactive = 0, activating = 1, active = 2 };

local function MoveET_RestrictionTypeIDs()
	if Enum and Enum.AddOnRestrictionType then
		local t = Enum.AddOnRestrictionType;
		local out = {};
		for _, id in ipairs({ t.Combat, t.Encounter, t.ChallengeMode, t.PvPMatch, t.Map, t.Chat }) do
			if id ~= nil then
				out[#out + 1] = id;
			end
		end
		if #out > 0 then
			return out;
		end
	end
	return MoveET_RESTRICTION_FALLBACK;
end

local function MoveET_RestrictionStateID(name)
	if Enum and Enum.AddOnRestrictionState and Enum.AddOnRestrictionState[name] ~= nil then
		return Enum.AddOnRestrictionState[name];
	end
	return MoveET_RESTRICTION_STATE[name];
end

-- Full all-types query. Must NEVER run during ADDON_RESTRICTION_STATE_CHANGED
-- dispatch (IsAddOnRestrictionActive reads false there by design); that
-- handler maintains per-type marks from the payload instead.
local function MoveET_AreRestrictionsActive()
	if C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive then
		for _, rtype in ipairs(MoveET_RestrictionTypeIDs()) do
			local ok, active = pcall(C_RestrictedActions.IsAddOnRestrictionActive, rtype);
			if ok and active then
				return true;
			end
		end
		return false;
	end
	if InCombatLockdown then
		return InCombatLockdown() and true or false;
	end
	return false;
end

-- Live check: the latched flag covers dispatch windows where the query reads
-- false by design; the query covers events missed while a registration was
-- down. Either side locks. Callers are input/event-driven (never per-frame),
-- so the handful of pcall'd queries per gesture is negligible.
MoveET_IsInteractionLocked = function()
	return MoveET_restrictionsActive or MoveET_AreRestrictionsActive();
end

local function MoveET_ApplyRestrictionsActive()
	MoveET_restrictionsActive = true;
	-- end an in-flight drag without touching gates: the flag stops the
	-- OnUpdate (hidden frames tick nothing anyway) and the detach below is
	-- best-effort -- while enforced it stays as a nil-cost early-return until
	-- the next unrestricted stop or lift detaches it. The box itself stays
	-- put: the manager cannot move either, so it stays accurate.
	MoveET_moveDragging = false;
	MoveET_DetachDrag();
end

local function MoveET_ApplyRestrictionsCleared()
	MoveET_restrictionsActive = false;
	for k in pairs(MoveET_restrictedTypes) do
		MoveET_restrictedTypes[k] = nil;
	end
	MoveET_EnsureGatedInit();
end

-- Re-query outside event dispatch; clears the lock only when every type is idle.
local function MoveET_ConfirmRestrictionsCleared()
	if not MoveET_AreRestrictionsActive() then
		MoveET_ApplyRestrictionsCleared();
	end
end

-- Re-query and apply whichever side is true. Both sides are silent. The clear
-- side is cheap when there is nothing to resume: only a lock episode, a
-- deferred init, queued work, or a never-finished init runs the full resume.
local function MoveET_RefreshRestrictionState()
	if MoveET_AreRestrictionsActive() then
		MoveET_ApplyRestrictionsActive();
		return true;
	end
	if MoveET_restrictionsActive or MoveET_gatedInitDeferred or not MoveET_initDone
		or MoveET_pendingPosition or MoveET_pendingClickable then
		MoveET_ApplyRestrictionsCleared();
	end
	return false;
end

-- ----------------------------------------------------------------------------
-- core behavior: every applier checks the lock FIRST (before even its gated
-- reads) and queues instead of attempting, so a call from any path -- hooks,
-- slash, options, lift flush -- is safe by construction
-- ----------------------------------------------------------------------------

-- While positioned, the manager's own anchor methods are no-ops so neither
-- Blizzard's UpdateAnchor (every DisplayToast resets to TOP 0 -190) nor any
-- other toast mover can displace it behind our back; our own applies go
-- through the privately kept originals. The no-ops make no gated calls
-- themselves, so a Blizzard re-anchor landing mid-protection simply does
-- nothing instead of failing.
local function MoveET_SetLocked(locked)
	if locked == MoveET_anchored or not MoveET_captured then
		return;
	end
	MoveET_anchored = locked;
	if locked then
		manager.ClearAllPoints = function() end;
		manager.SetPoint = function() end;
	else
		manager.ClearAllPoints = origClear;
		manager.SetPoint = origSetPoint;
	end
end

-- Re-apply the saved position over the manager's current anchor. GetPoint is
-- gated: while locked the Blizzard anchor (already ours, via the lock)
-- stands until the lift flush.
local function MoveET_ApplyPosition()
	if not db or not MoveET_captured then
		return;
	end
	if MoveET_IsInteractionLocked() then
		MoveET_pendingPosition = true;
		return;
	end
	origClear(manager);
	origSetPoint(manager, "TOP", UIParent, "TOP", db.x, db.y);
end

-- Apply the mouse state to the manager and whichever toast is currently
-- pooled: clickthrough (or disable) means nothing here intercepts clicks.
-- EnableMouse is NotAllowed-gated, so while locked the current state stands
-- and the apply queues for the lift.
local function MoveET_ApplyClickable()
	if not db or not MoveET_captured then
		return;
	end
	if MoveET_IsInteractionLocked() then
		MoveET_pendingClickable = true;
		return;
	end
	local enabled = (not db.clickthrough) and (not db.disable);
	manager:EnableMouse(enabled);
	local toast = manager.currentDisplayingToast;
	if toast then
		if toast.EnableMouse then
			toast:EnableMouse(enabled);
		end
		if toast.TitleTextMouseOverFrame and toast.TitleTextMouseOverFrame.EnableMouse then
			toast.TitleTextMouseOverFrame:EnableMouse(enabled);
		end
		if toast.SubTitleMouseOverFrame and toast.SubTitleMouseOverFrame.EnableMouse then
			toast.SubTitleMouseOverFrame:EnableMouse(enabled);
		end
	end
end

-- Apply the disable switch. SetAlpha is AllowedWhenTainted (visual-only,
-- safe even mid-protection); hiding is ungated per house rule 3, so a
-- disable lands instantly even while locked and a toast arriving while
-- disabled is re-hidden by the OnShow post-hook below.
local function MoveET_ApplyDisable()
	if not db or not MoveET_captured then
		return;
	end
	if db.disable then
		manager:SetAlpha(0);
		manager:Hide();
	else
		manager:SetAlpha(1);
	end
	MoveET_ApplyClickable(); -- queues itself while locked
end

-- Fired after Blizzard's own display work: every DisplayToast ends in
-- Show-or-Hide, so this post-hook sees each newly pooled toast. It runs
-- inside Blizzard's call chain, so its body is restricted to the safe set
-- plus self-guarding appliers (which queue while locked).
local function MoveET_OnManagerShow()
	MoveET_ApplyPosition();
	if db and db.disable then
		manager:Hide();
	end
	MoveET_ApplyClickable();
end

-- restore every setting to the game's own behavior (db work is pure Lua and
-- always lands; the applies queue themselves while locked). Every saved
-- value goes back, including the config window's own position -- as if the
-- addon was never enabled.
local function MoveET_Reset()
	if not db then
		return;
	end
	db.x, db.y = stockX, stockY;
	db.clickthrough, db.disable = false, false;
	db.win = { x = 0, y = 0 };
	MoveET_ApplyPosition(); -- restores the game's own placement
	MoveET_ApplyDisable(); -- alpha back to 1, mouse back on (queued while locked)
	-- note: reset touches values only -- the window stays open and move mode
	-- stays on (the box follows the reset spot through refreshWindow below)
	if options then
		if MoveET_IsInteractionLocked() then
			MoveET_pendingWin = true;
		else
			options:ClearAllPoints();
			options:SetPoint("CENTER", UIParent, "CENTER", 0, 0);
		end
	end
	if refreshWindow then
		refreshWindow(); -- the window (and the move box) follows the reset
	end
	if options and options.xBox and not MoveET_IsInteractionLocked() then
		-- force the boxes: they may hold keyboard focus or a format-equal
		-- string ("-190.0") that the conditional refresh skips, leaving
		-- stale visible text on the real client
		options.xBox:ClearFocus();
		options.yBox:ClearFocus();
		options.xBox:SetText(tostring(db.x));
		options.yBox:SetText(tostring(db.y));
	end
end

-- v1 carryover: the old slash-command addon saved exactly
-- { x, y, clickthrough, disable } under this same name. All four keep
-- working verbatim (v1's parser only wrote single-decimal coords, which
-- round-trip cleanly) while the new win key backfills below -- no re-greet,
-- the window is introduced in the changelog instead.
local function MoveET_Sanitize(dbt)
	dbt.x = MoveET_Round2(tonumber(dbt.x) or stockX);
	dbt.y = MoveET_Round2(tonumber(dbt.y) or stockY);
	if dbt.x < -MAX_COORD or dbt.x > MAX_COORD then dbt.x = stockX; end
	if dbt.y < -MAX_COORD or dbt.y > MAX_COORD then dbt.y = stockY; end
	dbt.clickthrough = dbt.clickthrough and true or false;
	dbt.disable = dbt.disable and true or false;
	if type(dbt.win) ~= "table" then
		dbt.win = {};
	end
	dbt.win.x = MoveET_Round2(tonumber(dbt.win.x) or 0);
	dbt.win.y = MoveET_Round2(tonumber(dbt.win.y) or 0);
end

-- ----------------------------------------------------------------------------
-- move mode: drag the toast spot, following the MFC/MRM drag proxy pattern
-- ----------------------------------------------------------------------------
-- Entering move mode shows a green 50% box exactly over the toast spot at a
-- lower strata (BACKGROUND, so a live toast overlays it) plus a transparent
-- drag input above it (TOOLTIP, so grabs land). Both are UIParent siblings
-- copying the saved anchor, so they also mark the spot while the manager
-- itself is hidden (no toast showing) -- where the next toast would land.
-- The math is cursor-driven, never read back from the box: the box follows
-- the db, so reading it would feed our own movement back into the next
-- update and run away. The OnUpdate script only exists while a drag is
-- active and is removed on release, so there is no per-frame cost outside
-- of it.

-- Best-effort OnUpdate detach: the script needs gates, so while locked it
-- stays as a nil-cost early-return (hidden frames tick nothing anyway) until
-- the next unrestricted stop or lift detaches it.
MoveET_DetachDrag = function()
	if MoveET_moveInput and not MoveET_IsInteractionLocked() then
		MoveET_moveInput:SetScript("OnUpdate", nil);
	end
end;

local function MoveET_BuildMoveUI()
	if MoveET_moveBox then
		return;
	end
	MoveET_moveBox = CreateFrame("Frame", "Move_Event_ToastMoveBox", UIParent);
	MoveET_moveBox:SetFrameStrata("BACKGROUND");
	MoveET_moveBox:SetFrameLevel(1);
	MoveET_moveBox:EnableMouse(false);
	local tex = MoveET_moveBox:CreateTexture(nil, "BACKGROUND");
	tex:SetColorTexture(0, 1, 0, 0.5);
	tex:SetAllPoints();
	MoveET_moveBox:Hide();
	MoveET_moveInput = CreateFrame("Frame", "Move_Event_ToastMoveInput", UIParent);
	MoveET_moveInput:SetFrameStrata("TOOLTIP");
	MoveET_moveInput:SetFrameLevel(100);
	MoveET_moveInput:EnableMouse(true);
	MoveET_moveInput:RegisterForDrag("LeftButton");
	-- No StartMoving/StopMovingOrSizing anywhere: the built-in mover would
	-- fight the box's db-driven anchors (each apply pulls the box, each box
	-- read would feed back into the db). Instead the box is ONLY ever
	-- db-driven and the db is ONLY ever cursor-driven, so there is a single
	-- control loop with nothing to fight.
	MoveET_moveInput:SetScript("OnDragStart", function(self)
		MoveET_BeginDrag(self);
	end);
	MoveET_moveInput:SetScript("OnDragStop", function(self)
		MoveET_EndDrag(self);
	end);
	MoveET_moveInput:Hide();
end

-- Shared drag endpoints driving the cursor loop.
MoveET_BeginDrag = function(self)
	if not db or not MoveET_moveModeOn then
		return;
	end
	if MoveET_IsInteractionLocked() then
		return; -- silently refuse: blocked input just does nothing
	end
	-- capture where the cursor grabbed relative to the anchor point: db
	-- already IS the TOP anchor's offset in UI units, so the grab is exact
	-- and the spot cannot jump by a single pixel, whatever the scale
	local pw, ph = UIParent:GetSize();
	local cx, cy = GetCursorPosition(); -- already in UI units on this client
	MoveET_grabDX = cx - (pw / 2 + db.x);
	MoveET_grabDY = cy - (ph + db.y);
	MoveET_moveDragging = true;
	if MoveET_moveInput then
		MoveET_moveInput:SetScript("OnUpdate", function() MoveET_DragUpdate(); end);
	end
end;

MoveET_EndDrag = function(self)
	if MoveET_moveDragging and not MoveET_IsInteractionLocked() then
		MoveET_DragUpdate(); -- exact final position (drag still active)
	end
	MoveET_moveDragging = false;
	MoveET_DetachDrag();
end;

-- Re-anchor the box and the input over the saved spot. Gated throughout
-- (SetPoint): callers ensure a clear context, and the guard below keeps it
-- safe by construction anyway.
MoveET_SyncMoveBox = function()
	if not MoveET_moveBox or not db then
		return;
	end
	if MoveET_IsInteractionLocked() then
		return;
	end
	MoveET_moveBox:ClearAllPoints();
	MoveET_moveBox:SetPoint("TOP", UIParent, "TOP", db.x, db.y);
	MoveET_moveBox:SetSize(BOX_W, BOX_H);
	MoveET_moveInput:ClearAllPoints();
	MoveET_moveInput:SetPoint("TOP", UIParent, "TOP", db.x, db.y);
	MoveET_moveInput:SetSize(BOX_W, BOX_H);
end;

MoveET_DragUpdate = function()
	if not MoveET_moveDragging then
		return; -- idle frame: return before the lock query (nil per-frame cost)
	end
	if not db then
		MoveET_moveDragging = false;
		return;
	end
	if MoveET_IsInteractionLocked() then
		-- protection landed mid-drag: end the gesture without persisting
		-- anything further (db keeps the pre-lock spot for the part after).
		MoveET_moveDragging = false;
		MoveET_DetachDrag();
		return;
	end
	local pw, ph = UIParent:GetSize();
	local cx, cy = GetCursorPosition(); -- already in UI units on this client
	db.x = MoveET_Round2(cx - MoveET_grabDX - pw / 2);
	db.y = MoveET_Round2(cy - MoveET_grabDY - ph);
	MoveET_ApplyPosition();
	MoveET_SyncMoveBox();
	if refreshWindow then
		refreshWindow(); -- the boxes update live while dragging
	end
end;

MoveET_SetMoveMode = function(on)
	if on then
		if MoveET_IsInteractionLocked() then
			return; -- move mode needs gated installs/anchors: leave it off while locked
		end
		MoveET_BuildMoveUI();
		if not MoveET_moveBox then
			return;
		end
		MoveET_SyncMoveBox();
		MoveET_moveBox:Show();
		MoveET_moveInput:Show();
		MoveET_moveModeOn = true;
	else
		-- exiting is always safe: Hide is ungated and the detach/label below
		-- guard themselves, so move mode can be left even while locked
		MoveET_moveModeOn = false;
		MoveET_moveDragging = false;
		MoveET_DetachDrag();
		if MoveET_moveBox then
			MoveET_moveBox:Hide();
		end
		if MoveET_moveInput then
			MoveET_moveInput:Hide();
		end
	end
	if options and options.moveBtn and not MoveET_IsInteractionLocked() then
		-- Button:SetText is gated: refresh the label only when clear (the
		-- lift flush re-syncs it through refreshWindow)
		options.moveBtn:SetText(MoveET_moveModeOn and "stop moving" or "move toast");
	end
end;

-- ----------------------------------------------------------------------------
-- config window, built on gated init inside a pcall: even if a widget template
-- is missing in some client build, the toast positioning keeps working
-- ----------------------------------------------------------------------------
local function MoveET_MakeLabel(parent, text, fontObject, point, relativeTo, relPoint, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY");
	fs:SetFontObject(fontObject);
	fs:SetText(text);
	fs:SetPoint(point, relativeTo, relPoint, x, y);
	return fs;
end

local function MoveET_MakeEditBox(parent, width, maxLetters, point, relativeTo, relPoint, x, y, onEnter)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate");
	box:SetSize(width, 28);
	box:SetPoint(point, relativeTo, relPoint, x, y);
	-- the compact font is load-bearing for the coordinate boxes: the Large
	-- font makes "-100.00" wider than the box's visible text area and the
	-- EditBox's scroll/caret handling then clips and misplaces the digits
	box:SetFontObject("GameFontHighlight");
	if box.SetTextInsets then
		-- the search-border left cap protrudes 5px outside the frame
		box:SetTextInsets(12, 8, 6, 6); -- equal vertical insets center the text
	end
	box:SetAutoFocus(false);
	box:SetMaxLetters(maxLetters);
	box:SetJustifyH("CENTER");
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus();
	end);
	box:SetScript("OnEnterPressed", function(self)
		self:ClearFocus();
		if db then
			onEnter(self:GetText());
		end
	end);
	return box;
end

local function MoveET_BuildWindow()
	options = CreateFrame("Frame", "Move_Event_ToastOptions", UIParent, "BackdropTemplate");
	options:SetFrameStrata("HIGH");
	options:SetSize(260, 132);
	options:SetMovable(true);
	options:EnableMouse(true);
	options:RegisterForDrag("LeftButton");
	options:SetClampedToScreen(true);
	options:SetScript("OnDragStart", function(self)
		if MoveET_IsInteractionLocked() then
			return; -- StartMoving is gated: the window stays put while protected
		end
		self:StartMoving();
	end);
	options:SetScript("OnDragStop", function(self)
		if MoveET_IsInteractionLocked() then
			return; -- StopMovingOrSizing + re-anchor are gated; position unsaved
		end
		self:StopMovingOrSizing();
		if db then
			local pw, ph = UIParent:GetSize();
			local cx, cy = self:GetCenter();
			db.win = { x = MoveET_Round2(cx - pw / 2), y = MoveET_Round2(cy - ph / 2) };
			self:ClearAllPoints();
			self:SetPoint("CENTER", UIParent, "CENTER", db.win.x, db.win.y);
		end
	end);
	options:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	});
	options:SetBackdropColor(0, 0, 0, 0.85);
	options:Hide();

	-- clicking anywhere outside an edit box (on the window or on the world)
	-- gives keyboard focus back so the game chat works again
	options:SetScript("OnMouseDown", function()
		if options.xBox then
			options.xBox:ClearFocus();
		end
		if options.yBox then
			options.yBox:ClearFocus();
		end
	end);
	if WorldFrame then
		WorldFrame:HookScript("OnMouseUp", function()
			if options and options:IsShown() then
				if options.xBox then
					options.xBox:ClearFocus();
				end
				if options.yBox then
					options.yBox:ClearFocus();
				end
			end
		end);
	end

	-- close
	local close = CreateFrame("Button", nil, options, "UIPanelCloseButton");
	close:SetPoint("TOPRIGHT", options, "TOPRIGHT", -4, -4);
	close:SetScript("OnClick", function()
		options:Hide();
	end);

	-- move mode: only while it is on is the toast spot drag-movable; the box
	-- doubles as the position preview (the manager hides with no toast to
	-- show). It sits centered at the top of the window
	options.moveBtn = CreateFrame("Button", nil, options, "UIPanelButtonTemplate");
	options.moveBtn:SetSize(140, 22); -- wide enough for the Large-font label
	if options.moveBtn.SetNormalFontObject then
		options.moveBtn:SetNormalFontObject("GameFontNormalLarge");
		options.moveBtn:SetHighlightFontObject("GameFontHighlightLarge");
		options.moveBtn:SetDisabledFontObject("GameFontNormalLarge");
	end
	options.moveBtn:SetText("move toast");
	options.moveBtn:SetPoint("TOP", options, "TOP", 0, -6);
	options.moveBtn:SetScript("OnClick", function()
		if MoveET_moveModeOn then
			MoveET_SetMoveMode(false); -- exiting is always safe, even while locked
		else
			MoveET_SetMoveMode(true); -- entering refuses silently while locked
		end
	end);

	-- position: x/y coordinates with two decimal places, side by side; the
	-- labels are edge-anchored to their boxes so they sit on the same row
	options.xBox = MoveET_MakeEditBox(options, 80, 9, "TOPLEFT", options, "TOPLEFT", 44, -34, function(v)
		v = tonumber(v);
		if v and v >= -MAX_COORD and v <= MAX_COORD then
			db.x = MoveET_Round2(v);
			MoveET_ApplyPosition(); -- queues itself while locked (db already correct)
			if refreshWindow then
				refreshWindow();
			end
		end
	end);
	options.xLabel = MoveET_MakeLabel(options, "X", "GameFontNormalLarge", "RIGHT", options.xBox, "LEFT", -12, 0);
	options.yBox = MoveET_MakeEditBox(options, 80, 9, "TOPLEFT", options, "TOPLEFT", 160, -34, function(v)
		v = tonumber(v);
		if v and v >= -MAX_COORD and v <= MAX_COORD then
			db.y = MoveET_Round2(v);
			MoveET_ApplyPosition(); -- queues itself while locked (db already correct)
			if refreshWindow then
				refreshWindow();
			end
		end
	end);
	options.yLabel = MoveET_MakeLabel(options, "Y", "GameFontNormalLarge", "RIGHT", options.yBox, "LEFT", -12, 0);

	-- clickthrough: nothing here intercepts mouse clicks
	options.clickBox = CreateFrame("CheckButton", "Move_Event_ToastClickthrough", options, "UICheckButtonTemplate");
	options.clickBox:SetSize(22, 22);
	options.clickBox:SetPoint("TOPLEFT", options, "TOPLEFT", 44, -70);
	MoveET_MakeLabel(options, "clickthrough", "GameFontNormalLarge", "LEFT", options.clickBox, "RIGHT", 8, 0);
	options.clickBox:SetScript("OnClick", function(self)
		if not db then
			return;
		end
		db.clickthrough = self:GetChecked() and true or false;
		MoveET_ApplyClickable(); -- queues itself while locked (db already correct)
	end);

	-- disable: no toasts at all while set
	options.disableBox = CreateFrame("CheckButton", "Move_Event_ToastDisable", options, "UICheckButtonTemplate");
	options.disableBox:SetSize(22, 22);
	options.disableBox:SetPoint("TOPLEFT", options, "TOPLEFT", 44, -98);
	MoveET_MakeLabel(options, "disable toasts", "GameFontNormalLarge", "LEFT", options.disableBox, "RIGHT", 8, 0);
	options.disableBox:SetScript("OnClick", function(self)
		if not db then
			return;
		end
		db.disable = self:GetChecked() and true or false;
		MoveET_ApplyDisable(); -- queues itself while locked (db already correct)
	end);

	function refreshWindow()
		if not db or not options.xBox then
			return;
		end
		if MoveET_IsInteractionLocked() then
			return; -- EditBox/Button/CheckButton writes are gated: refresh on lift
		end
		if tonumber(options.xBox:GetText()) ~= db.x then
			options.xBox:SetText(tostring(db.x));
		end
		if tonumber(options.yBox:GetText()) ~= db.y then
			options.yBox:SetText(tostring(db.y));
		end
		options.clickBox:SetChecked(db.clickthrough);
		options.disableBox:SetChecked(db.disable);
		if options.moveBtn then
			options.moveBtn:SetText(MoveET_moveModeOn and "stop moving" or "move toast");
		end
		if MoveET_moveModeOn then
			MoveET_SyncMoveBox(); -- the box follows typed/reset changes too
		end
	end

	options:SetScript("OnShow", function()
		if refreshWindow then
			refreshWindow();
		end
	end);
	options:SetScript("OnHide", function()
		if MoveET_moveModeOn then
			MoveET_SetMoveMode(false); -- leaving the window also leaves move mode
		end
	end);
end

-- ----------------------------------------------------------------------------
-- Load (pure Lua, safe anytime) vs gated init (deferred while protected)
-- ----------------------------------------------------------------------------

-- Backfill the db from SavedVariables. Pure Lua table work only: safe under
-- any restriction, so a /reload-in-combat still lands its state and only the
-- gated apply waits for the lift. Returns false on a missing manager (inert
-- before touching SavedVariables). Idempotent.
local function MoveET_LoadState()
	if MoveET_stateLoaded then
		return true;
	end
	if not manager then
		return false;
	end

	local freshDB = _G[ADDON_NAME] == nil;
	db = _G[ADDON_NAME];
	if not db then
		db = {}; -- start from the game's own placement
		_G[ADDON_NAME] = db; -- first session: publish it so it gets saved
	end
	MoveET_Sanitize(db);
	if freshDB then
		if MoveET_IsInteractionLocked() then
			MoveET_pendingGreet = true; -- chat is best-effort: greet on lift
		else
			MoveET_instructions();
		end
	end
	MoveET_stateLoaded = true;
	return true;
end

-- Flush work queued while locked. Runs only when clear.
MoveET_FlushPending = function()
	if not MoveET_stateLoaded or MoveET_IsInteractionLocked() then
		return;
	end
	if MoveET_pendingGreet then
		MoveET_pendingGreet = false;
		MoveET_instructions();
	end
	if MoveET_pendingPosition then
		MoveET_pendingPosition = false;
		MoveET_ApplyPosition();
	end
	if MoveET_pendingClickable then
		MoveET_pendingClickable = false;
		MoveET_ApplyDisable(); -- re-runs alpha/hide plus the mouse state
	end
	if MoveET_pendingWin then
		MoveET_pendingWin = false;
		if options then
			options:ClearAllPoints();
			options:SetPoint("CENTER", UIParent, "CENTER", db.win.x, db.win.y);
		end
	end
	if MoveET_moveModeOn then
		MoveET_SyncMoveBox(); -- a locked rebuild may have moved the spot
	end
	if refreshWindow then
		refreshWindow();
	end
end;

-- Install the display post-hook. HookScript is gated, so this runs only
-- while clear, inside gated init. The hook runs after Blizzard's own
-- display work: DisplayToast always ends in Show-or-Hide through Blizzard's
-- own untainted execution (which keeps working while locked), then ours
-- re-applies the saved position and the per-toast mouse state -- or queues
-- them while locked.
local function MoveET_InstallHooks()
	if MoveET_hooksInstalled then
		return;
	end
	manager:HookScript("OnShow", MoveET_OnManagerShow);
	MoveET_hooksInstalled = true;
end

-- Idempotent gated setup: captures the stock layout, (re)registers events,
-- builds the options window, installs the post-hook, locks the anchors and
-- runs the deferred login apply. Safe to call from any event or slash entry;
-- defers (and remembers) while protected so a /reload-in-combat never
-- half-installs silently.
MoveET_EnsureGatedInit = function()
	if MoveET_IsInteractionLocked() then
		MoveET_gatedInitDeferred = true;
		return false;
	end
	MoveET_gatedInitDeferred = false;
	MoveET_RegisterAddonEvents();
	MoveET_CaptureStock();
	MoveET_InstallHooks();
	if not options then
		pcall(function()
			MoveET_BuildWindow();
		end);
	end
	if MoveET_stateLoaded and not MoveET_initDone then
		MoveET_ApplyPosition(); -- positions over the login anchor
		MoveET_ApplyDisable(); -- saved clickthrough/disable from the start
		MoveET_SetLocked(true); -- Blizzard re-anchors stop here from now on
		if options then
			options:ClearAllPoints();
			options:SetPoint("CENTER", UIParent, "CENTER", db.win.x, db.win.y);
			if refreshWindow then
				refreshWindow();
			end
		end
		MoveET_initDone = true;
	end
	MoveET_FlushPending();
	return true;
end;

-- ----------------------------------------------------------------------------
-- login and persist through sessions functionality
-- ----------------------------------------------------------------------------
local function MoveET_OnEvent(self, event, arg1, arg2)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			-- UnregisterEvent is itself gated: skip while locked (the
			-- handler is idempotent, a lingering registration is harmless).
			if not MoveET_IsInteractionLocked() then
				self:UnregisterEvent("ADDON_LOADED");
			end
			if MoveET_LoadState() then
				MoveET_EnsureGatedInit();
			end
		end
	elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
		-- Payload is (restrictionType, newState). IsAddOnRestrictionActive
		-- reads FALSE during this dispatch by design, so never query here --
		-- maintain per-type marks from the payload and confirm outside.
		if arg2 == MoveET_RestrictionStateID("inactive") then
			if arg1 ~= nil then MoveET_restrictedTypes[arg1] = nil; end
			if next(MoveET_restrictedTypes) == nil then
				if C_Timer and C_Timer.After then
					C_Timer.After(0, MoveET_ConfirmRestrictionsCleared);
				end
			end
		else
			-- Activating (fired before enforcement starts), Active, or unknown.
			if arg1 ~= nil then MoveET_restrictedTypes[arg1] = true; end
			MoveET_ApplyRestrictionsActive();
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- Entering combat: mark locked only if the query agrees. The lock
		-- transition is silent by design.
		MoveET_RefreshRestrictionState();
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- Backstop wake-up: covers a restriction-changed registration missed
		-- during a /reload-in-combat.
		MoveET_RefreshRestrictionState();
	elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" then
		-- Zone crossings (M+/rated maps restrict on entry, out of combat):
		-- re-check protected status, re-assert the saved spot on lift.
		MoveET_RefreshRestrictionState();
		MoveET_ApplyPosition();
		MoveET_ApplyDisable();
		if MoveET_moveModeOn then
			MoveET_SyncMoveBox(); -- zoning rebuilds the UI: box follows
		end
	end
end

-- All event installs funnel through here so a deferred boot can retry them
-- idempotently once protection lifts. Re-registering is a no-op and the
-- script is simply replaced.
local function MoveET_RegisterAddonEventsInner()
	if not MoveET_EventFrame then return end
	MoveET_EventFrame:RegisterEvent("ADDON_LOADED");
	MoveET_EventFrame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED");
	MoveET_EventFrame:RegisterEvent("PLAYER_REGEN_DISABLED");
	MoveET_EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED");
	MoveET_EventFrame:RegisterEvent("PLAYER_ENTERING_WORLD");
	MoveET_EventFrame:RegisterEvent("ZONE_CHANGED");
	MoveET_EventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA");
	MoveET_EventFrame:SetScript("OnEvent", MoveET_OnEvent);
end
MoveET_RegisterAddonEvents = MoveET_RegisterAddonEventsInner;

MoveET_EventFrame = CreateFrame("Frame", "Move_Event_ToastEventFrame");

-- Boot-time restriction evaluation: a /reload landing mid-protection
-- silently defers all gated setup instead of half-installing. Recovery order
-- on lift: restriction-changed confirm, regen-enabled, zone re-check, next
-- slash use (lazy self-heal in the slash handler below).
MoveET_EnsureGatedInit();

-- ----------------------------------------------------------------------------
-- slash command functionality: bare /moveet (or anything unrecognized)
-- toggles the config window, /moveet reset restores the game's defaults
-- ----------------------------------------------------------------------------
SLASH_MOVEET1 = "/moveet";
SlashCmdList.MOVEET = function(msg)
	if not MoveET_stateLoaded then
		if not MoveET_LoadState() then
			return; -- unknown layout: inert, SavedVariables untouched
		end
	end
	-- self-heal: a missed ADDON_LOADED (deaf boot under protection) resumes
	-- here once clear; no-op while locked.
	MoveET_EnsureGatedInit();
	if not db then
		return; -- settings are not loaded yet
	end
	msg = string.lower(string.match(msg or "", "^%s*(.-)%s*$") or "");
	if msg == "reset" then
		MoveET_Reset();
	elseif options and options:IsShown() then
		options:Hide();
	elseif options then
		options:Show();
	end
end
