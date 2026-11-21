return function(ctx)
local Players, ReplicatedStorage, player = ctx.Players, ctx.ReplicatedStorage, ctx.player
local State, CONFIG, AutumnTravel = ctx.State, ctx.CONFIG, ctx.AutumnTravel
local AutoBuy = ctx.AutoBuy or {}
ctx.AutoBuy = AutoBuy
local makeCard, makeToggle, makeDropdown, makeLine = ctx.makeCard, ctx.makeToggle, ctx.makeDropdown, ctx.makeLine
local create, corner, stroke, pill, vlist, THEME = ctx.create, ctx.corner, ctx.stroke, ctx.pill, ctx.vlist, ctx.THEME
local pad = ctx.pad
local addTab, gui, connections, refreshers = ctx.addTab, ctx.gui, ctx.connections, ctx.refreshers
local getHRP, getRemote, invoke = ctx.getHRP, ctx.getRemote, ctx.invoke
local SetFeature, GetFeature, formatNumber = ctx.SetFeature, ctx.GetFeature, ctx.formatNumber
local BLUE, GREEN, YELLOW, ORANGE, GRAY, RED = ctx.BLUE, ctx.GREEN, ctx.YELLOW, ctx.ORANGE, ctx.GRAY, ctx.RED
local setAutoClaim
local AutoRoll = ctx.AutoRoll or {}
ctx.AutoRoll = AutoRoll
local pathString = ctx.pathString
local DEFAULT_DETAIL = {
 Idle = "Enable \"Auto Roll Autumn Dice\" to start.",
 Initializing = "Preparing Autumn Dice automation.",
 Teleporting = "Traveling to Autumn World.",
 Syncing = "Synchronizing player data.",
 Moving = "Traveling to the Dice Location.",
 Rolling = "Rolling Autumn Dice.",
 AutoRollEnabled = "The custom rolling loop is active.",
 AutoRollDisabled = "The rolling loop has stopped.",
 Error = "An issue occurred while attempting to roll.",
}
local function SetStatus(key, detail)
 State.Status = key
 State.Detail = detail or DEFAULT_DETAIL[key] or ""
 ctx.notify()
end
ctx.SetStatus = SetStatus
local runId, workerActive = 0, false
local function alive(id)
	return runId == id and State.Features.AutoDice
end

local function rollPriorityAllows()
	return not AutumnTravel.questRequested and not AutumnTravel.autoQuestMoving and not AutumnTravel.autoQuestRequested and not AutumnTravel.buyRequested
end

local function sleep(id, seconds)
	local t0 = os.clock()
	while os.clock() - t0 < seconds do
		if not alive(id) or not rollPriorityAllows() then return false end
		task.wait(0.05)
	end
	return alive(id) and rollPriorityAllows()
end

local function failAndStop(id, message)
	warn("[AutumnDice] " .. message)
	if runId == id then
		State.Features.AutoDice = false
		runId += 1
		SetStatus("Error", message)
	end
	return false
end

local function acquireRollMovement(id, owner)
	while alive(id) do
		if AutumnTravel.questRequested or AutumnTravel.autoQuestMoving or AutumnTravel.autoQuestRequested or AutumnTravel.buyRequested then
			AutumnTravel.release(owner)
			task.wait(0.05)
		elseif AutumnTravel.acquire(owner, function() return alive(id) and rollPriorityAllows() end) then
			if not AutumnTravel.questRequested and not AutumnTravel.autoQuestMoving and not AutumnTravel.autoQuestRequested and not AutumnTravel.buyRequested then
				return true
			end
			AutumnTravel.release(owner)
		else
			task.wait(0.05)
		end
	end
	return false
end

local function runSetup(id, owner)
	SetStatus("Initializing")
	local paths = {
		sync = { "Network", "AppleService", "RF", "Sync" },
		roll = { "Network", "LeafDiceService", "RF", "Roll" },
	}
	local remotes = {}
	for key, path in pairs(paths) do
		remotes[key] = getRemote(path, CONFIG.RemoteWaitTimeout, function() return alive(id) and rollPriorityAllows() end)
		if not alive(id) or not rollPriorityAllows() then return nil end
		if not remotes[key] then
			return failAndStop(id, "Remote not found: " .. pathString(path)) and nil
		end
	end
	if not sleep(id, CONFIG.StepDelay) then return nil end

	SetStatus("Teleporting")
	local traveled, travelErr = AutumnTravel.ensureInAutumnWorld(function() return alive(id) and rollPriorityAllows() end)
	if not alive(id) or not rollPriorityAllows() then return nil end
	if not traveled then
		return failAndStop(id, travelErr or "Travel failed.") and nil
	end
	if not sleep(id, CONFIG.TeleportSettle) then return nil end

	if not rollPriorityAllows() then return nil end
	SetStatus("Syncing")
	local ok, res = invoke(remotes.sync)
	if not alive(id) or not rollPriorityAllows() then return nil end
	if not ok or res == false then
		return failAndStop(id, "Sync failed: " .. tostring(res)) and nil
	end
	if not sleep(id, CONFIG.StepDelay) then return nil end

	local moved, err = false, nil
	while alive(id) do
		if not acquireRollMovement(id, owner) then return nil end
		SetStatus("Moving")
		moved, err = AutumnTravel.pivotToZone("LeafDice", function()
			return alive(id) and not AutumnTravel.questRequested and not AutumnTravel.autoQuestMoving and not AutumnTravel.autoQuestRequested and not AutumnTravel.buyRequested
		end, 10, Vector3.new(12, 0, 0))
		if moved then break end

		AutumnTravel.release(owner)
		if not alive(id) then return nil end
		if not AutumnTravel.questRequested and not AutumnTravel.autoQuestMoving and not AutumnTravel.autoQuestRequested and not AutumnTravel.buyRequested then
			return failAndStop(id, err or "Movement failed.") and nil
		end
		task.wait(0.05)
	end
	if not moved or not alive(id) then return nil end
	if not sleep(id, CONFIG.StepDelay) then return nil end

	return remotes.roll
end

local function isAtLeafDice()
	return AutumnTravel.isNearZone("LeafDice", 10)
end

local function poolRollResults(results)
	for _, entry in ipairs(results) do
		if type(entry) == "table" and entry.result ~= nil and not entry.autoSold then
			local unitId = tostring(entry.result)
			local counts = State.RollResultPool[unitId]
			if not counts then
				counts = { total = 0 }
				State.RollResultPool[unitId] = counts
			end
			counts.total += 1

		end
	end
end
local function rollLoop(id, rollRemote)
	local consecutiveErrors = 0
	State.Rolls = 0

	while alive(id) do
		if AutumnTravel.questRequested or AutumnTravel.autoQuestMoving or AutumnTravel.autoQuestRequested or AutumnTravel.buyRequested then
			task.wait(0.1)
		else
			local owner = {}
			if AutumnTravel.acquire(owner, function() return alive(id) and rollPriorityAllows() end) then
				if not alive(id) then
					AutumnTravel.release(owner)
					return
				end

				local moved, err = true, nil
				if not isAtLeafDice() then
					SetStatus("Moving", "Returning to the LeafDice zone before rolling.")
					moved, err = AutumnTravel.pivotToZone("LeafDice", function() return alive(id) and not AutumnTravel.questRequested and not AutumnTravel.autoQuestMoving and not AutumnTravel.autoQuestRequested and not AutumnTravel.buyRequested end, 10, Vector3.new(12, 0, 0))
				end
				if not moved or not isAtLeafDice() then
					AutumnTravel.release(owner)
					if not AutumnTravel.questRequested and not AutumnTravel.autoQuestMoving and not AutumnTravel.autoQuestRequested and not AutumnTravel.buyRequested then
						if alive(id) then failAndStop(id, err or "Could not verify arrival at LeafDice.") end
						return
					end
				end

				if AutumnTravel.questRequested or AutumnTravel.autoQuestMoving or AutumnTravel.autoQuestRequested or AutumnTravel.buyRequested or not alive(id) then
					AutumnTravel.release(owner)
				else
					SetStatus("Rolling", ("Rolling Autumn Dice. Rolls completed: %d"):format(State.Rolls))
					local called, ok, result = pcall(invoke, rollRemote, CONFIG.RollAmount)
					AutumnTravel.release(owner)
					if not called then ok, result = false, ok end
					if not alive(id) then return end

					if ok and type(result) == "table" then
						local rolledCount = math.max(#result, 1)
						consecutiveErrors = 0
						poolRollResults(result)
						State.Rolls += rolledCount
						SetStatus("AutoRollEnabled", ("The custom rolling loop is active. Rolls completed: %d"):format(State.Rolls))
						if not sleep(id, CONFIG.RollDelay) then return end
					elseif ok then
						local reason = result == nil and "rejected by server" or ("rejected by server: " .. tostring(result))
						SetStatus("Error", reason .. " (not counted toward MaxRollErrors)")
						if not sleep(id, CONFIG.RollErrorDelay) then return end
					else
						consecutiveErrors += 1
						local msg = ("Roll failed (%d/%d): %s"):format(consecutiveErrors, CONFIG.MaxRollErrors, tostring(result))
						warn("[AutumnDice] " .. msg)
						if consecutiveErrors >= CONFIG.MaxRollErrors then
							failAndStop(id, msg .. " Auto Roll stopped.")
							return
						end
						SetStatus("Error", msg)
						if not sleep(id, CONFIG.RollErrorDelay) then return end
					end
				end
			else
				task.wait(0.1)
			end
		end
	end
end

local function worker(id)
	while workerActive and alive(id) do task.wait(0.05) end
	if not alive(id) then return end

	workerActive = true
	while alive(id) do
		while alive(id) and not rollPriorityAllows() do task.wait(0.05) end
		if not alive(id) then break end

		local owner = {}
		local locked = AutumnTravel.acquire(owner, function()
			return alive(id) and rollPriorityAllows()
		end)

		if locked then
			local ok, rollRemote = pcall(runSetup, id, owner)
			AutumnTravel.release(owner)
			if not ok then
				failAndStop(id, "Unexpected error: " .. tostring(rollRemote))
			elseif rollRemote and alive(id) then
				AutumnTravel.rollRemote = rollRemote
				rollLoop(id, rollRemote)
			end
		else
			task.wait(0.05)
		end
	end
	workerActive = false
end
AutoRoll.setEnabled = function(enabled)
	runId += 1
	if enabled then
		local id = runId
		SetStatus("Initializing")
		task.spawn(worker, id)
	else
		SetStatus("AutoRollDisabled")
	end
end
AutoRoll.stop = function()
	runId += 1
end
local function questIcon(tile)
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -3),
		Size = UDim2.fromOffset(3, 10),
		BackgroundColor3 = THEME.accent,
		BorderSizePixel = 0,
		Parent = tile,
	}, { pill() })
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 7),
		Size = UDim2.fromOffset(3, 3),
		BackgroundColor3 = THEME.accent,
		BorderSizePixel = 0,
		Parent = tile,
	}, { pill() })
end

local eventTab = addTab(1, "Event")
ctx.EventTab = eventTab
local questBody = makeCard(eventTab.right, questIcon, "Quest")
makeToggle(questBody, 1, "Auto Claim Quest", "AutoClaimQuest")
makeToggle(questBody, 2, "Auto Quest", "AutoQuest")
local autoQuestStatusLabel = makeLine(questBody, 3, 11, THEME.subtext)
autoQuestStatusLabel.Text = "Auto Quest is disabled."
local questList = create("Frame", {
	LayoutOrder = 4,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Parent = questBody,
}, { vlist(4) })

local Quests = { loaded = false, hooked = {}, hooks = {}, signature = nil, dirty = true }

local QUEST_STATUS = {
	progress = { text = "In Progress", color = THEME.accent },
	complete = { text = "Complete", color = Color3.fromRGB(88, 204, 128) },
	claimed = { text = "Claimed", color = THEME.subtext },
}

local function loadQuestModules()
	if Quests.loaded then return true end
	local ok = pcall(function()
		local features = ReplicatedStorage.Framework.Features
		Quests.DataController = require(features.Data.DataController)
		Quests.Config = require(features.Autumn.AutumnQuestConfig)
	end)
	if not ok or not Quests.DataController or not Quests.Config then
		Quests.DataController, Quests.Config = nil, nil
		return false
	end
	Quests.loaded = true
	return true
end

local function readQuestSections()
	if not Quests.loaded then
		return { { title = "Quests", quests = {}, message = "Waiting for the game's quest data..." } }
	end

	local sections = {}
	pcall(function()
		for _, period in Quests.Config.Periods do
			local title = tostring(period.title or period.dataKey)
			local section = { title = title, quests = {}, bonusClaimed = false }

			local okState, state = pcall(function() return Quests.DataController[period.dataKey]() end)
			if okState and type(state) == "table" and type(state.quests) == "table" and #state.quests > 0 then
				local progressMap = type(state.progress) == "table" and state.progress or {}
				local claimedMap = type(state.claimed) == "table" and state.claimed or {}

				for _, questId in ipairs(state.quests) do
					local okQ, quest = pcall(Quests.Config.GetQuest, questId)
					if okQ and type(quest) == "table" then
						local target = type(quest.target) == "number" and math.max(quest.target, 0) or 0
						local progress = progressMap[questId]
						progress = type(progress) == "number" and math.clamp(progress, 0, target) or 0
						local claimed = claimedMap[questId] == true
						table.insert(section.quests, {
							id = tostring(quest.id or questId),
							title = tostring(quest.title or questId),
							progress = progress,
							target = target,
							status = claimed and "claimed" or (progress >= target and "complete" or "progress"),
						})
					end
				end
				section.bonusClaimed = state.bonusClaimed == true
			end

			if #section.quests == 0 then
				section.message = "No " .. title .. " quests yet (still syncing or none rolled)"
			end
			table.insert(sections, section)
		end
	end)

	if #sections == 0 then
		sections = { { title = "Quests", quests = {}, message = "No quest periods found." } }
	end
	return sections
end

local function questSignature(sections)
	local parts = {}
	for _, sec in ipairs(sections) do
		table.insert(parts, ("%s|%s|%s"):format(sec.title, sec.message or "", tostring(sec.bonusClaimed)))
		for _, q in ipairs(sec.quests) do
			table.insert(parts, ("%s:%s:%s:%s:%s"):format(q.id, q.title, tostring(q.progress), tostring(q.target), q.status))
		end
	end
	return table.concat(parts, "\n")
end

local function buildQuestRow(parent, order, q)
	local info = QUEST_STATUS[q.status]
	local row = create("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = THEME.field,
		BorderSizePixel = 0,
		Parent = parent,
	}, { corner(6), pad(8, 6, 8, 6), vlist(4) })

	local statusText = info.text
	if q.status == "progress" then
		statusText = formatNumber(q.progress) .. "/" .. formatNumber(q.target)
	elseif q.status == "claimed" then
		statusText = "CLAIMED"
	end

	local top = create("Frame", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Parent = row,
	})
	create("TextLabel", {
		Size = UDim2.new(1, -72, 1, 0),
		BackgroundTransparency = 1,
		Text = q.title,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = THEME.text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = top,
	})
	create("TextLabel", {
		Size = UDim2.new(0, 70, 1, 0),
		Position = UDim2.new(1, -70, 0, 0),
		BackgroundTransparency = 1,
		Text = statusText,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = info.color,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = top,
	})

	local track = create("Frame", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 4),
		BackgroundColor3 = THEME.bg,
		BorderSizePixel = 0,
		Parent = row,
	}, { pill() })
	local ratio = q.target > 0 and (q.progress / q.target) or 1
	create("Frame", {
		Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1),
		BackgroundColor3 = info.color,
		BorderSizePixel = 0,
		Parent = track,
	}, { pill() })
end

local function renderQuests()
	local sections = readQuestSections()
	local signature = questSignature(sections)
	if signature == Quests.signature then return end
	Quests.signature = signature

	for _, child in ipairs(questList:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end

	for i, sec in ipairs(sections) do
		local block = create("Frame", {
			LayoutOrder = i,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = questList,
		}, { vlist(4) })

		makeLine(block, 1, 12, THEME.text, Enum.Font.GothamBold).Text = sec.title
		if sec.message then
			makeLine(block, 2, 11, THEME.subtext).Text = sec.message
		end
		for j, q in ipairs(sec.quests) do
			buildQuestRow(block, 10 + j, q)
		end
		if #sec.quests > 0 then
			makeLine(block, 100, 11, THEME.subtext).Text = "Bonus claimed: " .. (sec.bonusClaimed and "Yes" or "No")
		end
	end
end

local function scheduleQuestRender()
	Quests.dirty = true
end

local function hookQuestChanges()
	if not Quests.loaded then return end
	for _, period in Quests.Config.Periods do
		local key = period.id or period.dataKey
		if not Quests.hooked[key] then
			local ok, conn = pcall(function()
				return Quests.DataController[period.dataKey].Changed(scheduleQuestRender)
			end)
			if ok then
				Quests.hooked[key] = true
				if conn ~= nil then table.insert(Quests.hooks, conn) end
			end
		end
	end
end
local function unhookQuests()
	for _, conn in ipairs(Quests.hooks) do
		pcall(function()
			if typeof(conn) == "RBXScriptConnection" then
				conn:Disconnect()
			elseif type(conn) == "table" and type(conn.Disconnect) == "function" then
				conn:Disconnect()
			elseif type(conn) == "function" then
				conn()
			end
		end)
	end
	Quests.hooks = {}
	Quests.hooked = {}
end

local AutoClaim = {
	loaded = false,
	token = 0,
	workerActive = false,
	claimInFlight = false,
	lastAttempt = {},
	lastSyncAttempt = 0,
}

local function loadAutoClaimModules()
	if AutoClaim.loaded then return true end
	if not loadQuestModules() then return false end

	local ok = pcall(function()
		local features = ReplicatedStorage.Framework.Features
		local Network = require(ReplicatedStorage.Packages.Network)
		local questComm = Network.ClientComm.new(ReplicatedStorage.Network, false, "AutumnQuestService")
		AutoClaim.AutumnConfig = require(features.Autumn.AutumnConfig)
		AutoClaim.claimQuest = questComm:GetFunction("Claim")
		AutoClaim.claimBonus = questComm:GetFunction("ClaimBonus")
		AutoClaim.sync = questComm:GetFunction("Sync")
	end)
	AutoClaim.loaded = ok
	return ok
end
local function autoClaimEnabled(token)
	return AutoClaim.token == token and State.Features.AutoClaimQuest
end

local function autoClaimActive(token)
	return autoClaimEnabled(token) and AutoClaim.AutumnConfig.ACTIVE == true and not AutumnTravel.buyRequested and not AutumnTravel.autoQuestRequested
end

local function isAtQuestBoard()
	local zone = AutumnTravel.findZone("AutumnQuests")
	local root = getHRP()
	return zone ~= nil and root ~= nil and (root.Position - zone:GetPivot().Position).Magnitude < 8
end

local function ensureQuestBoard(token)
	local shouldContinue = function() return autoClaimActive(token) end
	local arrived, err = AutumnTravel.ensureInAutumnWorld(shouldContinue)
	if not arrived then return false, err end
	return AutumnTravel.pivotToZone("AutumnQuests", shouldContinue)
end
local function readClaimState(period)
	local ok, raw = pcall(Quests.DataController[period.dataKey])
	if not ok or type(raw) ~= "table" or type(raw.quests) ~= "table" then return nil end
	return {
		quests = raw.quests,
		progress = type(raw.progress) == "table" and raw.progress or {},
		claimed = type(raw.claimed) == "table" and raw.claimed or {},
		bonusClaimed = raw.bonusClaimed == true,
	}
end

local function requestQuestClaim(token, key, callback, argument)
	if not autoClaimActive(token) or not AutumnTravel.isInAutumnWorld() or not isAtQuestBoard() then return false end
	local now = os.clock()
	if AutoClaim.claimInFlight or now - (AutoClaim.lastAttempt[key] or -math.huge) < 5 then return false end
	AutoClaim.claimInFlight = true
	local ok, result = pcall(callback, argument)
	AutoClaim.claimInFlight = false
	AutoClaim.lastAttempt[key] = os.clock()
	return ok and result ~= false
end

local function autoClaimPeriod(token, period)
	local state = readClaimState(period)
	if not state or #state.quests == 0 then return end

	for _, questId in state.quests do
		if not autoClaimActive(token) or not isAtQuestBoard() then return end
		if state.claimed[questId] ~= true then
			local ok, quest = pcall(Quests.Config.GetQuest, questId)
			local progress = state.progress[questId]
			progress = type(progress) == "number" and math.max(progress, 0) or 0
			if ok and type(quest) == "table" and type(quest.target) == "number" and progress >= quest.target then
				requestQuestClaim(token, "quest:" .. tostring(period.id) .. ":" .. tostring(questId), AutoClaim.claimQuest, questId)
			end
		end
	end

	state = readClaimState(period)
	if not state or state.bonusClaimed then return end
	for _, questId in state.quests do
		if state.claimed[questId] ~= true then return end
	end
	requestQuestClaim(token, "bonus:" .. tostring(period.id), AutoClaim.claimBonus, period.id)
end

local function hasClaimableQuest()
	for _, period in Quests.Config.Periods do
		local state = readClaimState(period)
		if state then
			local allClaimed = #state.quests > 0
			for _, questId in state.quests do
				if state.claimed[questId] ~= true then
					allClaimed = false
					local ok, quest = pcall(Quests.Config.GetQuest, questId)
					local progress = state.progress[questId]
					if ok and type(quest) == "table" and type(quest.target) == "number" and type(progress) == "number" and progress >= quest.target then
						return true
					end
				end
			end
			if allClaimed and not state.bonusClaimed then return true end
		end
	end
	return false
end

local function autoClaimWorker(token)
	while AutoClaim.workerActive and autoClaimEnabled(token) do task.wait(0.1) end
	if not autoClaimEnabled(token) then return end
	AutoClaim.workerActive = true
	local lastCharacter, needsSync = nil, true

	while autoClaimEnabled(token) do
		if not loadAutoClaimModules() then
			task.wait(1)
		elseif not autoClaimActive(token) then
			task.wait(1)
		else
			if player.Character ~= lastCharacter then
				lastCharacter = player.Character
				needsSync = true
			end

			if not hasClaimableQuest() then
				task.wait(1)
			else
				local owner = {}
				AutumnTravel.questRequested = true
				if AutumnTravel.acquire(owner, function() return autoClaimActive(token) end) then
					local ok, err = pcall(function()
						if not AutumnTravel.isInAutumnWorld() or not isAtQuestBoard() then
							needsSync = true
							local arrived, travelErr = ensureQuestBoard(token)
							if not arrived then error(travelErr or "Could not reach Quest Board.") end
						end
						if not autoClaimActive(token) or not isAtQuestBoard() then return end

						if needsSync and os.clock() - AutoClaim.lastSyncAttempt >= 3 then
							AutoClaim.lastSyncAttempt = os.clock()
							local synced, result = pcall(AutoClaim.sync)
							if synced and result ~= false then
								needsSync = false
								task.wait(1)
							end
						end
						if not needsSync then
							for _, period in Quests.Config.Periods do
								if not autoClaimActive(token) or not isAtQuestBoard() then break end
								pcall(autoClaimPeriod, token, period)
							end
						end

						if State.Features.AutoDice and autoClaimActive(token) then
							local returned, returnErr = AutumnTravel.pivotToZone("LeafDice", function() return autoClaimActive(token) end, 10)
							if not returned or not isAtLeafDice() then error(returnErr or "Could not verify return to LeafDice.") end
						end
					end)
					AutumnTravel.release(owner)
					AutumnTravel.questRequested = false
					if not ok then task.wait(1) end
				else
					AutumnTravel.questRequested = false
				end
				task.wait(1)
			end
		end
	end

	AutoClaim.workerActive = false
end
setAutoClaim = function(enabled)
	AutoClaim.token += 1
	
end

task.spawn(function()
	while gui.Parent do
		if State.Features.AutoClaimQuest then
			local ok = pcall(autoClaimWorker, AutoClaim.token)
			AutoClaim.workerActive = false
			if not ok then task.wait(1) end
		else
			task.wait(0.1)
		end
	end
end)

AutoBuy.token = 0
AutoBuy.workerActive = false
AutoBuy.loaded = false
AutoBuy.built = false
AutoBuy.stockKey = nil
AutoBuy.DataController = nil
AutoBuy.dataHooks = {}
AutoBuy.hooked = {}
AutoBuy.offers = {}
AutoBuy.rows = {}       
AutoBuy.selected = {}   
AutoBuy.status = "Off"
AutoBuy.passDelay = 2  
AutoBuy.idleDelay = 10  

function AutoBuy.alive(token)
	return AutoBuy.token == token and State.Features.AutoBuy
end

function AutoBuy.sleep(token, seconds)
	local t0 = os.clock()
	while os.clock() - t0 < seconds do
		if not AutoBuy.alive(token) then return false end
		task.wait(0.1)
	end
	return AutoBuy.alive(token)
end

function AutoBuy.selectedCount()
	local n = 0
	for _ in pairs(AutoBuy.selected) do n += 1 end
	return n
end

function AutoBuy.loadModules()
	if AutoBuy.loaded then return true end
	local ok, err = pcall(function()
		local features = ReplicatedStorage.Framework.Features
		local Network = require(ReplicatedStorage.Packages.Network)
		AutoBuy.Config = require(features.Autumn.AppleShopConfig)
		AutoBuy.DataController = require(features.Data.DataController)
		AutoBuy.buy = Network.ClientComm.new(ReplicatedStorage.Network, false, "AppleShopService"):GetFunction("Buy")
	end)
	if not ok then
		AutoBuy.loadError = tostring(err)
		return false
	end
	AutoBuy.loadError = nil
	AutoBuy.loaded = true
	AutoBuy.hookData()
	return true
end

function AutoBuy.setStatus(text)
	AutoBuy.status = text
	AutoBuy.refresh()
end

function AutoBuy.refresh()
	local line = AutoBuy.statusLine
	if not line then return end
	local text = AutoBuy.status
	pcall(function()
		if line.Text ~= text then line.Text = text end
	end)
end

local function getOfferLimit(offer)
    local spec = offer.limit
    local period = offer.limitPeriod or offer.limitType or offer.reset or offer.period
    if type(spec) == "table" then
        period = spec.period or spec.reset or period
        if spec.daily ~= nil then
            spec, period = spec.daily, "daily"
        elseif spec.total ~= nil then
            spec, period = spec.total, "total"
        else
            spec = spec.amount or spec.count or spec.max or spec.limit
        end
    end
    return tonumber(spec), tostring(period or ""):lower()
end

local function getBought(offer)
    local ok, count = pcall(function()
        local autumn = AutoBuy.DataController.Autumn
        local day = autumn.ShopDay()
        local purchases = autumn.ShopPurchases()
        if type(purchases) ~= "table" then return 0 end

        local _, period = getOfferLimit(offer)
        local isTotal = period:find("total", 1, true) or period:find("lifetime", 1, true)
        local counts = purchases
        if not isTotal and day ~= nil then
            local today = purchases[day] or purchases[tostring(day)]
            if type(today) == "table" then counts = today end
        end

        local bought = counts[offer.id]
        if type(bought) == "table" then
            local recordDay = bought.day or bought.shopDay
            if not isTotal and recordDay ~= nil and day ~= nil and recordDay ~= day then return 0 end
            if isTotal then
                bought = bought.total or bought.count or bought.amount
            else
                bought = bought.today or bought.daily or bought.count or bought.amount or bought.total
            end
        end
        return tonumber(bought) or 0
    end)
    return ok and count or 0
end

local function isSoldOut(offer, boughtOverride)
    local limit = getOfferLimit(offer)
    local bought = getBought(offer)
    if boughtOverride ~= nil then bought = math.max(bought, boughtOverride) end
    return limit ~= nil and bought >= limit
end

local function offerOption(offer)
    local parts = { offer.id }
    local limit, period = getOfferLimit(offer)
    local bought = limit ~= nil and getBought(offer) or 0
    local soldOut = limit ~= nil and bought >= limit
    if limit ~= nil then
        local suffix = (period:find("day", 1, true) or period == "daily") and " today" or ""
        table.insert(parts, ("%d/%d%s"):format(bought, limit, suffix))
    end

    return { key = offer.id, label = table.concat(parts, "  ·  "), color = soldOut and RED or nil }
end

local function uniqueOffers(offers)
    local unique, seen = {}, {}
    for _, offer in offers do
        if type(offer) == "table" and type(offer.id) == "string" then
            local key = string.lower(string.match(offer.id, "^%s*(.-)%s*$"))
            if key ~= "" and not seen[key] then
                seen[key] = true
                table.insert(unique, offer)
            end
        end
    end
    return unique
end
function AutoBuy.refreshOptions()
	if not ctx.Alive or not AutoBuy.built or not AutoBuy.dropdown then return end

	local offers = AutoBuy.Config and AutoBuy.Config.Offers
	AutoBuy.offers = uniqueOffers(type(offers) == "table" and offers or AutoBuy.offers)

	local options, signature = {}, {}
	for _, offer in ipairs(AutoBuy.offers) do
		table.insert(options, offerOption(offer))
		table.insert(signature, offer.id .. ":" .. tostring(getBought(offer)))
	end

	local key = table.concat(signature, "|")
	if key == AutoBuy.stockKey then return end
	if not ctx.Alive then return end
	local ok, err = pcall(AutoBuy.dropdown.SetOptions, options)
	if not ok then
		warn("[Auto Buy] Dropdown refresh failed: " .. tostring(err))
		return
	end
	AutoBuy.stockKey = key
end

local refreshQueued = false
AutoBuy.refreshEvent = Instance.new("BindableEvent")
table.insert(connections, AutoBuy.refreshEvent.Event:Connect(function()
	refreshQueued = false
	if not ctx.Alive then return end
	AutoBuy.refreshOptions()
end))

function AutoBuy.queueRefreshOptions()
	if not ctx.Alive or refreshQueued then return end
	refreshQueued = true
	AutoBuy.refreshEvent:Fire()
end
function AutoBuy.hookData()
    if not AutoBuy.DataController then return end
    local autumn = AutoBuy.DataController.Autumn
    for _, name in ipairs({ "ShopPurchases", "ShopDay" }) do
        if not AutoBuy.hooked[name] then
            local ok, conn = pcall(function()
                return autumn[name].Changed(AutoBuy.queueRefreshOptions)
            end)
            if ok then
                AutoBuy.hooked[name] = true
                if conn then table.insert(AutoBuy.dataHooks, conn) end
            end
        end
    end
end

function AutoBuy.build()
	if AutoBuy.built or not AutoBuy.loadModules() then return end

	local offers = AutoBuy.Config.Offers
	if type(offers) ~= "table" then return end

	AutoBuy.offers = uniqueOffers(offers)
	AutoBuy.built = true
	AutoBuy.hookData()
	AutoBuy.queueRefreshOptions()
	AutoBuy.refresh()
end

function AutoBuy.runPass(token)
    local offers = {}
    local selectedCount, soldOutCount = 0, 0
    for _, offer in ipairs(AutoBuy.offers) do
        if AutoBuy.selected[offer.id] then
            selectedCount += 1
            if isSoldOut(offer) then
                soldOutCount += 1
            else
                table.insert(offers, offer)
            end
        end
    end
    if #offers == 0 then return false, selectedCount > 0 and soldOutCount == selectedCount end

    AutoBuy.setStatus("Taking control of the character")
    AutumnTravel.buyRequested = true

    local owner = {}
    if not AutumnTravel.acquire(owner, function() return AutoBuy.alive(token) end) then
        AutumnTravel.buyRequested = false
        return false, false
    end

    local bought = false
    local ok, err = pcall(function()
        local keepGoing = function() return AutoBuy.alive(token) end

        AutoBuy.setStatus("Moving to the Apple Shop")
        local arrived, travelErr = AutumnTravel.ensureInAutumnWorld(keepGoing)
        if not arrived then error(travelErr or "Could not enter Autumn World.", 0) end
        local moved, moveErr = AutumnTravel.pivotToZone(AutoBuy.Config.ZONE, keepGoing, 6)
        if not moved then error(moveErr or "Could not reach the Apple Shop.", 0) end
        task.wait(0.2)

        AutoBuy.setStatus("Buying")
        for _, offer in ipairs(offers) do
            local boughtCount = getBought(offer)
            while keepGoing() and AutoBuy.selected[offer.id] and not isSoldOut(offer, boughtCount) do
                local okBuy, result = pcall(AutoBuy.buy, offer.id)
                if not okBuy or not result then break end
                bought = true
                boughtCount = math.max(boughtCount + 1, getBought(offer))

                if not AutoBuy.selected[offer.id] or not keepGoing() or isSoldOut(offer, boughtCount) then break end
                task.wait((AutoBuy.Config.REQUEST_DEBOUNCE or 0.5) + 0.1)
            end
        end
    end)

    AutumnTravel.release(owner)
    AutumnTravel.buyRequested = false

    if not ok and AutoBuy.alive(token) then
        warn("[AutumnDice] Auto Buy: " .. tostring(err))
        AutoBuy.setStatus("Error: " .. tostring(err))
    end
    return bought, false
end
function AutoBuy.worker(token)
	while AutoBuy.workerActive and AutoBuy.alive(token) do task.wait(0.1) end
	if not AutoBuy.alive(token) then return end

	AutoBuy.workerActive = true
	while AutoBuy.alive(token) do
		if not AutoBuy.loadModules() then
			AutoBuy.setStatus("Waiting for shop data")
			AutoBuy.sleep(token, 1)
		elseif AutoBuy.selectedCount() == 0 then
			AutoBuy.setStatus("Select items to buy")
			AutoBuy.sleep(token, 0.5)
		else
			local okPass, bought, allSoldOut = pcall(AutoBuy.runPass, token)
			if not okPass then
				AutumnTravel.buyRequested = false
				warn("[AutumnDice] Auto Buy error: " .. tostring(bought))
				bought = false
			end
			if AutoBuy.alive(token) then
				AutoBuy.setStatus(bought and "Waiting for the next pass" or allSoldOut and "Selected items at their purchase limits" or "Nothing bought, waiting")
				AutoBuy.sleep(token, bought and AutoBuy.passDelay or AutoBuy.idleDelay)
			end
		end
	end
	AutoBuy.workerActive = false
end

AutoBuy.setEnabled = function(enabled)
	AutoBuy.token += 1
	if enabled then
		AutoBuy.setStatus("Starting")
		task.spawn(AutoBuy.worker, AutoBuy.token)
	else
		AutoBuy.setStatus("Off")
	end
end

do
	local function shopIcon(tile)
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, 3),
			Size = UDim2.fromOffset(14, 11),
			BackgroundColor3 = THEME.accent,
			BorderSizePixel = 0,
			Parent = tile,
		}, { corner(3) })
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0.5, -5),
			Size = UDim2.fromOffset(8, 7),
			BackgroundTransparency = 1,
			Parent = tile,
		}, { corner(3), stroke(THEME.accent, 2) })
	end

	local body = makeCard(eventTab.left, shopIcon, "Apple Shop", 2)
	makeToggle(body, 1, "Auto Buy", "AutoBuy")

	AutoBuy.statusLine = makeLine(body, 2, 11, THEME.subtext)
	AutoBuy.statusLine.Text = "Off"

	AutoBuy.dropdown = makeDropdown(body, 3, {
		label = "Items",
		multi = true,
		searchable = true,
		placeholder = "Select Items...",
		emptyText = "Loading shop items...",
		maxHeight = 180,
		onChange = function() AutoBuy.refresh() end,
	})
	AutoBuy.selected = AutoBuy.dropdown.selected 
end

table.insert(refreshers, AutoBuy.refresh)

task.spawn(function()
	while ctx.Alive and gui.Parent and not AutoBuy.built do
		pcall(AutoBuy.build)
		task.wait(1)
	end
end)

task.spawn(function()
	while ctx.Alive and gui.Parent do
		if AutoBuy.built then
			pcall(AutoBuy.queueRefreshOptions)
		end
		local interval = tonumber(AutoBuy.Config and AutoBuy.Config.STOCK_POLL_INTERVAL) or 5
		task.wait(math.max(1, interval))
	end
end)
task.spawn(function()
	local nextLoadTry, nextHookTry, lastRender = 0, 0, 0
	while gui.Parent do
		local now = os.clock()
		if not Quests.loaded and now >= nextLoadTry and not loadQuestModules() then
			nextLoadTry = now + 1
		end
		if Quests.loaded then
			if now >= nextHookTry then
				hookQuestChanges()
				nextHookTry = now + 3
			end
			if Quests.dirty or now - lastRender >= 3 then
				Quests.dirty = false
				pcall(renderQuests)
				lastRender = now
			end
		end
		task.wait(0.1)
	end
end)

local ReplicatedStorage, State, gui = ctx.ReplicatedStorage, ctx.State, ctx.gui
local makeCard, makeToggle = ctx.makeCard, ctx.makeToggle
local create, makeLine, vlist, THEME = ctx.create, ctx.makeLine, ctx.vlist, ctx.THEME
ctx.Roll = { leafBalanceValue = 0 }
local rollBody = makeCard(ctx.EventTab.left, function(tile)
	create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "🍂",
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		Parent = tile,
	})
end, "Auto Roll")

makeToggle(rollBody, 1, "Auto Roll Autumn Dice", "AutoDice")

local rollInfo = create("Frame", {
	LayoutOrder = 2,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Parent = rollBody,
}, { vlist(4) })

local rollResultsLine = makeLine(rollInfo, 1, 11, THEME.subtext)
rollResultsLine.Text = "Results: None yet"
local rollCount = makeLine(rollInfo, 2, 12, THEME.subtext)
local leafBalance = makeLine(rollInfo, 3, 12, THEME.subtext)
ctx.Roll.leafBalanceValue = 0
local leafBalanceHooked = false
task.spawn(function()
	while gui.Parent and not leafBalanceHooked do
		local ok = pcall(function()
			local features = ReplicatedStorage.Framework.Features
			local DataController = require(features.Data.DataController)
			local AutumnConfig = require(features.Autumn.AutumnConfig)
			local Leaves = AutumnConfig.Currencies.Leaves
			local inventory = DataController.Inventory[Leaves]
			local entry = inventory()
			ctx.Roll.leafBalanceValue = entry and entry.amount or 0
			inventory.Observe(function(entry)
				ctx.Roll.leafBalanceValue = entry and entry.amount or 0
			end)
		end)
		if ok then
			leafBalanceHooked = true
		else
			task.wait(1)
		end
	end
end)


ctx.Roll.rollBody = rollBody
ctx.Roll.rollCount = rollCount
ctx.Roll.leafBalance = leafBalance
ctx.Roll.rollResultsLine = rollResultsLine
local function refreshRollUI()
	local pooledResults = {}
	for unitId, counts in pairs(State.RollResultPool) do table.insert(pooledResults, ("%s x%d"):format(unitId, counts.total)) end
	table.sort(pooledResults)
	rollCount.Text = ("Rolls: %s"):format(formatNumber(State.Rolls))
	leafBalance.Text = ("Leaf Balance: %s"):format(formatNumber(ctx.Roll.leafBalanceValue))
	rollResultsLine.Text = "Results: " .. (#pooledResults > 0 and table.concat(pooledResults, ", ") or "None yet")
end
table.insert(refreshers, refreshRollUI)
task.spawn(function()
	while gui.Parent do
		pcall(refreshRollUI)
		task.wait(0.5)
	end
end)

local function initializeAutoQuest()

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AppleConfig = require(ReplicatedStorage.Framework.Features.Autumn.AppleConfig)
local TurkeyTowers = require(ReplicatedStorage.Framework.Features.Autumn.TurkeyTowers)
local TowerRefs = require(ReplicatedStorage.Framework.Features.Towers.TowerRefs)
local TowerController = require(ReplicatedStorage.Framework.Features.Towers.TowerController)
local DataController = require(ReplicatedStorage.Framework.Features.Data.DataController)
local BuffController = require(ReplicatedStorage.Framework.Features.Buffs.BuffController)
local EntryRegistry = require(ReplicatedStorage.Framework.Features.Inventory.EntryRegistry)
local AutumnConfig = require(ReplicatedStorage.Framework.Features.Autumn.AutumnConfig)
local AutumnQuestConfig = require(ReplicatedStorage.Framework.Features.Autumn.AutumnQuestConfig)
local LeafDice = require(ReplicatedStorage.Framework.Features.Autumn.LeafDice)
local Network = require(ReplicatedStorage.Packages.Network)

local player = Players.LocalPlayer

local buyBoardUpgrade = (Network.ClientComm.new(ReplicatedStorage.Network, false, "AppleService")):GetFunction("BuyUpgrade")
local rollLeafDice = (Network.ClientComm.new(ReplicatedStorage.Network, false, "LeafDiceService")):GetFunction("Roll")

local CONFIG = {
	AUTO_APPLES = true,
	AUTO_BOARD_LEVELS = true,
	AUTO_LEAF_ROLLS = true,    
	AUTO_TOWER_RUN = true,     
	TOWER_PREFERENCE = "Hardest", 
	TOWER_START_COOLDOWN = 6,   
	ArriveDistance = 8,
	BOARD_BUY_COOLDOWN = 10,  
	DICE_RETRY_COOLDOWN = 10, 
	RUN_FLOOR_CHECK = 100, 
}

local OBJECTIVES = {
	APPLES = { apples = true, rareApples = true, combo = true },
	RUSH = { rushApples = true },
	BOARD = { boardLevels = true },
	FLOORS = { floors = true },
	LEAF_ROLLS = { leafRolls = true },
	RUN_FLOOR = { runFloor = true },
}

local enabled = State.Features.AutoQuest
local mainStatus, towerStatus = "Idle", nil
local function refreshStatus()
	autoQuestStatusLabel.Text = enabled and (towerStatus and (towerStatus .. " | " .. mainStatus) or mainStatus) or "Auto Quest is disabled."
end
local function setStatus(status)
	mainStatus = status
	refreshStatus()
end
local function setTowerStatus(status)
	towerStatus = status
	refreshStatus()
end

local function getRolledQuests()
	local rolled = {}

	for _, period in AutumnQuestConfig.Periods do
		local ok, state = pcall(function()
			return DataController[period.dataKey]()
		end)

		if ok and type(state) == "table" and type(state.quests) == "table" then
			local progressMap = type(state.progress) == "table" and state.progress or {}
			local claimedMap = type(state.claimed) == "table" and state.claimed or {}

			for _, questId in state.quests do
				local quest = AutumnQuestConfig.GetQuest(questId)

				if quest and type(quest.target) == "number" then
					local progress = math.clamp(tonumber(progressMap[questId]) or 0, 0, quest.target)

					if claimedMap[questId] ~= true then
						table.insert(rolled, {
							objective = quest.objective,
							target = quest.target,
							progress = progress,
						})
					end
				end
			end
		end
	end

	return rolled
end

local function getRemaining(objectives)
	local best = nil

	for _, quest in getRolledQuests() do
		if objectives[quest.objective] and quest.progress < quest.target then
			local remaining = quest.target - quest.progress
			if not best or remaining < best then
				best = remaining
			end
		end
	end

	return best
end

local function getRushRemaining()
	return getRemaining(OBJECTIVES.RUSH)
end

local function isRushActive()
	local endsAt = workspace:GetAttribute(AppleConfig.Rush.ATTRIBUTE)
	return type(endsAt) == "number" and workspace:GetServerTimeNow() < endsAt
end

local function getCharacterParts()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if humanoid and root and root:IsA("BasePart") then
        return humanoid, root
    end
    return nil, nil
end
local function stopWalking(humanoid)
    if not humanoid then return end
    pcall(function()
        local root = humanoid.RootPart
        if root then humanoid:MoveTo(root.Position) end
        humanoid:Move(Vector3.zero)
    end)
end

local function moveTowards(position, timeout, shouldStop)
    local humanoid = getCharacterParts()
    if not humanoid then return false end

    local started = os.clock()
    humanoid:MoveTo(position)
    while os.clock() - started < timeout do
        task.wait(0.1)
        if shouldStop and shouldStop() then
            stopWalking(humanoid)
            return false
        end

        local _, root = getCharacterParts()
        if root and (root.Position - position).Magnitude <= 4 then return true end
    end
    return false
end

local function getNearestApplePosition(fromPosition)
	local folder = workspace:FindFirstChild("AutumnApples")
	if not folder then
		return nil
	end

	local bestPosition = nil
	local bestDistance = nil

	for _, child in folder:GetChildren() do
		if child:IsA("Model") then
			local ok, position = pcall(function()
				return child:GetPivot().Position
			end)

			if ok and position then
				local distance = (position - fromPosition).Magnitude
				if not bestDistance or distance < bestDistance then
					bestDistance = distance
					bestPosition = position
				end
			end
		end
	end

	return bestPosition
end

local function shouldStopApples()
	if not enabled or AutumnTravel.buyRequested then
		return true
	end

	if isRushActive() and getRushRemaining() then
		return false
	end

	if CONFIG.AUTO_APPLES and getRemaining(OBJECTIVES.APPLES) then
		return false
	end

	return true
end

local function chaseApples()
    while not shouldStopApples() do
        local _, root = getCharacterParts()
        if not root then
            task.wait(0.15)
            continue
        end

        local applePosition = getNearestApplePosition(root.Position)
        if applePosition then
            moveTowards(applePosition, 1, shouldStopApples)
        else
            task.wait(0.15)
        end
    end
end

local function collectApplesActivity()
	if not shouldStopApples() then
		chaseApples()
	end
end

local function interruptibleWait(seconds)
	local t0 = os.clock()
	while os.clock() - t0 < seconds and enabled and not AutumnTravel.buyRequested do
		task.wait(0.1)
	end
end

local function buyBoardLevelsActivity()
	while enabled and not AutumnTravel.buyRequested and CONFIG.AUTO_BOARD_LEVELS and getRemaining(OBJECTIVES.BOARD) do
		local boughtAny = false
		for _, upgrade in AppleConfig.Upgrades do
			if not enabled or AutumnTravel.buyRequested or not getRemaining(OBJECTIVES.BOARD) then
				break
			end

			local ok, bought = pcall(buyBoardUpgrade, upgrade.name, true)
			if ok and bought then
				boughtAny = true
			end

			task.wait(0.1)
		end

		if boughtAny then
			setStatus("Board: buying levels")
			task.wait(0.2)
		else
			setStatus("Board: waiting for Apples")
			interruptibleWait(CONFIG.BOARD_BUY_COOLDOWN)
		end
	end
end

local function rollLeafDiceActivity()
	local shouldContinue = function()
		return enabled and not AutumnTravel.buyRequested and getRemaining(OBJECTIVES.LEAF_ROLLS) ~= nil
	end
	local function ensureLeafDicePosition()
		if not shouldContinue() then return false end
		local traveled, travelErr = AutumnTravel.ensureInAutumnWorld(shouldContinue)
		if not traveled then
			setStatus("Dice: could not enter Autumn World")
			warn("[AutumnDice] Auto Quest dice travel failed: " .. tostring(travelErr))
			return false
		end
		if not AutumnTravel.isNearZone(AutumnConfig.Zones.LeafDice, 10) then
			setStatus("Dice: moving to the Leaf Dice")
			local arrived, moveErr = AutumnTravel.pivotToZone(AutumnConfig.Zones.LeafDice, shouldContinue, 10)
			if not arrived then
				setStatus("Dice: could not reach the Leaf Dice")
				warn("[AutumnDice] Auto Quest dice movement failed: " .. tostring(moveErr))
				return false
			end
		end
		return AutumnTravel.isNearZone(AutumnConfig.Zones.LeafDice, 10)
	end

	while enabled and not AutumnTravel.buyRequested and CONFIG.AUTO_LEAF_ROLLS and getRemaining(OBJECTIVES.LEAF_ROLLS) do
		if not ensureLeafDicePosition() then
			if not shouldContinue() then break end
			task.wait(1)
			continue
		end

		local ok, results = pcall(rollLeafDice, LeafDice.MULTI)
		local rolled = ok and type(results) == "table" and #results > 0

		if not rolled and ensureLeafDicePosition() then
			ok, results = pcall(rollLeafDice, 1)
			rolled = ok and type(results) == "table" and #results > 0
		end

		if rolled then
			setStatus("Dice: rolling")
			interruptibleWait(LeafDice.ROLL_DURATION + 0.1)
		else
			setStatus("Dice: waiting for Leaves")
			interruptibleWait(CONFIG.DICE_RETRY_COOLDOWN)
		end
	end
end

local function withAutoQuestPriority(activity)
    if not enabled or AutumnTravel.buyRequested then return false end

    AutumnTravel.autoQuestRequestCount += 1
    AutumnTravel.autoQuestRequested = true

    local owner = {}
    local acquired = AutumnTravel.acquire(owner, function()
        return enabled and not AutumnTravel.buyRequested
    end)
    local ok, err = true, nil

    if acquired then
        if enabled and not AutumnTravel.buyRequested then
            ok, err = pcall(activity)
        end
        AutumnTravel.release(owner)
    end

    AutumnTravel.autoQuestRequestCount = math.max(0, AutumnTravel.autoQuestRequestCount - 1)
    AutumnTravel.autoQuestRequested = AutumnTravel.autoQuestRequestCount > 0

    if not ok then
        warn("[AutumnDice] Auto Quest activity failed: " .. tostring(err))
    end
    return acquired and ok
end

local function runQuestActivity(activity, zoneName, alwaysMove)
    withAutoQuestPriority(function()
        local shouldContinue = function()
            return enabled and not AutumnTravel.buyRequested
        end
        local traveled, travelErr = AutumnTravel.ensureInAutumnWorld(shouldContinue)
        if not traveled then
            if shouldContinue() then warn("[AutumnDice] Auto Quest travel failed: " .. tostring(travelErr)) end
            return
        end

        local zone = AutumnTravel.findZone(zoneName)
        if not zone then
            warn("[AutumnDice] Auto Quest zone not found: " .. tostring(zoneName))
            return
        end

        local _, root = getCharacterParts()
        local destination = zone:GetPivot().Position
        local needsMovement = alwaysMove
            or not root
            or (root.Position - destination).Magnitude > CONFIG.ArriveDistance
            or not AutumnTravel.isNearZone(zoneName, 10)

        AutumnTravel.autoQuestMoving = needsMovement
        if needsMovement then
            local arrived, moveErr = AutumnTravel.pivotToZone(zoneName, shouldContinue, 10)
            if not arrived then
                AutumnTravel.autoQuestMoving = false
                if shouldContinue() then warn("[AutumnDice] Auto Quest movement failed: " .. tostring(moveErr)) end
                return
            end
        end

        local ok, err = pcall(activity)
        AutumnTravel.autoQuestMoving = false
        if not ok then warn("[AutumnDice] Auto Quest activity failed: " .. tostring(err)) end
    end)
end

task.spawn(function()
	while true do
		task.wait(1)

		if not enabled or AutumnTravel.buyRequested then
			continue
		end

		if isRushActive() and getRushRemaining() then
			local remaining = getRushRemaining()
			setStatus(("Rush: %d apples to go"):format(remaining))
			runQuestActivity(collectApplesActivity, AppleConfig.AREA_ZONE, true)
		elseif CONFIG.AUTO_BOARD_LEVELS and getRemaining(OBJECTIVES.BOARD) then
			runQuestActivity(buyBoardLevelsActivity, AppleConfig.AREA_ZONE, true)
		elseif CONFIG.AUTO_LEAF_ROLLS and getRemaining(OBJECTIVES.LEAF_ROLLS) then
			runQuestActivity(rollLeafDiceActivity, AutumnConfig.Zones.LeafDice)
		elseif CONFIG.AUTO_APPLES and getRemaining(OBJECTIVES.APPLES) then
			setStatus("Apples: collecting in the Orchard")
			runQuestActivity(collectApplesActivity, AppleConfig.AREA_ZONE, true)
		else
			setStatus("Idle")
		end
	end
end)

local function getBuff(name)
	local ok, value = pcall(function()
		return BuffController.GetBuff(name)
	end)
	if ok and type(value) == "number" then
		return value
	end
	return 1
end

local function getTeam()
	local team = {}

	for index = 1, TowerRefs.MAX_TEAM_SIZE do
		local ok, key = pcall(function()
			return DataController.TowerTeam[index]()
		end)

		if ok and type(key) == "string" then
			local okEntry, entry = pcall(function()
				return DataController.Inventory[key]()
			end)

			if okEntry and type(entry) == "table" then
				local config = EntryRegistry.getEntryConfig(entry.name)

				if config and config.kind == "Unit" then
					local damage = config.damage(entry.attributes)
					local health = config.health(entry.attributes)

					if type(damage) == "number" and type(health) == "number" then
						table.insert(team, {
							name = entry.name,
							damage = damage * getBuff("Damage Multiplier"),
							health = health * getBuff("Health Multiplier"),
						})
					end
				end
			end
		end
	end

	return team
end

local function getMilestones()
	local ok, result = pcall(function()
		return DataController.Autumn.Milestones()
	end)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

local function simulateRun(section, maxFloors, team)
	local members = {}
	for _, member in team do
		table.insert(members, { damage = member.damage, health = member.health })
	end

	local currentMember = 1

	for floor = 1, maxFloors do
		local okHealth, enemyHealth = pcall(TurkeyTowers.EnemyHealth, section, floor)
		local okDamage, enemyDamage = pcall(TurkeyTowers.EnemyDamage, section, floor)

		if not okHealth or not okDamage
			or type(enemyHealth) ~= "number"
			or type(enemyDamage) ~= "number" then
			return floor - 1
		end

		local floorCleared = false

		while currentMember <= #members do
			local member = members[currentMember]

			if member.damage <= 0 then
				currentMember += 1
				continue
			end

			if enemyDamage <= 0 then
				floorCleared = true
				break
			end

			local attacksBeforeDying = math.ceil(member.health / enemyDamage)
			local attacksNeeded = math.ceil(enemyHealth / member.damage)

			if attacksNeeded <= attacksBeforeDying then
				member.health -= (attacksNeeded - 1) * enemyDamage
				floorCleared = true
				break
			end

			enemyHealth -= attacksBeforeDying * member.damage
			currentMember += 1
		end

		if not floorCleared then
			return floor - 1
		end
	end

	return maxFloors
end

local function getRunFloorTarget()
	for _, period in AutumnQuestConfig.Periods do
		for _, quest in period.quests do
			if quest.objective == "runFloor" then
				return quest.target
			end
		end
	end

	return nil
end

local function findBestSection(requireFullRun)
	local runTarget = getRunFloorTarget()
	local milestones = getMilestones()
	if not milestones then
		return nil, "data unavailable"
	end

	local team = getTeam()
	if #team == 0 then
		return nil, "no units"
	end

	local candidate = nil
	local bestSimulation = { section = nil, floors = 0 }

	for index, section in TurkeyTowers.Sections do
		local ok, unlocked = pcall(TurkeyTowers.IsUnlocked, milestones, index)
		if ok and unlocked then
			local floors = simulateRun(section, CONFIG.RUN_FLOOR_CHECK, team)

			if floors > bestSimulation.floors then
				bestSimulation.floors = floors
				bestSimulation.section = section
			end

			if runTarget and floors >= runTarget then
				candidate = section
				if CONFIG.TOWER_PREFERENCE == "First" then
					break
				end
			end
		end
	end

	if candidate then
		return candidate, nil
	end

	if not requireFullRun and bestSimulation.section then
		return bestSimulation.section, nil
	end

	if bestSimulation.section then
		return nil, ("best is %s at %d floors"):format(bestSimulation.section.name, bestSimulation.floors)
	end

	return nil, "no towers unlocked"
end

local lastTowerAttempt = 0

local function isTowerRunActive()
	local playerGui = player:FindFirstChild("PlayerGui")
	local root = playerGui and playerGui:FindFirstChild("Root")
	local tower = root and root:FindFirstChild("Tower")
	local screen = tower and tower:FindFirstChild("Screen")
	return screen ~= nil and screen.Visible
end

local function tryStartTower(section)
	local now = os.clock()

	if now - lastTowerAttempt < CONFIG.TOWER_START_COOLDOWN then
		return false
	end
	lastTowerAttempt = now

	local ok, result = pcall(TowerController.startTower, section.name)
	return ok and result == true
end

task.spawn(function()
	while true do
		task.wait(1)

		if not enabled or not CONFIG.AUTO_TOWER_RUN then
			continue
		end

		local runFloorRemaining = getRemaining(OBJECTIVES.RUN_FLOOR)
		local floorsRemaining = getRemaining(OBJECTIVES.FLOORS)

		if not runFloorRemaining and not floorsRemaining then
			continue
		end

		if isTowerRunActive() then
			setTowerStatus("Tower: run in progress")
			continue
		end
		local section, reason = nil, nil

		if runFloorRemaining then
			section, reason = findBestSection(true)
		end

		if not section and floorsRemaining then
			section, reason = findBestSection(false)
		end

		if section then
			withAutoQuestPriority(function()
				if tryStartTower(section) then
					setTowerStatus(("Tower: running %s"):format(section.name))
				end
			end)
		else
			setTowerStatus(("Tower: waiting (%s)"):format(reason or "none"))
		end
	end
end)

ctx.setAutoQuest = function(value)
	enabled = value
	setStatus(value and "Preparing Autumn quests" or "Disabled")
end

end
initializeAutoQuest()

ctx.autoQuestStatusLabel = autoQuestStatusLabel
ctx.setAutoClaim = setAutoClaim
ctx.FeatureHandlers.AutoDice = AutoRoll.setEnabled
ctx.FeatureHandlers.AutoClaimQuest = setAutoClaim
ctx.FeatureHandlers.AutoQuest = ctx.setAutoQuest
ctx.FeatureHandlers.AutoBuy = AutoBuy.setEnabled
ctx.CleanupHandlers.event = function()
	unhookQuests()
	AutumnTravel.buyRequested = false
	if AutoBuy.refreshEvent then pcall(function() AutoBuy.refreshEvent:Destroy() end) end
	for _, connection in ipairs(AutoBuy.dataHooks) do pcall(function() connection:Disconnect() end) end
end
ctx.unhookQuests = unhookQuests
end