return function(ctx)
local Players, State = ctx.Players, ctx.State
local AntiAfk = { conn = nil, attrConn = nil, prevAttr = nil, savedAttr = false }

local function antiAfkClick()
	pcall(function()
		local VirtualUser = game:GetService("VirtualUser")
		local camera = workspace.CurrentCamera
		local cf = camera and camera.CFrame or CFrame.new()
		VirtualUser:CaptureController()
		VirtualUser:Button2Down(Vector2.new(0, 0), cf)
		task.wait(0.5)
		VirtualUser:Button2Up(Vector2.new(0, 0), cf)
	end)
end

local function setAntiAfk(enabled)
	local lp = Players.LocalPlayer
	if not enabled then
		if AntiAfk.conn then
			AntiAfk.conn:Disconnect()
			AntiAfk.conn = nil
		end
		if AntiAfk.attrConn then
			AntiAfk.attrConn:Disconnect()
			AntiAfk.attrConn = nil
		end
		
		if AntiAfk.savedAttr and lp then
			pcall(function() lp:SetAttribute("AFKRejoinEnabled", AntiAfk.prevAttr) end)
		end
		AntiAfk.savedAttr = false
		return
	end
	if AntiAfk.conn then return end

	if not lp then
		warn("[AutumnDice] Anti AFK unavailable: LocalPlayer not ready")
		State.Features.AntiAfk = false
		return
	end

	pcall(function()
		if not AntiAfk.savedAttr then
			AntiAfk.prevAttr = lp:GetAttribute("AFKRejoinEnabled")
			AntiAfk.savedAttr = true
		end
		lp:SetAttribute("AFKRejoinEnabled", false)
		AntiAfk.attrConn = lp:GetAttributeChangedSignal("AFKRejoinEnabled"):Connect(function()
			if lp:GetAttribute("AFKRejoinEnabled") ~= false then
				lp:SetAttribute("AFKRejoinEnabled", false)
			end
		end)
	end)

	AntiAfk.conn = lp.Idled:Connect(function(timeIdled)
		antiAfkClick()
	end)
end

local function setAutoReconnect(enabled)
	
end

ctx.FeatureHandlers.AntiAfk = setAntiAfk
ctx.FeatureHandlers.AutoReconnect = setAutoReconnect

local addTab, makeCard, makeToggle = ctx.addTab, ctx.makeCard, ctx.makeToggle
local create, THEME, pill = ctx.create, ctx.THEME, ctx.pill
local miscBody = makeCard(addTab(4, "Miscellaneous").left, function(tile)
	for i, w in ipairs({ 14, 9, 12 }) do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 8 + (i - 1) * 5),
			Size = UDim2.fromOffset(w, 2),
			BackgroundColor3 = THEME.accent,
			BorderSizePixel = 0,
			Parent = tile,
		}, { pill() })
	end
end, "Miscellaneous")

makeToggle(miscBody, 1, "Anti AFK", "AntiAfk")
makeToggle(miscBody, 2, "Auto Reconnect", "AutoReconnect")



end