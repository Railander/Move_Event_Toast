--[[
    Unit tests for Move Event Toast -- boot, window, appliers, move mode.
    Run with: lua5.1 tests/test_moveet.lua   (from the addon root)
--]]

local env = dofile("../shared/wow_test_env.lua");
local lib = dofile("tests/lib.lua").init(env);
local out = env.rawPrint;
local ok, same, P = lib.ok, lib.same, lib.P;
local Boot, DisplayToast, Slash, Window, TypeIn, Click
    = lib.Boot, lib.DisplayToast, lib.Slash, lib.Window, lib.TypeIn, lib.Click;

-- ----------------------------------------------------------------------------
-- static hygiene: the addon must not leak globals (a bare `moveBox`-style
-- typo silently shares state across /reloads: the second boot reuses the
-- first boot's orphaned frames). luac lists every global store; the only
-- legal one is the client's slash registration. It also lists every global
-- READ: any MoveET_-prefixed read is a missed forward declaration (a later
-- `local` the earlier code cannot see -- silently nil until that branch
-- runs live). Runs first so either failure lands precisely here instead of
-- downstream.
-- ----------------------------------------------------------------------------
out("global hygiene:");

do
	local pipe = io.popen("luac -l -p Move_Event_Toast.lua 2>&1");
	ok(pipe ~= nil, "luac listing runs");
	if pipe then
		local listing = pipe:read("*a");
		pipe:close();
		local leaks = {};
		for name in listing:gmatch("SETGLOBAL%s+%d+%s+%-?%d+%s+;%s+([A-Za-z_][A-Za-z0-9_]*)") do
			if name ~= "SLASH_MOVEET1" then
				leaks[#leaks + 1] = name;
			end
		end
		ok(#leaks == 0, "no leaked globals (only SLASH_MOVEET1)", table.concat(leaks, ","));
		local early = {};
		for name in listing:gmatch("GETGLOBAL%s+%d+%s+%-?%d+%s+;%s+(MoveET_[A-Za-z0-9_]*)") do
			early[#early + 1] = name;
		end
		ok(#early == 0, "no early globals (all MoveET_ refs are locals)", table.concat(early, ","));
	end
end

-- ----------------------------------------------------------------------------
-- boot and the window
-- ----------------------------------------------------------------------------
out("boot and window:");

local manager = Boot();
local db = _G.Move_Event_Toast;

ok(#env.printLog == 2 and env.printLog[1]:find("/moveet", 1, true) ~= nil,
    "fresh install prints the chat instructions", #env.printLog);
ok(db.x == 0 and db.y == -190 and db.clickthrough == false and db.disable == false,
    "fresh defaults: game's own spot, mouse on, toasts on");
ok(type(db.win) == "table" and db.win.x == 0 and db.win.y == 0,
    "window position backfills centered");
ok(same(P(manager), { "TOP", "UIParent", "TOP", 0, -190 }),
    "fresh install keeps the game's own anchor");
ok(manager:IsMouseEnabled() ~= false, "fresh install leaves the mouse on");
ok(manager:GetAlpha() == 1, "fresh install leaves full alpha");

local options = Window();
ok(options ~= nil and options:IsShown(), "/moveet opens the config window");
ok(options.xBox and options.yBox and options.clickBox and options.disableBox and options.moveBtn,
    "window has X/Y boxes, both checkboxes and the move button");
Slash("");
ok(not options:IsShown(), "/moveet again closes it");
Slash("garbage");
ok(options:IsShown(), "unrecognized input opens the window");
Slash("RESET");
ok(db.x == 0 and db.y == -190, "/moveet reset is case-insensitive");

-- ----------------------------------------------------------------------------
-- toasts: Blizzard's per-toast re-anchor must not displace the saved spot
-- ----------------------------------------------------------------------------
out("toast display:");

TypeIn(options.xBox, "120");
TypeIn(options.yBox, "-250");
ok(db.x == 120 and db.y == -250, "boxes save the spot");
ok(same(P(manager), { "TOP", "UIParent", "TOP", 120, -250 }),
    "boxes move the manager");

local toast = DisplayToast(manager);
ok(same(P(manager), { "TOP", "UIParent", "TOP", 120, -250 }),
    "a toast keeps the saved spot (re-anchor neutralized)");
ok(toast:IsMouseEnabled() ~= false, "toast mouse follows the setting (on)");

Click(options.clickBox, true);
ok(db.clickthrough == true, "clickthrough checkbox saves");
ok(manager:IsMouseEnabled() == false, "manager stops intercepting clicks");
local toast2 = DisplayToast(manager);
ok(toast2:IsMouseEnabled() == false, "new toasts arrive clickthrough");
ok(toast2.TitleTextMouseOverFrame:IsMouseEnabled() == false, "title mouseover frame clickthrough");
ok(toast2.SubTitleMouseOverFrame:IsMouseEnabled() == false, "subtitle mouseover frame clickthrough");
Click(options.clickBox, false);
ok(manager:IsMouseEnabled() ~= false, "clickthrough off restores the mouse");

-- ----------------------------------------------------------------------------
-- disable: toasts go invisible and stay suppressed
-- ----------------------------------------------------------------------------
out("disable:");

Click(options.disableBox, true);
ok(db.disable == true, "disable checkbox saves");
ok(manager:GetAlpha() == 0, "disable fades the manager out");
ok(not manager:IsShown(), "disable hides the manager");
local toast3 = DisplayToast(manager);
ok(not manager:IsShown(), "toasts arriving while disabled stay suppressed", manager:IsShown());
Click(options.disableBox, false);
ok(db.disable == false, "re-enable saves");
ok(manager:GetAlpha() == 1, "re-enable restores full alpha");
DisplayToast(manager);
ok(manager:IsShown(), "toasts show again once enabled");

-- ----------------------------------------------------------------------------
-- zoning and reloads re-assert the saved spot
-- ----------------------------------------------------------------------------
out("zones and reloads:");

env:FireEvent("PLAYER_ENTERING_WORLD");
ok(same(P(manager), { "TOP", "UIParent", "TOP", 120, -250 }),
    "zoning keeps the saved spot");
TypeIn(options.xBox, "40");
manager = Boot(true); -- /reload over the kept db
db = _G.Move_Event_Toast;
ok(db.x == 40 and db.y == -250, "reload keeps the saved values");
ok(same(P(manager), { "TOP", "UIParent", "TOP", 40, -250 }),
    "reload re-applies the saved spot at login (v1 never did)");
ok(#env.printLog == 0, "reload never reprints the instructions");

-- ----------------------------------------------------------------------------
-- reset restores the game's own behavior
-- ----------------------------------------------------------------------------
out("reset:");

options = Window();
Click(options.clickBox, true);
Click(options.disableBox, true);
Slash("reset");
db = _G.Move_Event_Toast;
ok(db.x == 0 and db.y == -190 and db.clickthrough == false and db.disable == false,
    "reset restores every value to the game's own");
ok(same(P(manager), { "TOP", "UIParent", "TOP", 0, -190 }),
    "reset restores the game's own placement");
ok(manager:GetAlpha() == 1 and manager:IsMouseEnabled() ~= false,
    "reset restores alpha and mouse");
ok(options.clickBox:GetChecked() == false and options.disableBox:GetChecked() == false,
    "reset refreshes the checkboxes");

-- ----------------------------------------------------------------------------
-- validation: garbage never lands in the db
-- ----------------------------------------------------------------------------
out("validation:");

TypeIn(options.xBox, "banana");
ok(db.x == 0, "non-numeric X is ignored");
TypeIn(options.yBox, "999999999");
ok(db.y == -190, "out-of-range Y falls back to stock");
TypeIn(options.xBox, "10.567");
ok(db.x == 10.57, "coords round to 2 decimals at the boundary", db.x);

-- ----------------------------------------------------------------------------
-- legacy v1 tables carry over verbatim (the old slash addon saved exactly
-- x/y/clickthrough/disable under this same name)
-- ----------------------------------------------------------------------------
out("legacy carryover:");

env:Reset();
_G.UIParent:SetSize(1024, 768);
_G.Move_Event_Toast = { x = -50, y = -210, clickthrough = true, disable = false };
local manager2 = (function()
    local m = CreateFrame("Frame", "EventToastManagerFrame", UIParent);
    m:SetSize(418, 72);
    m:SetFrameStrata("HIGH");
    m:EnableMouse(true);
    m:SetPoint("TOP", UIParent, "TOP", 0, -190);
    m:Hide();
    m.currentDisplayingToast = nil;
    _G.EventToastManagerFrame = m;
    assert(loadfile("Move_Event_Toast.lua"))();
    env:FireEvent("ADDON_LOADED", "Move_Event_Toast");
    return m;
end)();
local db2 = _G.Move_Event_Toast;
ok(db2.x == -50 and db2.y == -210 and db2.clickthrough == true and db2.disable == false,
    "v1 values carry over verbatim");
ok(type(db2.win) == "table", "win backfills without a re-greet");
ok(#env.printLog == 0, "upgrading never reprints the instructions");
ok(manager2:IsMouseEnabled() == false, "carried clickthrough applies at login");
ok(same(P(manager2), { "TOP", "UIParent", "TOP", -50, -210 }),
    "carried position applies at login");

-- float32 layout drift from older saves heals at load
env:Reset();
_G.UIParent:SetSize(1024, 768);
_G.Move_Event_Toast = { x = -140.00001525879, y = -190, clickthrough = false, disable = false };
Boot(true);
ok(_G.Move_Event_Toast.x == -140, "float drift heals to 2 decimals", _G.Move_Event_Toast.x);

-- a v1 table saved while disabled boots suppressed, with no toast needed
env:Reset();
_G.UIParent:SetSize(1024, 768);
_G.Move_Event_Toast = { x = 0, y = -190, clickthrough = false, disable = true };
local manager4 = Boot(true);
ok(_G.Move_Event_Toast.disable == true, "v1 disable carries over");
ok(manager4:GetAlpha() == 0 and not manager4:IsShown(),
    "carried disable applies at login");

-- a truncated v1 table (all keys missing) falls back to stock, crash-free
env:Reset();
_G.UIParent:SetSize(1024, 768);
_G.Move_Event_Toast = {};
local manager5 = Boot(true);
local db5 = _G.Move_Event_Toast;
ok(db5.x == 0 and db5.y == -190 and db5.clickthrough == false and db5.disable == false,
    "empty table falls back to stock defaults");
ok(same(P(manager5), { "TOP", "UIParent", "TOP", 0, -190 }),
    "empty table still boots clean");

-- ----------------------------------------------------------------------------
-- move mode: drag the toast spot on both axes
-- ----------------------------------------------------------------------------
out("move mode:");

manager = Boot();
db = _G.Move_Event_Toast;
options = Window();

local function BoxOf() return env:FindFrame("Move_Event_ToastMoveBox"); end
local function InputOf() return env:FindFrame("Move_Event_ToastMoveInput"); end

ok(options.moveBtn ~= nil and options.moveBtn:GetText() == "move toast",
    "window has the move button, labelled for entry");
ok(BoxOf() == nil, "box and input are built lazily, not at login");

Click(options.moveBtn);
local box, input = BoxOf(), InputOf();
ok(box ~= nil and input ~= nil and box:IsShown() and input:IsShown(),
    "move button shows the box and the input");
ok(options.moveBtn:GetText() == "stop moving", "button relabels while moving");
ok(same(P(box), { "TOP", "UIParent", "TOP", 0, -190 }),
    "box copies the saved spot");
ok(box:GetWidth() == 418 and box:GetHeight() == 72, "box matches the manager size");
ok(box:GetFrameStrata() == "BACKGROUND", "box sits below (BACKGROUND)");
ok(input:GetFrameStrata() == "TOOLTIP", "input sits above for grabs");
local boxTex = ({ box:GetRegions() })[1];
ok(boxTex ~= nil and boxTex.r == 0 and boxTex.g == 1 and boxTex.b == 0 and boxTex.a == 0.5,
    "box is the 50% green marker");

-- drag: grab the anchor exactly, move the cursor, the spot follows
env.cursorX, env.cursorY = 512, 768 - 190; -- cursor right on the anchor
input:GetScript("OnDragStart")(input);
ok(input:GetScript("OnUpdate") ~= nil, "grab attaches the drag script");
env.cursorX, env.cursorY = 612, 528;
input:GetScript("OnUpdate")(input);
ok(db.x == 100 and db.y == -240, "drag writes both axes (cursor-driven)",
    db.x .. "," .. db.y);
ok(same(P(manager), { "TOP", "UIParent", "TOP", 100, -240 }),
    "manager follows, anchor preserved");
ok(same(P(box), P(manager)), "box follows the manager");
ok(options.xBox:GetText() == "100" and options.yBox:GetText() == "-240",
    "boxes update live while dragging");
input:GetScript("OnDragStop")(input);
ok(input:GetScript("OnUpdate") == nil, "release detaches the drag script");

-- typing while move mode is on moves the box too
TypeIn(options.xBox, "200");
ok(same(P(box), { "TOP", "UIParent", "TOP", 200, -240 }),
    "typed values move the box while moving");

-- leaving the window also leaves move mode
options:GetScript("OnHide")(options);
ok(not box:IsShown() and not input:IsShown(), "window close leaves move mode");

-- ----------------------------------------------------------------------------
-- unknown layout: inert before touching SavedVariables
-- ----------------------------------------------------------------------------
out("unknown layout:");

env:Reset();
_G.UIParent:SetSize(1024, 768);
_G.Move_Event_Toast = nil;
_G.EventToastManagerFrame = nil;
assert(loadfile("Move_Event_Toast.lua"))();
env:FireEvent("ADDON_LOADED", "Move_Event_Toast");
ok(_G.Move_Event_Toast == nil, "missing manager stays inert (SV untouched)");
ok(SlashCmdList.MOVEET == nil, "missing manager registers no slash");

-- ----------------------------------------------------------------------------
-- missing templates: the core positioning survives a failed window build
-- ----------------------------------------------------------------------------
out("template failure:");

env:Reset();
_G.UIParent:SetSize(1024, 768);
_G.Move_Event_Toast = nil;
env.failTemplates = { "BackdropTemplate" };
local manager3 = (function()
    local m = CreateFrame("Frame", "EventToastManagerFrame", UIParent);
    m:SetSize(418, 72);
    m:SetFrameStrata("HIGH");
    m:EnableMouse(true);
    m:SetPoint("TOP", UIParent, "TOP", 0, -190);
    m:Hide();
    m.currentDisplayingToast = nil;
    _G.EventToastManagerFrame = m;
    assert(loadfile("Move_Event_Toast.lua"))();
    env:FireEvent("ADDON_LOADED", "Move_Event_Toast");
    return m;
end)();
env.failTemplates = nil;
ok(same(P(manager3), { "TOP", "UIParent", "TOP", 0, -190 }),
    "positioning works with no options window");
SlashCmdList.MOVEET("");
ok(true, "slash with no window does not error");

lib.done();
