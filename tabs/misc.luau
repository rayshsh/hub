return function(ctx)
local Players, State, player = ctx.Players, ctx.State, ctx.player
local THEME = ctx.THEME
local UserInputService = game:GetService("UserInputService")
local TeleportService = game:GetService("TeleportService")
local env = (getgenv and getgenv()) or _G

-- Hide VirtualInputManager from FindService (installed once, survives reloads)
if not env.RayHubFindServiceHooked and hookfunction and newcclosure then
	local ok = pcall(function()
		local oFS
		oFS = hookfunction(game.FindService, newcclosure(function(self, serviceName)
			if serviceName == "VirtualInputManager" then return nil end
			return oFS(self, serviceName)
		end))
	end)
	if ok then env.RayHubFindServiceHooked = true end
end

-- Safety net: block Teleport calls coming from the game's "AFK" script (installed once)
env.RayHubAfkGuard = env.RayHubAfkGuard or { active = false }
local Guard = env.RayHubAfkGuard
if not Guard.installed and hookmetamethod and newcclosure and getnamecallmethod then
	local ok = pcall(function()
		local oldNamecall
		oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
			if Guard.active and self == TeleportService and getnamecallmethod() == "Teleport"
				and not (checkcaller and checkcaller()) then
				local caller = getcallingscript and getcallingscript()
				if caller and caller.Name == "AFK" then
					return nil
				end
			end
			return oldNamecall(self, ...)
		end))
	end)
	if ok then Guard.installed = true end
end

local AntiAfk = {
	process = nil,
	vim = nil,
	gameScript = nil,
	scriptWasDisabled = nil,
	killedConnections = {},
}

local function disableGameAfk()
	local lp = Players.LocalPlayer
	if not lp then return end

	-- 1) Disable the game's LocalScript "AFK" (StarterPlayerScripts copy)
	pcall(function()
		local scr = lp:FindFirstChild("AFK", true)
		if scr and scr:IsA("LocalScript") then
			if not AntiAfk.gameScript then
				AntiAfk.gameScript = scr
				AntiAfk.scriptWasDisabled = scr.Disabled
			end
			scr.Disabled = true
		end
	end)

	-- 2) Disable any connections it left on the input signals (resets its 1080s timer)
	if getconnections then
		for _, signal in ipairs({ UserInputService.InputBegan, UserInputService.TouchStarted }) do
			pcall(function()
				for _, conn in ipairs(getconnections(signal)) do
					local fn = conn.Function
					if fn then
						local okEnv, fenv = pcall(getfenv, fn)
						local scr = okEnv and type(fenv) == "table" and rawget(fenv, "script")
						if typeof(scr) == "Instance" and scr.Name == "AFK" then
							conn:Disable()
							table.insert(AntiAfk.killedConnections, conn)
						end
					end
				end
			end)
		end
	end

	Guard.active = true
end

local function restoreGameAfk()
	Guard.active = false
	for _, conn in ipairs(AntiAfk.killedConnections) do
		pcall(function() conn:Enable() end)
	end
	AntiAfk.killedConnections = {}
	if AntiAfk.gameScript then
		local scr, was = AntiAfk.gameScript, AntiAfk.scriptWasDisabled
		pcall(function() if scr.Parent then scr.Disabled = was and true or false end end)
		AntiAfk.gameScript, AntiAfk.scriptWasDisabled = nil, nil
	end
end

local function enableAntiAfk()
	if AntiAfk.process then return true end
	local lp = Players.LocalPlayer
	if not lp then return false end

	local ok, vim = pcall(function() return game:GetService("VirtualInputManager") end)
	if not ok or not vim then return false end
	AntiAfk.vim = vim

	disableGameAfk()

	AntiAfk.process = lp.Idled:Connect(function()
		pcall(function()
			vim:SendKeyEvent(true, Enum.KeyCode.Unknown, false, game)
			task.wait()
			vim:SendKeyEvent(false, Enum.KeyCode.Unknown, false, game)
		end)
	end)
	return true
end

local function disableAntiAfk()
	if AntiAfk.process then
		AntiAfk.process:Disconnect()
		AntiAfk.process = nil
	end
	restoreGameAfk()
end

local function setAntiAfk(enabled)
	if not enabled then
		disableAntiAfk()
		return
	end
	if not enableAntiAfk() then
		warn("[RayHub] Anti AFK unavailable (LocalPlayer or VirtualInputManager missing)")
		State.Features.AntiAfk = false
	end
end

local function setAutoReconnect(enabled)
	
end

local AUTO_EXECUTE_URL = "https://raw.githubusercontent.com/rayshsh/hub/refs/heads/main/loader.luau"
local teleportBusy = false

local function runtimeFunction(name)
	local fn = env[name]
	if type(fn) == "function" then return fn end
	fn = _G[name]
	if type(fn) == "function" then return fn end
	local ok, currentEnvironment = pcall(getfenv, 0)
	if ok and type(currentEnvironment) == "table" then
		fn = currentEnvironment[name]
		if type(fn) == "function" then return fn end
	end
	if name == "queue_on_teleport" then
		local available, queue = pcall(function() return queue_on_teleport end)
		if available and type(queue) == "function" then return queue end
	elseif name == "request" then
		local available, requestFn = pcall(function() return request end)
		if available and type(requestFn) == "function" then return requestFn end
	end
	return nil
end

local function setAutoExecute(enabled)
	if not enabled then
		if not ctx.Alive then return end
		env.RayHubAutoExecuteEnabled = false
		return
	end
	env.RayHubAutoExecuteEnabled = true

	local queue = runtimeFunction("queue_on_teleport")
	if not queue then
		env.RayHubAutoExecuteEnabled = false
		State.Features.AutoExecute = false
		warn("[RayHub] Auto Execute unavailable: Real queue_on_teleport is unavailable.")
		ctx.notify()
		return
	end

	local queuedSource = ([=[
local runtimeEnv = (getgenv and getgenv()) or _G
if runtimeEnv.RayHubAutoExecuteEnabled ~= false then
    runtimeEnv.RayHubAutoExecuteEnabled = true
    local sourceOk, source = pcall(function()
        return game:HttpGet(%q)
    end)
    if sourceOk then
        local compileOk, run = pcall(loadstring, source)
        if compileOk and type(run) == "function" then
            local runOk, runError = pcall(run)
            if not runOk then warn("[RayHub] Auto Execute failed: " .. tostring(runError)) end
        else
            warn("[RayHub] Could not compile loader: " .. tostring(run))
        end
    else
        warn("[RayHub] Could not fetch loader: " .. tostring(source))
    end
end
]=]):format(AUTO_EXECUTE_URL)
	local ok, err = pcall(queue, queuedSource)
	if not ok then
		env.RayHubAutoExecuteEnabled = false
		State.Features.AutoExecute = false
		warn("[RayHub] Auto Execute could not queue script: " .. tostring(err))
		ctx.notify()
		return
	end
end

local function rejoin()
	if teleportBusy then return end
	if not player or game.JobId == "" then
		warn("[RayHub] Rejoin unavailable: current server ID is unavailable.")
		return
	end
	teleportBusy = true
	local ok, err = pcall(function()
		TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, player)
	end)
	if not ok then
		teleportBusy = false
		warn("[RayHub] Rejoin failed: " .. tostring(err))
	end
end

local function decodeJson(text)
	local api = env.json or json
	if api and type(api.decode) == "function" then
		local ok, value = pcall(api.decode, text)
		if ok then return value end
	end
	return game:GetService("HttpService"):JSONDecode(text)
end

local function findPublicServer()
	local requestFn = runtimeFunction("request")
	if not requestFn then error("Real request API is unavailable.", 0) end
	local http = game:GetService("HttpService")
	local cursor, candidates = nil, {}
	for _ = 1, 4 do
		local url = string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100%s",
			game.PlaceId,
			cursor and ("&cursor=" .. http:UrlEncode(cursor)) or ""
		)
		local requested, response = pcall(requestFn, { Url = url, Method = "GET" })
		if not requested then error(tostring(response), 0) end
		if type(response) ~= "table" or response.Success ~= true or type(response.Body) ~= "string" then
			error(type(response) == "table" and (response.StatusMessage or response.StatusCode or "Server list request failed") or tostring(response), 0)
		end
		local decoded, data = pcall(decodeJson, response.Body)
		if not decoded or type(data) ~= "table" then error("Could not parse the server list: " .. tostring(data), 0) end
		for _, server in ipairs(data.data or {}) do
			if type(server) == "table" and type(server.id) == "string"
				and server.id ~= game.JobId and type(server.playing) == "number"
				and type(server.maxPlayers) == "number" and server.playing < server.maxPlayers then
				table.insert(candidates, server.id)
			end
		end
		cursor = data.nextPageCursor
		if #candidates > 0 or type(cursor) ~= "string" or cursor == "" then break end
	end
	if #candidates == 0 then error("No other available public server was found.", 0) end
	return candidates[math.random(1, #candidates)]
end

local function serverHop()
	if teleportBusy then return end
	teleportBusy = true
	task.spawn(function()
		local ok, serverId = pcall(findPublicServer)
		if not ok then
			teleportBusy = false
			warn("[RayHub] Server hop failed: " .. tostring(serverId))
			return
		end
		local teleported, err = pcall(function()
			TeleportService:TeleportToPlaceInstance(game.PlaceId, serverId, player)
		end)
		if not teleported then
			teleportBusy = false
			warn("[RayHub] Server hop failed: " .. tostring(err))
		end
	end)
end

ctx.FeatureHandlers.AntiAfk = setAntiAfk
ctx.FeatureHandlers.AutoReconnect = setAutoReconnect
ctx.FeatureHandlers.AutoExecute = setAutoExecute

local addTab, makeCard, makeToggle = ctx.addTab, ctx.makeCard, ctx.makeToggle
local create, pill, makeButton = ctx.create, ctx.pill, ctx.makeButton
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
makeToggle(miscBody, 3, "Auto Execute", "AutoExecute")

local teleportRow = create("Frame", {
	LayoutOrder = 4,
	Size = UDim2.new(1, 0, 0, 24),
	BackgroundTransparency = 1,
	Parent = miscBody,
})
local rejoinButton = makeButton({
	Position = UDim2.new(0, 0, 0, 0),
	Size = UDim2.new(0.5, -4, 1, 0),
	Text = "Rejoin",
	Parent = teleportRow,
})
local serverHopButton = makeButton({
	Position = UDim2.new(0.5, 4, 0, 0),
	Size = UDim2.new(0.5, -4, 1, 0),
	Text = "Server Hop",
	Parent = teleportRow,
})
local teleportModal = ctx.makeModal()
local function askTeleportConfirmation(action)
	if teleportBusy then return end
	teleportModal.Show({
		title = "Confirm " .. action,
		message = action == "Rejoin" and "Rejoin this server?" or "Hop to another server?",
		confirmText = action,
		cancelText = "Cancel",
		onConfirm = function()
			if action == "Rejoin" then rejoin() else serverHop() end
		end,
	})
end
rejoinButton.Activated:Connect(function() askTeleportConfirmation("Rejoin") end)
serverHopButton.Activated:Connect(function() askTeleportConfirmation("Server Hop") end)

if State.Features.AutoExecute then setAutoExecute(true) end
table.insert(ctx.connections, TeleportService.TeleportInitFailed:Connect(function(failedPlayer, _, errorMessage)
	if failedPlayer == player then
		teleportBusy = false
		warn("[RayHub] Teleport failed: " .. tostring(errorMessage))
	end
end))

end
