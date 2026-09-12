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
-- Midnight (12.x) gate discipline, retail flavor only: there is none. Tainted
-- calls on secret-clean objects serve under any restriction state
-- (live-verified 2026-09-12 on the sibling movers, all six types forced:
-- drags, settings, strata writes, installs, all clean), and nothing this
-- addon touches can become secret-marked (it ingests no unit/combat/aura
-- data -- toast chrome only; Blizzard doesn't mark chrome). So every op
-- below just attempts -- no flag checks, no mark checks, no pcall, no
-- read-back verification, no queues. If the engine ever refuses, it errors
-- LOUDLY (Bugsack, not silence), which is exactly what we want: a silent
-- queue would hide the bug forever, an error gets reported and fixed. The
-- only guards left are crash-safety (nil results abort geometry) and
-- correctness (the already-there early-out keeps default settings from
-- touching Blizzard's anchors at all, once-semantics for capture/hooks).
-- Chat tutorial prints best-effort always (a swallowed line under Chat
-- lockdown is harmless -- it is never load-bearing).

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
-- the stock layout is captured once at init and as the reset target
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

-- Install state. Declared HERE, above every function that reads or writes
-- them: Lua upvalues bind at closure creation, so a later `local` would
-- leave earlier paths writing to a same-named global instead.
local MoveET_stateLoaded = false; -- db backfilled (pure Lua, always runs)
local MoveET_hooksInstalled = false; -- post-hook attempted once (HookScript chains)
local MoveET_captured = false; -- stock captured once (recapturing would adopt our moves)
local MoveET_anchored = false; -- the manager's own anchor methods are no-ops (placement lock)
local MoveET_moveModeOn = false; -- move mode: the green box + drag input are shown
local MoveET_moveDragging = false; -- a drag gesture is in flight (OnUpdate early-returns without it)
local MoveET_moveBox; -- green 50% box over the toast spot, marking its rect
local MoveET_moveInput; -- transparent drag input above the spot
local MoveET_grabDX, MoveET_grabDY; -- cursor offset from the anchor point at grab time
-- Forward declarations: assigned further below, called from early paths and
-- mid-file appliers (bound here so they resolve correctly).
local MoveET_EnsureInit;
local MoveET_RegisterAddonEvents;
local MoveET_DetachDrag;
local MoveET_DragUpdate;
local MoveET_SetMoveMode;
local MoveET_BeginDrag;
local MoveET_EndDrag;
local MoveET_SyncMoveBox;
local MoveET_EventFrame; -- listener frame, created at file load below

-- stock layout, captured once at init (recapturing later would adopt our
-- own moves as the game's)
local stockX, stockY = STOCK_X, STOCK_Y; -- the game's own toast placement
-- the manager's own anchor methods, kept privately once captured: every
-- apply below goes through these, so the no-op lock never blocks us
local origClear, origSetPoint;

-- Capture the stock layout: the game's own placement plus the anchor
-- methods the lock later swaps out. Runs once (stock must predate our own
-- moves -- recapturing later would adopt our offset as the game's).
local function MoveET_CaptureStock()
	if MoveET_captured then
		return;
	end
	origClear, origSetPoint = manager.ClearAllPoints, manager.SetPoint;
	local _, _, _, x, y = manager:GetPoint(1);
	if x ~= nil and y ~= nil then
		stockX, stockY = MoveET_Round2(x), MoveET_Round2(y);
	end
	MoveET_captured = true;
end

-- ----------------------------------------------------------------------------
-- core behavior: every op below just attempts. A call from any path --
-- hooks, slash, options, events -- runs the same straight-line code; there
-- is no lock state, no queue, nothing to flush
-- ----------------------------------------------------------------------------

-- While positioned, the manager's own anchor methods are no-ops so neither
-- Blizzard's UpdateAnchor (every DisplayToast resets to TOP 0 -190) nor any
-- other toast mover can displace it behind our back; our own applies go
-- through the privately kept originals. This is a placement lock, not a
-- restriction gate: the swap itself is plain Lua field writes.
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

-- Re-apply the saved position over the manager's current anchor. A nil read
-- means the engine refused to answer: abort without touching anything (the
-- next organic trigger retries). An already-there anchor is left completely
-- alone, so default settings never touch Blizzard's anchors at all.
local function MoveET_ApplyPosition()
	if not db or not MoveET_captured then
		return;
	end
	local _, _, _, x, y = manager:GetPoint(1);
	if x == nil or y == nil then
		return;
	end
	if x == db.x and y == db.y then
		-- already exactly there: leave Blizzard's anchor completely alone
		return;
	end
	origClear(manager);
	origSetPoint(manager, "TOP", UIParent, "TOP", db.x, db.y);
end

-- Apply the mouse state to the manager and whichever toast is currently
-- pooled: clickthrough (or disable) means nothing here intercepts clicks.
local function MoveET_ApplyClickable()
	if not db or not MoveET_captured then
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

-- Apply the disable switch: a disabled manager is faded out and hidden, and
-- a toast arriving while disabled is re-hidden by the OnShow post-hook
-- below. SetAlpha is the designated secret-display sink and always lands.
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
	MoveET_ApplyClickable();
end

-- Fired after Blizzard's own display work: every DisplayToast ends in
-- Show-or-Hide through Blizzard's own execution, then ours re-applies the
-- saved position and the per-toast mouse state.
local function MoveET_OnManagerShow()
	MoveET_ApplyPosition();
	if db and db.disable then
		manager:Hide();
	end
	MoveET_ApplyClickable();
end

-- restore every setting to the game's own behavior (db work is pure Lua and
-- always lands). Every saved value goes back, including the config window's
-- own position -- as if the addon was never enabled.
local function MoveET_Reset()
	if not db then
		return;
	end
	db.x, db.y = stockX, stockY;
	db.clickthrough, db.disable = false, false;
	db.win = { x = 0, y = 0 };
	MoveET_ApplyPosition(); -- restores the game's own placement
	MoveET_ApplyDisable(); -- alpha back to 1, mouse back on
	-- note: reset touches values only -- the window stays open and move mode
	-- stays on (the box follows the reset spot through refreshWindow below)
	if options then
		options:ClearAllPoints();
		options:SetPoint("CENTER", UIParent, "CENTER", 0, 0);
	end
	if refreshWindow then
		refreshWindow(); -- the window (and the move box) follows the reset
	end
	if options and options.xBox then
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

-- Best-effort OnUpdate detach on our own input frame: always safe.
MoveET_DetachDrag = function()
	if MoveET_moveInput then
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
	-- capture where the cursor grabbed relative to the anchor point: db
	-- already IS the TOP anchor's offset in UI units, so the grab is exact
	-- and the spot cannot jump by a single pixel, whatever the scale
	local pw, ph = UIParent:GetSize();
	if pw == nil or ph == nil then
		return;
	end
	local cx, cy = GetCursorPosition(); -- already in UI units on this client
	if cx == nil or cy == nil then
		return; -- cursor unreadable: refuse the grab without touching anything
	end
	MoveET_grabDX = cx - (pw / 2 + db.x);
	MoveET_grabDY = cy - (ph + db.y);
	MoveET_moveDragging = true;
	if MoveET_moveInput then
		MoveET_moveInput:SetScript("OnUpdate", function() MoveET_DragUpdate(); end);
	end
end;

MoveET_EndDrag = function(self)
	if MoveET_moveDragging then
		MoveET_DragUpdate(); -- exact final position (drag still active)
	end
	MoveET_moveDragging = false;
	MoveET_DetachDrag();
end;

-- Re-anchor the box and the input over the saved spot. Both are our own
-- frames, so this always serves.
MoveET_SyncMoveBox = function()
	if not MoveET_moveBox or not db then
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
		return; -- idle frame: cheapest possible return, no queries at all
	end
	if not db then
		MoveET_moveDragging = false;
		return;
	end
	local pw, ph = UIParent:GetSize();
	local cx, cy = GetCursorPosition(); -- already in UI units on this client
	if pw == nil or ph == nil or cx == nil or cy == nil then
		-- cursor unreadable mid-drag: end the gesture without persisting
		-- anything further (db keeps the last good spot)
		MoveET_moveDragging = false;
		MoveET_DetachDrag();
		return;
	end
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
		MoveET_BuildMoveUI();
		if not MoveET_moveBox then
			return;
		end
		MoveET_SyncMoveBox();
		MoveET_moveBox:Show();
		MoveET_moveInput:Show();
		MoveET_moveModeOn = true;
	else
		-- exiting is always safe
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
	if options and options.moveBtn then
		options.moveBtn:SetText(MoveET_moveModeOn and "stop moving" or "move toast");
	end
end;

-- ----------------------------------------------------------------------------
-- config window, built on init inside a pcall: even if a widget template
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
		self:StartMoving(); -- own frame: always servable
	end);
	options:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing();
		if db then
			local pw, ph = UIParent:GetSize();
			local cx, cy = self:GetCenter();
			if pw == nil or ph == nil or cx == nil or cy == nil then
				return;
			end
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
			MoveET_SetMoveMode(false);
		else
			MoveET_SetMoveMode(true);
		end
	end);

	-- position: x/y coordinates with two decimal places, side by side; the
	-- labels are edge-anchored to their boxes so they sit on the same row
	options.xBox = MoveET_MakeEditBox(options, 80, 9, "TOPLEFT", options, "TOPLEFT", 44, -34, function(v)
		v = tonumber(v);
		if v and v >= -MAX_COORD and v <= MAX_COORD then
			db.x = MoveET_Round2(v);
			MoveET_ApplyPosition(); -- db already correct, frame follows
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
			MoveET_ApplyPosition(); -- db already correct, frame follows
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
		MoveET_ApplyClickable(); -- db already correct, frame follows
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
		MoveET_ApplyDisable(); -- db already correct, frame follows
	end);

	function refreshWindow()
		if not db or not options.xBox then
			return;
		end
		-- own frames throughout: every write below serves.
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
-- Load (pure Lua, always) + init (attempt everything at file scope, on load,
-- and on slash)
-- ----------------------------------------------------------------------------

-- Backfill the db from SavedVariables. Pure Lua table work only. Returns
-- false on a missing manager (inert before touching SavedVariables).
-- Idempotent. The first-run tutorial prints best-effort, chat lockdown or
-- not -- it is never load-bearing.
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
		MoveET_instructions();
	end
	MoveET_stateLoaded = true;
	return true;
end

-- Install the display post-hook. Attempted unconditionally; the hook runs
-- after Blizzard's own display work: DisplayToast always ends in
-- Show-or-Hide through Blizzard's own execution, then ours re-applies the
-- saved position and the per-toast mouse state.
local function MoveET_InstallHooks()
	if MoveET_hooksInstalled then
		return;
	end
	manager:HookScript("OnShow", MoveET_OnManagerShow);
	-- installs are attempted once (HookScript chains, so repeats would stack
	-- duplicate wrappers): if the engine ever refuses, it errors loudly and
	-- we hear about it.
	MoveET_hooksInstalled = true;
end

-- Setup, run at file scope (pre-SV: registers, captures, hooks, builds)
-- and again on ADDON_LOADED and slash (cheap idempotent re-entry:
-- registration no-ops, capture/hooks run once, applies re-assert).
-- The first apply waits for state (db guard below).
MoveET_EnsureInit = function()
	MoveET_RegisterAddonEvents();
	MoveET_CaptureStock();
	MoveET_InstallHooks();
	if not options then
		pcall(function()
			MoveET_BuildWindow();
		end);
	end
	if MoveET_stateLoaded then
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
	end
end;

-- ----------------------------------------------------------------------------
-- login and persist through sessions functionality
-- ----------------------------------------------------------------------------
local function MoveET_OnEvent(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 == ADDON_NAME then
			if MoveET_LoadState() then
				MoveET_EnsureInit();
			end
			-- unregister LAST: EnsureInit re-registers everything above,
			-- so unsubscribing first would resurrect in the same tick.
			-- The handler is idempotent anyway, so a lingering
			-- registration would be harmless regardless.
			self:UnregisterEvent("ADDON_LOADED");
		end
	end
end

-- All event installs funnel through here. Re-registering is a no-op and the
-- script is simply replaced, so repeated EnsureInit calls stay cheap.
local function MoveET_RegisterAddonEventsInner()
	if not MoveET_EventFrame then return end
	MoveET_EventFrame:RegisterEvent("ADDON_LOADED");
	MoveET_EventFrame:SetScript("OnEvent", MoveET_OnEvent);
end
MoveET_RegisterAddonEvents = MoveET_RegisterAddonEventsInner;

MoveET_EventFrame = CreateFrame("Frame", "Move_Event_ToastEventFrame");

-- File scope runs before SavedVariables land: register (so our own
-- ADDON_LOADED is heard), capture stock, install hooks, build the window.
-- The first apply waits for state in the ADDON_LOADED handler below.
MoveET_EnsureInit();

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
	-- re-entry is cheap and idempotent: a missed ADDON_LOADED (refused
	-- registration) resumes here.
	MoveET_EnsureInit();
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
