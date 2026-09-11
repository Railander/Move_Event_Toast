--[[
    Restriction-discipline suite for Move Event Toast on the SHARED harness.

    Straps the addon to shared/wow_test_env.lua (mock client) +
    shared/wow_restriction_sim.lua (12.x enforcement layer: SecretArguments
    gates, dispatch-false query semantics, hooksecurefunc taint).

    Run from the addon root: lua5.1 tests/sim_restrictions.lua
    Prints PASS:/FAIL: lines, ends with "Test Results: N passed, M failed",
    os.exit(1) on any failure. Output via env.rawPrint (print is captured).

    Harness adaptations (documented, not worked around):
    - tests/lib.lua is NOT reused here: its world is built for the bare mock
      (no gates, no seeds). The minimal world below is built on the sim's
      seeded Blizzard-owned EventToastManagerFrame so every gated call is
      observed.
    - Toast scaffolding (CreateFrame + EnableMouse on the pooled toast) is
      Blizzard-equivalent Lua here: in game the toast pool is created by
      untainted Blizzard execution, so violations it logs while locked are
      cleared as test-induced; the addon itself must log nothing.
    - The sim does not gate layout getters (GetPoint) or ClearAllPoints;
      the addon still avoids them while locked by design (lock-checked
      appliers), so sim-clean matches the game-safe discipline.
    - Mainline only: the toast manager is a mainline FrameXML frame (no
      classic flavor ships it), so there is no classic-flavor section.
--]]

local env = dofile("../shared/wow_test_env.lua");
local rs = dofile("../shared/wow_restriction_sim.lua");

local PASS, FAIL = 0, 0;
local function ok(cond, name, extra)
    if cond then PASS = PASS + 1; env.rawPrint("  PASS: " .. name);
    else FAIL = FAIL + 1; env.rawPrint("  FAIL: " .. name .. (extra and (" -- " .. tostring(extra)) or "")); end
end

local function newViolations(base)
    local out = {};
    for i = base + 1, #env.restrictionViolations do
        out[#out + 1] = env.restrictionViolations[i].api;
    end
    return out;
end

local function noSetShown(base, label)
    for i = base + 1, #env.restrictionViolations do
        if env.restrictionViolations[i].api == "Frame:SetShown" then
            ok(false, label, "SetShown used; Show/Hide required");
            return;
        end
    end
    ok(true, label);
end

local function pointOf(region)
    local a, b, c, d, e = region:GetPoint(1);
    if type(b) == "table" then b = b:GetName() or "?"; end
    return table.concat({ tostring(a), tostring(b), tostring(c), tostring(d), tostring(e) }, "|");
end

-- Stock toast world on the sim's Blizzard seed (mirrors tests/lib.lua).
local function buildWorld()
    local manager = _G.EventToastManagerFrame;
    manager:SetSize(418, 72);
    manager:SetFrameStrata("HIGH");
    manager:EnableMouse(true);
    manager:SetPoint("TOP", UIParent, "TOP", 0, -190);
    manager:Hide();
    manager.currentDisplayingToast = nil;
    return manager;
end

-- Blizzard's DisplayToast, anchor behavior verbatim (UpdateAnchor resets to
-- the stock spot on every toast). Toast scaffolding is test-induced (see
-- header): callers ClearViolations after building it while locked. The
-- OnShow post-hook ref is captured while clear (GetScript is itself gated --
-- driving it by reference under lock, like every driver here).
local onShowHook;
local function blizzardToast(manager)
    manager:ClearAllPoints();
    manager:SetPoint("TOP", UIParent, "TOP", 0, -190);
    local toast = CreateFrame("Frame", nil, manager);
    toast:EnableMouse(true);
    toast.TitleTextMouseOverFrame = CreateFrame("Frame", nil, toast);
    toast.TitleTextMouseOverFrame:EnableMouse(true);
    toast.SubTitleMouseOverFrame = CreateFrame("Frame", nil, toast);
    toast.SubTitleMouseOverFrame:EnableMouse(true);
    manager.currentDisplayingToast = toast;
    manager:Show();
    local s = onShowHook or manager:GetScript("OnShow");
    if s then s(manager); end
    return toast;
end

local function findOptions()
    return env:FindFrame("Move_Event_ToastOptions");
end

local function findEventFrame()
    return env:FindFrame("Move_Event_ToastEventFrame");
end

local function liftAll()
    for _, t in ipairs(rs.Types) do
        env:FireRestrictionChange(t, rs.INACTIVE);
    end
    env:RunTimers(); -- the out-of-dispatch confirm
end

-- driver refs, captured while clear at the end of R3 (GetScript is gated)
local onClickThrough, onDisableClick, onXEnter, onYEnter, onMoveBtn;

-- Boot under MAX restrictions: the /reload-in-combat trap. The world itself
-- is built clear first (Blizzard frames anchor before combat; only the ADDON
-- load lands mid-protection), then the lock slams on.
rs.Enable(env, { scenario = "none", flavor = "mainline" });
_G.UIParent:SetSize(1024, 768);
local manager = buildWorld();
env:ActivateAllRestrictions();
env:ClearViolations();
_G.Move_Event_Toast = nil;
assert(loadfile("Move_Event_Toast.lua"))();
env:FireEvent("ADDON_LOADED", "Move_Event_Toast");

env.rawPrint("== R1: max boot defers everything with zero gates ==");
do
    ok(#env.restrictionViolations == 0, "locked boot logs nothing (lock checked before any install)");
    ok(_G.Move_Event_Toast == nil, "saved state untouched: ADDON_LOADED unheard while deaf");
    ok(findOptions() == nil, "options window NOT half-built while protected");
    local ef = findEventFrame();
    ok(ef ~= nil, "listener frame exists (CreateFrame is ungated)");
    ok(ef ~= nil and not ef:IsEventRegistered("ADDON_LOADED"), "no event registered while protected");
    ok(#env.taintedHooks == 0, "no Blizzard-Lua hooks installed while protected");
end

env.rawPrint("== R2: slash self-heal while locked is fully silent ==");
do
    local base = #env.restrictionViolations;
    SlashCmdList.MOVEET(""); -- lazy state load (pure Lua) + deferred gated init
    ok(#newViolations(base) == 0, "locked slash logs nothing");
    local db = _G.Move_Event_Toast;
    ok(db ~= nil and db.x == 0 and db.y == -190, "state loaded (game placement) while gates wait");
    ok(#env.printLog == 0, "first-run greet queued, not printed into lockdown (best-effort)");
    ok(findOptions() == nil, "options still unbuilt while locked");
    base = #env.restrictionViolations;
    SlashCmdList.MOVEET("reset"); -- db-only work lands, applies queue
    ok(#newViolations(base) == 0, "locked reset logs nothing");
    ok(_G.Move_Event_Toast.x == 0 and _G.Move_Event_Toast.y == -190, "reset db correct while applies wait");
    noSetShown(base, "no SetShown anywhere on the locked paths");
end

env.rawPrint("== R3: slash-heal lift resumes everything with zero gates ==");
do
    -- a deaf boot owns no event registrations yet, so the restriction event
    -- cannot wake it (by design); the slash self-heal is the recovery path
    -- here -- the payload-protocol lift is covered from R4 on, once
    -- registrations exist.
    env:DeactivateAllRestrictions();
    env:ClearViolations();
    local base = #env.restrictionViolations;
    SlashCmdList.MOVEET("");
    ok(#newViolations(base) == 0, "lift init is clean");
    local db = _G.Move_Event_Toast;
    ok(pointOf(manager) == "TOP|UIParent|TOP|0|-190", "saved spot applied at lift", pointOf(manager));
    ok(findOptions() ~= nil, "options built once clear");
    ok(#env.printLog == 2, "queued first-run greet prints on lift", #env.printLog);
    -- the anchor lock is in: a Blizzard re-anchor attempt moves nothing
    base = #env.restrictionViolations;
    manager:ClearAllPoints();
    manager:SetPoint("TOP", UIParent, "TOP", 0, -190);
    ok(pointOf(manager) == "TOP|UIParent|TOP|0|-190", "re-anchor is a no-op under the lock");
    ok(#newViolations(base) == 0, "lock no-ops log nothing (no gated calls inside)");
    -- capture the gated-readable refs while clear: every driver below runs
    -- them by reference under lock (GetScript itself is gated).
    onShowHook = manager:GetScript("OnShow");
    local options = findOptions();
    onClickThrough = options.clickBox:GetScript("OnClick");
    onDisableClick = options.disableBox:GetScript("OnClick");
    onXEnter = options.xBox:GetScript("OnEnterPressed");
    onYEnter = options.yBox:GetScript("OnEnterPressed");
    onMoveBtn = options.moveBtn:GetScript("OnClick");
    ok(onShowHook and onClickThrough and onXEnter and onMoveBtn, "driver refs captured while clear");
end

env.rawPrint("== R4: toast arriving mid-lockdown is contained ==");
do
    env:ActivateAllRestrictions();
    env:ClearViolations();
    local base = #env.restrictionViolations;
    blizzardToast(manager); -- scaffolding violations are test-induced (see header)
    env:ClearViolations();
    ok(pointOf(manager) == "TOP|UIParent|TOP|0|-190", "locked toast cannot displace the spot");
    ok(#env.restrictionViolations == 0, "OnShow post-hook queues while locked (no attempts)");
    -- clickthrough requested while locked: db lands, mouse waits
    local options = findOptions();
    options.clickBox:SetChecked(true);
    onClickThrough(options.clickBox);
    ok(_G.Move_Event_Toast.clickthrough == true, "locked input lands in db");
    ok(#env.restrictionViolations == 0, "locked checkbox logs nothing");
    liftAll();
    ok(manager:IsMouseEnabled() == false, "queued clickthrough flushes on lift");
    ok(#env.restrictionViolations == 0, "lift flush is clean");
end

env.rawPrint("== R5: locked coordinate writes queue, then flush ==");
do
    env:ActivateAllRestrictions();
    env:ClearViolations();
    local options = findOptions();
    local base = #env.restrictionViolations;
    options.xBox:SetText("200");
    onXEnter(options.xBox);
    options.yBox:SetText("-260");
    onYEnter(options.yBox);
    ok(_G.Move_Event_Toast.x == 200 and _G.Move_Event_Toast.y == -260, "locked coords land in db");
    ok(pointOf(manager) == "TOP|UIParent|TOP|0|-190", "manager unmoved while locked");
    ok(#newViolations(base) == 0, "locked typing logs nothing");
    liftAll();
    ok(pointOf(manager) == "TOP|UIParent|TOP|200|-260", "queued spot flushes on lift");
    ok(#env.restrictionViolations == 0, "flush is clean");
end

env.rawPrint("== R6: mid-drag lock cancels the gesture ==");
do
    local options = findOptions();
    options:Show();
    local input = env:FindFrame("Move_Event_ToastMoveInput");
    if not (input and input:IsShown()) then
        SlashCmdList.MOVEET(""); -- ensure window open
        onMoveBtn(options.moveBtn);
        input = env:FindFrame("Move_Event_ToastMoveInput");
    end
    ok(input ~= nil and input:IsShown(), "move mode entered while clear");
    env.cursorX, env.cursorY = 512 + 200, 768 - 260; -- grab the anchor exactly
    local onDragStart = input:GetScript("OnDragStart");
    onDragStart(input);
    local onDragUpdate = input:GetScript("OnUpdate");
    env.cursorX, env.cursorY = 700, 400;
    env:FireRestrictionChange("Combat", rs.ACTIVE); -- protection lands mid-drag
    onDragUpdate(input); -- idle early-return: gesture already ended
    ok(_G.Move_Event_Toast.x == 200 and _G.Move_Event_Toast.y == -260,
        "mid-drag lock persists nothing (pre-lock spot kept)");
    local base = #env.restrictionViolations;
    onMoveBtn(options.moveBtn); -- exit while locked
    ok(#newViolations(base) == 0, "leaving move mode while locked is safe (Hide ungated)");
    ok(not input:IsShown(), "input hidden on exit");
    env:FireRestrictionChange("Combat", rs.INACTIVE);
    env:RunTimers();
    ok(#env.restrictionViolations == 0, "re-lift is clean");
end

env.rawPrint("== R7: move-mode entry refuses while locked ==");
do
    env:ActivateAllRestrictions();
    env:ClearViolations();
    local options = findOptions();
    local base = #env.restrictionViolations;
    onMoveBtn(options.moveBtn);
    local input = env:FindFrame("Move_Event_ToastMoveInput");
    ok(input == nil or not input:IsShown(), "no drag surface while locked");
    ok(#newViolations(base) == 0, "refused entry logs nothing");
    liftAll();
end

env.rawPrint("== R8: zone re-checks and the final audit ==");
do
    local base = #env.restrictionViolations;
    env:FireEvent("PLAYER_ENTERING_WORLD");
    env:FireEvent("ZONE_CHANGED");
    env:FireEvent("ZONE_CHANGED_NEW_AREA");
    ok(pointOf(manager) == "TOP|UIParent|TOP|200|-260", "zone crossings keep the spot");
    ok(#newViolations(base) == 0, "zone re-checks are clean");
    ok(#env.taintedHooks == 0, "zero hooksecurefunc on Blizzard Lua, end to end");
    noSetShown(base, "Show/Hide only, never SetShown");
    local fails = env:AssertNoViolations("final: no restriction violations");
    ok(fails == 0, "final audit clean");
end

env.rawPrint(("Test Results: %d passed, %d failed"):format(PASS, FAIL));
if FAIL > 0 then os.exit(1); end
