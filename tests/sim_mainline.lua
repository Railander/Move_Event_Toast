--[[
    Integration sim for Move Event Toast: a realistic 12.1 session against
    the mock client -- login, toasts arriving between sessions, configuring
    mid-session, zoning, /reload, disable finale.
    Run with: lua5.1 tests/sim_mainline.lua   (from the addon root)
--]]

local env = dofile("../shared/wow_test_env.lua");
local lib = dofile("tests/lib.lua").init(env);
local out = env.rawPrint;
local ok, same, P = lib.ok, lib.same, lib.P;
local Boot, DisplayToast, Slash, Window, TypeIn, Click
    = lib.Boot, lib.DisplayToast, lib.Slash, lib.Window, lib.TypeIn, lib.Click;

out("login and first toasts:");

local manager = Boot();
local db = _G.Move_Event_Toast;
ok(same(P(manager), { "TOP", "UIParent", "TOP", 0, -190 }),
    "login leaves the game's own anchor alone");

-- a level-up toast arrives right after login, before any configuration
local toast = DisplayToast(manager);
ok(manager:IsShown(), "toast shows the manager");
ok(same(P(manager), { "TOP", "UIParent", "TOP", 0, -190 }),
    "stock toast lands on the stock spot");

out("configure mid-session:");

local options = Window();
TypeIn(options.xBox, "-300");
TypeIn(options.yBox, "-320");
ok(db.x == -300 and db.y == -320, "player moves the toast spot");
DisplayToast(manager);
ok(same(P(manager), { "TOP", "UIParent", "TOP", -300, -320 }),
    "later toasts use the moved spot");
ok(manager.currentDisplayingToast ~= toast, "new toast pooled per display");

out("dungeon run: zone in, toast mid-run, zone out:");

env:FireEvent("ZONE_CHANGED_NEW_AREA");
DisplayToast(manager);
ok(same(P(manager), { "TOP", "UIParent", "TOP", -300, -320 }),
    "spot survives zone crossings and run toasts");

out("clickthrough for the rest of the night:");

Click(options.clickBox, true);
DisplayToast(manager);
ok(manager:IsMouseEnabled() == false
    and manager.currentDisplayingToast:IsMouseEnabled() == false,
    "manager and toast both clickthrough");

out("/reload between pulls:");

manager = Boot(true);
db = _G.Move_Event_Toast;
options = Window();
ok(db.x == -300 and db.y == -320 and db.clickthrough == true,
    "reload keeps the whole evening's setup");
ok(manager:IsMouseEnabled() == false, "clickthrough applies at login");
DisplayToast(manager);
ok(same(P(manager), { "TOP", "UIParent", "TOP", -300, -320 }),
    "first toast after reload uses the saved spot");
ok(manager.currentDisplayingToast:IsMouseEnabled() == false,
    "first toast after reload is clickthrough");

out("disable finale and reset:");

Click(options.disableBox, true);
DisplayToast(manager);
ok(not manager:IsShown(), "disabled: event toasts stay hidden");
Slash("reset");
ok(_G.Move_Event_Toast.disable == false, "reset re-enables");
DisplayToast(manager);
ok(manager:IsShown() and manager:GetAlpha() == 1, "toasts visible again");

lib.done();
