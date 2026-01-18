-- ingame instructions
local exitColor = "|r"
local colorOrange = "|cFFDF9F1F"
local colorRed = "|cFFFF3F1F"
local function MoveEventToast_instructions()
	print(colorOrange .. "Use /moveet followed by: the desired X and Y coordinates; whether to preview where it's currently at; whether to make it clickthrough; whether to disable it; to print saved config." .. exitColor)
	print(colorOrange .. "Example:" .. exitColor .. " /moveet 0 -150")
	print(colorOrange .. "Example:" .. exitColor .. " /moveet preview")
	print(colorOrange .. "Example:" .. exitColor .. " /moveet clickthrough yes")
	print(colorOrange .. "Example:" .. exitColor .. " /moveet disable yes")
	print(colorOrange .. "Example:" .. exitColor .. " /moveet print")
end

-- main functionality
local anchorMyselfAt, anchorTo, anchorToAt, coordX, coordY = EventToastManagerFrame:GetPoint()

local function MoveEventToast_clickable(bool)
	EventToastManagerFrame:EnableMouse(bool)
	if EventToastManagerFrame.currentDisplayingToast then
		EventToastManagerFrame.currentDisplayingToast:EnableMouse(bool)
		EventToastManagerFrame.currentDisplayingToast.TitleTextMouseOverFrame:EnableMouse(bool)
		EventToastManagerFrame.currentDisplayingToast.SubTitleMouseOverFrame:EnableMouse(bool)
	end
end

local function MoveEventToast_mover()
	if Move_Event_Toast.disable then
		EventToastManagerFrame:SetAlpha(0)
		MoveEventToast_clickable(false)
	else
		EventToastManagerFrame:SetPoint(anchorMyselfAt,anchorTo,anchorToAt,Move_Event_Toast.x,Move_Event_Toast.y)
		if Move_Event_Toast.clickthrough then
			MoveEventToast_clickable(false)
		end
	end
end

-- preview frame
local MoveEventToast_previewing = false
local Fr_MoveEventToast_Preview = CreateFrame("Frame", nil, UIParent)
Fr_MoveEventToast_Preview:SetSize(418, 72)
Fr_MoveEventToast_Preview:SetAlpha(0)
Fr_MoveEventToast_Preview.texture = Fr_MoveEventToast_Preview:CreateTexture(nil, "BACKGROUND")
Fr_MoveEventToast_Preview.texture:SetAllPoints(Fr_MoveEventToast_Preview)
Fr_MoveEventToast_Preview.texture:SetPoint("CENTER", Fr_MoveEventToast_Preview, "CENTER", 0, 0)
Fr_MoveEventToast_Preview.texture:SetColorTexture(1, 1, 0, 0.5)

-- login and persist through sessions functionality
local function MoveEventToast_loaded(self, event, arg1)
	if event == "ADDON_LOADED" and arg1 == "Move_Event_Toast" then
		if not Move_Event_Toast then
			MoveEventToast_instructions()
			Move_Event_Toast = {
				x = select(4,EventToastManagerFrame:GetPoint()),
				y = select(5,EventToastManagerFrame:GetPoint()),
				clickthrough = false,
				disable = false,
			}
		end
		Fr_MoveEventToast_Preview:SetPoint(anchorMyselfAt, anchorTo, anchorToAt, Move_Event_Toast.x, Move_Event_Toast.y)
		-- append ourselves into blizzard's function
		hooksecurefunc(EventToastManagerFrame, "DisplayToast", function()
			MoveEventToast_mover()
		end)
	end
end

-- event triggers
local Fr_MoveEventToast = CreateFrame("Frame")
Fr_MoveEventToast:RegisterEvent("ADDON_LOADED")
Fr_MoveEventToast:SetScript("OnEvent", MoveEventToast_loaded)

-- slash command functionality
SLASH_MOVEET1 = "/moveet"
function SlashCmdList.MOVEET(msg, editbox)
	local msgX,msgY = string.match(msg, "^(-?%d+\.?%d?) (-?%d+\.?%d?)$")
	local msgClickthrough = string.match(string.lower(msg), "^clickthrough (yes)$") or string.match(string.lower(msg), "^clickthrough (no)$")
	local msgDisable = string.match(string.lower(msg), "^disable (yes)$") or string.match(string.lower(msg), "^disable (no)$")
	local msgPreview = string.match(string.lower(msg), "^preview$")
	local msgPrint = string.match(string.lower(msg), "^print$")
	if msgX and msgY then
		msgX = tonumber(msgX)
		msgY = tonumber(msgY)
		Move_Event_Toast.x,Move_Event_Toast.y = msgX,msgY
		MoveEventToast_mover()
		Fr_MoveEventToast_Preview:SetPoint(anchorMyselfAt, anchorTo, anchorToAt, Move_Event_Toast.x, Move_Event_Toast.y)
	elseif msgClickthrough then
		if msgClickthrough == "yes" then
			Move_Event_Toast.clickthrough = true
			if not Move_Event_Toast.disable then
				MoveEventToast_clickable(false)
			end
		else
			Move_Event_Toast.clickthrough = false
			if not Move_Event_Toast.disable then
				MoveEventToast_clickable(true)
			end
		end
	elseif msgDisable then
		if msgDisable == "yes" then
			Move_Event_Toast.disable = true
			EventToastManagerFrame:SetAlpha(0)
			MoveEventToast_clickable(false)
		else
			Move_Event_Toast.disable = false
			EventToastManagerFrame:SetAlpha(1)
			if not Move_Event_Toast.clickthrough then
				MoveEventToast_clickable(true)
			end
		end
	elseif msgPreview then
		MoveEventToast_previewing = not MoveEventToast_previewing
		Fr_MoveEventToast_Preview:SetAlpha(1 - Fr_MoveEventToast_Preview:GetAlpha())
	elseif msgPrint then
		print(colorOrange .. "Disable: " .. exitColor .. tostring(Move_Event_Toast.disable))
		print(colorOrange .. "Clickthrough: " .. exitColor .. tostring(Move_Event_Toast.clickthrough))
		print(colorOrange .. "Coords: " .. exitColor .. "x=" .. tostring(Move_Event_Toast.x) .. ", y=" .. tostring(Move_Event_Toast.y))
	else
		print(colorRed .. "Incorrect use of" .. exitColor .. " /moveet")
		MoveEventToast_instructions()
	end
end