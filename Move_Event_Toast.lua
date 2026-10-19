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
-- toast mover can displace it -- the MFC anchor-lock pattern. Post-hooks on
-- the manager's OnShow (the first toast of a chain: the manager was hidden)
-- and on its fastHide/hideAnim OnFinished (every chained toast: those run
-- ToastingEnded -> DisplayToast while the manager stays shown, so OnShow
-- never fires again) re-apply the saved position and the clickthrough state
-- onto each newly pooled toast. There is zero hooksecurefunc anywhere:
-- hooking Blizzard's DisplayToast Lua method would taint Blizzard's own
-- toast path and degrade restricted calls made from it while protected.
-- Everything is event driven: no polling and no per-frame code. /moveet
-- opens the config window (with a move mode that makes the toast spot
-- drag-movable), /moveet reset restores the defaults.
--
-- Midnight (12.x) gate discipline, retail flavor only: there is none. Tainted
-- calls on secret-clean objects serve under any restriction state
-- (live-verified 2026-09-12 on the sibling movers, all six types forced),
-- and nothing this addon touches can become secret-marked (it ingests no
-- unit/combat/aura data -- toast chrome only). So every op below just
-- attempts -- no flag checks, no pcall, no queues. If the engine ever
-- refuses, it errors LOUDLY (Bugsack, not silence), which is exactly what we
-- want. The only guards left are crash-safety (nil results abort geometry)
-- and correctness (the already-there early-out keeps default settings from
-- touching Blizzard's anchors at all, once-semantics for capture/hooks).

local ADDON_NAME = "Move_Event_Toast";

-- Blizzard's EventToastManagerFrame loads from FrameXML before user addons,
-- so it exists at file scope; on an unknown layout stay inert. Nothing is
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

-- Rounds to 2 decimals (declared above every storer: the client's float32
-- layout math hands GetPoint values like -140.00001525879 back -- stored
-- raw, that 16-char string overflows a 9-char coordinate box).
local function MoveET_Round2(v)
	return math.floor(v * 100 + 0.5) / 100;
end

-- Shared state. Declared HERE, above every function that reads or writes
-- it: Lua upvalues bind at closure creation, so a later `local` would leave
-- earlier paths writing to a same-named global instead.
local db; -- alias for the Move_Event_Toast SavedVariables table, set on ADDON_LOADED
local options, refreshWindow; -- config window and its refresher, built below
local MoveET_stateLoaded = false; -- db backfilled (pure Lua, always runs)
local MoveET_hooksInstalled = false; -- post-hooks installed once (HookScript chains)
local MoveET_captured = false; -- stock captured once (recapturing would adopt our moves)
local MoveET_anchored = false; -- the manager's own anchor methods are no-ops (placement lock)
local MoveET_moveModeOn = false; -- move mode: the green box + drag input are shown
local MoveET_moveDragging = false; -- a drag gesture is in flight
local MoveET_moveBox; -- green 50% box over the toast spot, marking its rect
local MoveET_moveInput; -- transparent drag input above the spot
local MoveET_grabDX, MoveET_grabDY; -- cursor offset from the anchor point at grab time
-- each frame's own mouse state, read before our first write: re-enabling
-- restores it (stock toast bodies are NOT mouse-enabled -- their clicks
-- fall through to the manager, whose OnMouseDown is the right-click dismiss)
local MoveET_stockMouse = setmetatable({}, { __mode = "k" });
-- stock layout, captured once at init: the game's own toast placement and
-- the manager's own anchor methods (every apply goes through these, so the
-- no-op lock never blocks us)
local stockX, stockY = STOCK_X, STOCK_Y;
local origClear, origSetPoint;

-- ----------------------------------------------------------------------------
-- core behavior: every op below just attempts. A call from any path --
-- hooks, slash, options, events -- runs the same straight-line code
-- ----------------------------------------------------------------------------

-- Runs once: stock must predate our own moves.
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

-- While positioned, the manager's own anchor methods are no-ops so neither
-- Blizzard's UpdateAnchor nor any other toast mover can displace it behind
-- our back. A placement lock, not a restriction gate: plain field writes.
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
-- next organic trigger retries). An anchor that is already exactly ours (a
-- single TOP point on UIParent at the saved offset) is left completely
-- alone, so default settings never touch Blizzard's anchors at all; a
-- second point (UpdateAnchor's per-texture-kit LEFT offset) always heals.
local function MoveET_ApplyPosition()
	if not db or not MoveET_captured then
		return;
	end
	local point, relativeTo, relativePoint, x, y = manager:GetPoint(1);
	if x == nil or y == nil then
		return;
	end
	if point == "TOP" and relativePoint == "TOP" and relativeTo == UIParent
		and manager:GetNumPoints() == 1
		and MoveET_Round2(x) == db.x and MoveET_Round2(y) == db.y then
		return;
	end
	origClear(manager);
	origSetPoint(manager, "TOP", UIParent, "TOP", db.x, db.y);
end

-- Mouse off, or back to the frame's own stock state (never forced on).
local function MoveET_SetMouse(frame, enabled)
	if not (frame and frame.EnableMouse) then
		return;
	end
	local stock = MoveET_stockMouse[frame];
	if stock == nil then
		stock = true;
		if frame.IsMouseEnabled then
			stock = frame:IsMouseEnabled() and true or false;
		end
		MoveET_stockMouse[frame] = stock;
	end
	frame:EnableMouse(enabled and stock);
end

-- Apply the mouse state to the manager and whichever toast is currently
-- pooled: clickthrough (or disable) means nothing here intercepts clicks.
-- The manager's own Close button (sticky toasts only) is left alone, so a
-- toast that never times out can always be dismissed.
local function MoveET_ApplyClickable()
	if not db or not MoveET_captured then
		return;
	end
	local enabled = not (db.clickthrough or db.disable);
	MoveET_SetMouse(manager, enabled);
	local toast = manager.currentDisplayingToast;
	if toast then
		MoveET_SetMouse(toast, enabled);
		MoveET_SetMouse(toast.TitleTextMouseOverFrame, enabled);
		MoveET_SetMouse(toast.SubTitleMouseOverFrame, enabled);
	end
end

-- Apply the disable switch: a disabled manager is faded out and hidden (the
-- same mid-lifecycle Hide as Blizzard's own right-click dismiss), and a
-- toast arriving while disabled is re-hidden by the display post-hook.
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

-- Fired after Blizzard's own display work (OnShow for the first toast of a
-- chain, the fastHide/hideAnim OnFinished for every chained one).
local function MoveET_OnToastDisplayed()
	MoveET_ApplyPosition();
	if db and db.disable then
		manager:Hide();
	end
	MoveET_ApplyClickable();
end

-- v1 carryover: the old slash-command addon saved exactly
-- { x, y, clickthrough, disable } under this same name. All four keep
-- working verbatim while the win key backfills -- no re-greet. Corrupt or
-- float-noisy values heal here.
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
-- itself is hidden (no toast showing). The math is cursor-driven, never read
-- back from the box: the box follows the db, so reading it would feed our
-- own movement back into the next update and run away. No StartMoving
-- anywhere -- the built-in mover would fight the db-driven anchors. The
-- OnUpdate script only exists while a drag is active.

-- Cursor in UIParent units: GetCursorPosition is in scale-1 screen units
-- and the toast spot is a UIParent offset, so divide by UIParent's effective
-- scale (identical at UI scale 1). Nil when unreadable.
local function MoveET_CursorXY()
	local cx, cy = GetCursorPosition();
	local s = UIParent:GetEffectiveScale();
	if cx == nil or cy == nil or not s or s <= 0 then
		return nil;
	end
	return cx / s, cy / s;
end

-- Re-anchor the box and the input over the saved spot (own frames).
local function MoveET_SyncMoveBox()
	if not MoveET_moveBox or not db then
		return;
	end
	MoveET_moveBox:ClearAllPoints();
	MoveET_moveBox:SetPoint("TOP", UIParent, "TOP", db.x, db.y);
	MoveET_moveInput:ClearAllPoints();
	MoveET_moveInput:SetPoint("TOP", UIParent, "TOP", db.x, db.y);
end

local function MoveET_StopDrag()
	MoveET_moveDragging = false;
	if MoveET_moveInput then
		MoveET_moveInput:SetScript("OnUpdate", nil);
	end
end

local function MoveET_DragUpdate()
	if not (MoveET_moveDragging and db) then
		MoveET_StopDrag();
		return;
	end
	local pw, ph = UIParent:GetSize();
	local cx, cy = MoveET_CursorXY();
	if pw == nil or ph == nil or cx == nil or cy == nil then
		-- cursor unreadable mid-drag: end the gesture, db keeps the last good spot
		MoveET_StopDrag();
		return;
	end
	db.x = MoveET_Round2(cx - MoveET_grabDX - pw / 2);
	db.y = MoveET_Round2(cy - MoveET_grabDY - ph);
	MoveET_ApplyPosition();
	if refreshWindow then
		refreshWindow(); -- the boxes (and the move box) update live while dragging
	end
end

local function MoveET_BeginDrag()
	if not db or not MoveET_moveModeOn then
		return;
	end
	-- db already IS the TOP anchor's offset in UI units (ax = pw/2 + x,
	-- ay = ph + y), so the grab is exact and the spot cannot jump
	local pw, ph = UIParent:GetSize();
	local cx, cy = MoveET_CursorXY();
	if pw == nil or ph == nil or cx == nil or cy == nil then
		return; -- unreadable: refuse the grab without touching anything
	end
	MoveET_grabDX = cx - (pw / 2 + db.x);
	MoveET_grabDY = cy - (ph + db.y);
	MoveET_moveDragging = true;
	MoveET_moveInput:SetScript("OnUpdate", MoveET_DragUpdate);
end

local function MoveET_EndDrag()
	if MoveET_moveDragging then
		MoveET_DragUpdate(); -- exact final position
	end
	MoveET_StopDrag();
end

local function MoveET_BuildMoveUI()
	if MoveET_moveBox then
		return;
	end
	MoveET_moveBox = CreateFrame("Frame", "Move_Event_ToastMoveBox", UIParent);
	MoveET_moveBox:SetFrameStrata("BACKGROUND");
	MoveET_moveBox:SetFrameLevel(1);
	MoveET_moveBox:SetSize(BOX_W, BOX_H);
	MoveET_moveBox:EnableMouse(false);
	local tex = MoveET_moveBox:CreateTexture(nil, "BACKGROUND");
	tex:SetColorTexture(0, 1, 0, 0.5);
	tex:SetAllPoints();
	MoveET_moveBox:Hide();
	MoveET_moveInput = CreateFrame("Frame", "Move_Event_ToastMoveInput", UIParent);
	MoveET_moveInput:SetFrameStrata("TOOLTIP");
	MoveET_moveInput:SetFrameLevel(100);
	MoveET_moveInput:SetSize(BOX_W, BOX_H);
	MoveET_moveInput:EnableMouse(true);
	MoveET_moveInput:RegisterForDrag("LeftButton");
	MoveET_moveInput:SetScript("OnDragStart", MoveET_BeginDrag);
	MoveET_moveInput:SetScript("OnDragStop", MoveET_EndDrag);
	MoveET_moveInput:Hide();
end

local function MoveET_UpdateMoveButton()
	if options and options.moveBtn then
		options.moveBtn:SetText(MoveET_moveModeOn and "stop moving" or "move toast");
	end
end

local function MoveET_SetMoveMode(on)
	if on then
		MoveET_BuildMoveUI();
		MoveET_SyncMoveBox();
		MoveET_moveBox:Show();
		MoveET_moveInput:Show();
		MoveET_moveModeOn = true;
	else
		MoveET_moveModeOn = false;
		MoveET_StopDrag();
		if MoveET_moveBox then
			MoveET_moveBox:Hide();
			MoveET_moveInput:Hide();
		end
	end
	MoveET_UpdateMoveButton();
end

-- restore every setting to the game's own behavior, including the config
-- window's own position -- as if the addon was never enabled. The window
-- stays open and move mode stays on (the box follows the reset spot); a
-- drag in flight keeps going and its release (cursor truth) wins.
local function MoveET_Reset()
	if not db then
		return;
	end
	db.x, db.y = stockX, stockY;
	db.clickthrough, db.disable = false, false;
	db.win = { x = 0, y = 0 };
	MoveET_ApplyPosition();
	MoveET_ApplyDisable();
	if options then
		options:ClearAllPoints();
		options:SetPoint("CENTER", UIParent, "CENTER", 0, 0);
		if options.xBox then
			-- force the boxes: they may hold keyboard focus or a format-equal
			-- string ("-190.0") that the conditional refresh skips
			options.xBox:ClearFocus();
			options.yBox:ClearFocus();
			options.xBox:SetText(tostring(db.x));
			options.yBox:SetText(tostring(db.y));
		end
	end
	if refreshWindow then
		refreshWindow();
	end
end

-- ----------------------------------------------------------------------------
-- config window, built on init inside a pcall: even if a widget template
-- is missing in some client build, the toast positioning keeps working
-- ----------------------------------------------------------------------------
local function MoveET_MakeLabel(parent, text, point, relativeTo, relPoint, x, y)
	local fs = parent:CreateFontString(nil, "OVERLAY");
	fs:SetFontObject("GameFontNormalLarge");
	fs:SetText(text);
	fs:SetPoint(point, relativeTo, relPoint, x, y);
	return fs;
end

local function MoveET_ClearBoxFocus()
	if options and options.xBox then
		options.xBox:ClearFocus();
		options.yBox:ClearFocus();
	end
end

-- A coordinate box bound to db[key]. Enter commits a valid number (anything
-- else is ignored); every way of leaving the box -- Enter, Escape, Tab, a
-- click elsewhere -- shows the saved value again, so a rejected or
-- abandoned edit never lingers on screen looking applied.
local function MoveET_MakeCoordBox(key, x)
	local box = CreateFrame("EditBox", nil, options, "InputBoxTemplate");
	box:SetSize(80, 28);
	box:SetPoint("TOPLEFT", options, "TOPLEFT", x, -34);
	-- the compact font is load-bearing: the Large font makes "-100.00" wider
	-- than the visible text area and the EditBox then clips the digits
	box:SetFontObject("GameFontHighlight");
	if box.SetTextInsets then
		-- the template's left cap protrudes 5px outside the frame
		box:SetTextInsets(12, 8, 6, 6);
	end
	box:SetAutoFocus(false);
	box:SetMaxLetters(9);
	box:SetJustifyH("CENTER");
	local function ShowSaved(self)
		if db then
			self:SetText(tostring(db[key]));
		end
	end
	box:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText());
		if db and v and v >= -MAX_COORD and v <= MAX_COORD then
			db[key] = MoveET_Round2(v);
			MoveET_ApplyPosition();
			if refreshWindow then
				refreshWindow();
			end
		end
		self:ClearFocus();
		ShowSaved(self);
	end);
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus();
	end);
	box:SetScript("OnEditFocusLost", ShowSaved);
	return box;
end

local function MoveET_MakeCheck(name, label, y, onToggle)
	local check = CreateFrame("CheckButton", name, options, "UICheckButtonTemplate");
	check:SetSize(22, 22);
	check:SetPoint("TOPLEFT", options, "TOPLEFT", 44, y);
	MoveET_MakeLabel(options, label, "LEFT", check, "RIGHT", 8, 0);
	check:SetScript("OnClick", function(self)
		if db then
			onToggle(self:GetChecked() and true or false);
		end
	end);
	return check;
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
		self:StartMoving();
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
	options:SetScript("OnMouseDown", MoveET_ClearBoxFocus);
	if WorldFrame then
		WorldFrame:HookScript("OnMouseUp", function()
			if options:IsShown() then
				MoveET_ClearBoxFocus();
			end
		end);
	end

	local close = CreateFrame("Button", nil, options, "UIPanelCloseButton");
	close:SetPoint("TOPRIGHT", options, "TOPRIGHT", -4, -4);
	close:SetScript("OnClick", function()
		options:Hide();
	end);

	-- move mode: only while it is on is the toast spot drag-movable; the box
	-- doubles as the position preview (the manager hides with no toast)
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
		MoveET_SetMoveMode(not MoveET_moveModeOn);
	end);

	-- position: x/y coordinates with two decimal places, side by side; the
	-- labels are edge-anchored to their boxes so they sit on the same row
	options.xBox = MoveET_MakeCoordBox("x", 44);
	options.xLabel = MoveET_MakeLabel(options, "X", "RIGHT", options.xBox, "LEFT", -12, 0);
	options.yBox = MoveET_MakeCoordBox("y", 160);
	options.yLabel = MoveET_MakeLabel(options, "Y", "RIGHT", options.yBox, "LEFT", -12, 0);
	-- Tab hops between the two boxes (the edit is shown as saved on leave)
	options.xBox:SetScript("OnTabPressed", function() options.yBox:SetFocus(); end);
	options.yBox:SetScript("OnTabPressed", function() options.xBox:SetFocus(); end);

	-- clickthrough: nothing here intercepts mouse clicks
	options.clickBox = MoveET_MakeCheck("Move_Event_ToastClickthrough", "clickthrough", -70, function(on)
		db.clickthrough = on;
		MoveET_ApplyClickable();
	end);
	-- disable: no toasts at all while set
	options.disableBox = MoveET_MakeCheck("Move_Event_ToastDisable", "disable toasts", -98, function(on)
		db.disable = on;
		MoveET_ApplyDisable();
	end);

	function refreshWindow()
		if not db then
			return;
		end
		if tonumber(options.xBox:GetText()) ~= db.x then
			options.xBox:SetText(tostring(db.x));
		end
		if tonumber(options.yBox:GetText()) ~= db.y then
			options.yBox:SetText(tostring(db.y));
		end
		options.clickBox:SetChecked(db.clickthrough);
		options.disableBox:SetChecked(db.disable);
		MoveET_UpdateMoveButton();
		if MoveET_moveModeOn then
			MoveET_SyncMoveBox(); -- the box follows typed/reset/dragged changes too
		end
	end

	options:SetScript("OnShow", refreshWindow);
	options:SetScript("OnHide", function()
		if MoveET_moveModeOn then
			MoveET_SetMoveMode(false); -- leaving the window also leaves move mode
		end
	end);
end

-- ----------------------------------------------------------------------------
-- Load (pure Lua) + init (file scope, ADDON_LOADED and slash)
-- ----------------------------------------------------------------------------

-- Backfill the db from SavedVariables. Pure Lua table work, idempotent. The
-- first-run tutorial prints best-effort (never load-bearing).
local function MoveET_LoadState()
	if MoveET_stateLoaded then
		return;
	end
	local freshDB = type(_G[ADDON_NAME]) ~= "table";
	if freshDB then
		_G[ADDON_NAME] = {}; -- first session (also heals a corrupted non-table save)
	end
	db = _G[ADDON_NAME];
	MoveET_Sanitize(db);
	if freshDB then
		MoveET_instructions();
	end
	MoveET_stateLoaded = true;
end

-- Install the display post-hooks once (HookScript chains, so repeats would
-- stack duplicate wrappers). OnShow covers the first toast of a chain;
-- chained toasts come from the manager's fastHide (hideAnim on the same
-- path) OnFinished -> ToastingEnded -> DisplayToast with the manager already
-- shown, where OnShow does not fire.
local function MoveET_InstallHooks()
	if MoveET_hooksInstalled then
		return;
	end
	manager:HookScript("OnShow", MoveET_OnToastDisplayed);
	for _, key in ipairs({ "fastHide", "hideAnim" }) do
		local group = manager[key];
		if group and group.HookScript then
			group:HookScript("OnFinished", MoveET_OnToastDisplayed);
		end
	end
	MoveET_hooksInstalled = true;
end

-- Cheap idempotent (re-)entry: capture/hooks/window run once, applies
-- re-assert. The first apply waits for state.
local function MoveET_EnsureInit()
	MoveET_CaptureStock();
	MoveET_InstallHooks();
	if not options then
		pcall(MoveET_BuildWindow);
	end
	if MoveET_stateLoaded then
		MoveET_ApplyPosition(); -- positions over the login anchor
		MoveET_ApplyDisable(); -- saved clickthrough/disable from the start
		MoveET_SetLocked(true); -- Blizzard re-anchors stop here from now on
		if options then
			options:ClearAllPoints();
			options:SetPoint("CENTER", UIParent, "CENTER", db.win.x, db.win.y);
		end
		if refreshWindow then
			refreshWindow();
		end
	end
end

local MoveET_EventFrame = CreateFrame("Frame", "Move_Event_ToastEventFrame");
MoveET_EventFrame:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
		self:UnregisterEvent("ADDON_LOADED");
		MoveET_LoadState();
		MoveET_EnsureInit();
	end
end);
MoveET_EventFrame:RegisterEvent("ADDON_LOADED");

-- File scope runs before SavedVariables land: capture stock, install hooks,
-- build the window. The first apply waits for ADDON_LOADED.
MoveET_EnsureInit();

-- ----------------------------------------------------------------------------
-- slash command: bare /moveet (or anything unrecognized) toggles the config
-- window, /moveet reset restores the game's defaults
-- ----------------------------------------------------------------------------
SLASH_MOVEET1 = "/moveet";
SlashCmdList.MOVEET = function(msg)
	-- a missed ADDON_LOADED resumes here (state + init are idempotent)
	MoveET_LoadState();
	MoveET_EnsureInit();
	msg = string.lower(string.match(msg or "", "^%s*(.-)%s*$") or "");
	if msg == "reset" then
		MoveET_Reset();
	elseif options and options:IsShown() then
		options:Hide();
	elseif options then
		options:Show();
	end
end
