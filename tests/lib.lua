--[[
    Shared suite library for Move Event Toast (test_moveet, sim_mainline).
    Suites run from the addon root:

        local env = dofile("../shared/wow_test_env.lua"); -- the canonical mock
        local lib = dofile("tests/lib.lua").init(env);

    Passing env in (instead of dofile-ing the mock a second time) matters: a
    second dofile re-executes the mock and installs a FRESH frame registry,
    which would silently detach the addon from the suite's env.

    Provides the assert helpers, the slash/window drivers, and the client
    world, mirroring source/12.1.0's Blizzard_FrameXML EventToastManager:
      * EventToastManagerFrame on UIParent, strata HIGH, mouse on, anchor
        TOP/UIParent/TOP 0/-190, hidden with no toast (like the XML).
      * SimDisplayToast(manager) replays Blizzard's DisplayToast anchor
        behavior (UpdateAnchor: ClearAllPoints + SetPoint back to the stock
        spot), pools a fake toast with the two mouseover frames from the XML
        templates, and Shows the manager -- the exact re-anchor the addon's
        anchor-lock must neutralize.
    sim_restrictions.lua does NOT reuse this lib: it builds its minimal world
    on the restriction sim's seeded Blizzard-owned manager so every gated
    call is observed (see that file's header).
--]]

local function BuildToastWorld()
    local manager = CreateFrame("Frame", "EventToastManagerFrame", UIParent);
    manager:SetSize(418, 72);
    manager:SetFrameStrata("HIGH");
    manager:EnableMouse(true);
    manager:SetPoint("TOP", UIParent, "TOP", 0, -190);
    manager:Hide();
    manager.currentDisplayingToast = nil;
    _G.EventToastManagerFrame = manager;
    return manager;
end

-- Blizzard's DisplayToast, anchor behavior verbatim (UpdateAnchor resets to
-- the stock spot on EVERY toast, including per-texture-kit custom offsets --
-- here the stock spot): the addon's lock must neutralize exactly this.
local function SimDisplayToast(manager)
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
    return toast;
end

return {
    init = function(env)
        local out = env.rawPrint;
        local lib = {};

        local PASS, FAIL = 0, 0;
        function lib.ok(cond, name, extra)
            if cond then PASS = PASS + 1; out("  PASS: " .. name);
            else FAIL = FAIL + 1; out("  FAIL: " .. name .. (extra ~= nil and (" -- " .. tostring(extra)) or "")); end
        end
        function lib.done()
            out(("Test/Sim Results: %d passed, %d failed"):format(PASS, FAIL));
            if FAIL > 0 then
                os.exit(1);
            end
        end

        function lib.same(actual, expected)
            if #actual ~= #expected then return false; end
            for i = 1, #actual do
                if actual[i] ~= expected[i] then return false; end
            end
            return true;
        end

        -- points as comparable tables: relativeTo reduced to its name
        function lib.P(frame, index)
            local point, relativeTo, relativePoint, x, y = frame:GetPoint(index or 1);
            return { point, relativeTo and (relativeTo.GetName and relativeTo:GetName()) or tostring(relativeTo), relativePoint, x, y };
        end

        -- wipe the session (frames/log/clock cleared, SV globals kept only
        -- when keepDB), rebuild the toast world, load the addon and fire
        -- ADDON_LOADED; returns the manager. A Reload helper drives a second
        -- ADDON_LOADED; returns the manager.
        function lib.Boot(keepDB)
            if not keepDB then
                _G.Move_Event_Toast = nil;
            end
            env:Reset();
            _G.UIParent:SetSize(1024, 768);
            _G.EventToastManagerFrame = nil;
            local manager = BuildToastWorld();
            assert(loadfile("Move_Event_Toast.lua"))();
            env:FireEvent("ADDON_LOADED", "Move_Event_Toast");
            return manager;
        end

        function lib.DisplayToast(manager)
            local toast = SimDisplayToast(manager);
            -- the mock Show fires no scripts: drive the post-hook by hand,
            -- like every suite here drives OnShow/OnHide
            local s = manager:GetScript("OnShow");
            if s then s(manager); end
            return toast;
        end

        function lib.Slash(msg)
            SlashCmdList.MOVEET(msg);
        end

        function lib.Window()
            SlashCmdList.MOVEET("");
            return env:FindFrame("Move_Event_ToastOptions");
        end

        -- type into an edit box and press enter
        function lib.TypeIn(box, value)
            box:SetText(value);
            local s = box:GetScript("OnEnterPressed");
            if s then s(box); end
        end

        -- click a widget; pass checked to set a checkbox state first
        function lib.Click(widget, checked)
            if checked ~= nil then
                widget:SetChecked(checked);
            end
            local s = widget:GetScript("OnClick");
            if s then s(widget); end
        end

        return lib;
    end,
};
