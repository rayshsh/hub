return function(ctx)
local Players, ReplicatedStorage, player = ctx.Players, ctx.ReplicatedStorage, ctx.player
local State, CONFIG, AutumnTravel = ctx.State, ctx.CONFIG, ctx.AutumnTravel
local AutoBuy, AutoPotion = ctx.AutoBuy, ctx.AutoPotion
local makeCard, makeToggle, makeDropdown, makeLine = ctx.makeCard, ctx.makeToggle, ctx.makeDropdown, ctx.makeLine
local create, corner, stroke, pill, vlist, THEME = ctx.create, ctx.corner, ctx.stroke, ctx.pill, ctx.vlist, ctx.THEME
local pad = ctx.pad
local addTab, gui, connections, refreshers = ctx.addTab, ctx.gui, ctx.connections, ctx.refreshers
local getHRP, getRemote, invoke = ctx.getHRP, ctx.getRemote, ctx.invoke
local SetFeature, GetFeature, formatNumber = ctx.SetFeature, ctx.GetFeature, ctx.formatNumber
local BLUE, GREEN, YELLOW, ORANGE, GRAY, RED = ctx.BLUE, ctx.GREEN, ctx.YELLOW, ctx.ORANGE, ctx.GRAY, ctx.RED
local setAutoClaim
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
	if not AutoBuy.built or not AutoBuy.dropdown then return end

	local offers = AutoBuy.Config and AutoBuy.Config.Offers
	AutoBuy.offers = uniqueOffers(type(offers) == "table" and offers or AutoBuy.offers)

	local options, signature = {}, {}
	for _, offer in ipairs(AutoBuy.offers) do
		table.insert(options, offerOption(offer))
		table.insert(signature, offer.id .. ":" .. tostring(getBought(offer)))
	end

	local key = table.concat(signature, "|")
	if key == AutoBuy.stockKey then return end
	AutoBuy.stockKey = key
	AutoBuy.dropdown.SetOptions(options)
end

local refreshQueued = false
AutoBuy.refreshEvent = Instance.new("BindableEvent")
table.insert(connections, AutoBuy.refreshEvent.Event:Connect(function()
	refreshQueued = false
	AutoBuy.refreshOptions()
end))

function AutoBuy.queueRefreshOptions()
	if refreshQueued then return end
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
	while gui.Parent and not AutoBuy.built do
		pcall(AutoBuy.build)
		task.wait(1)
	end
end)

task.spawn(function()
	while gui.Parent do
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

ctx.autoQuestStatusLabel = autoQuestStatusLabel
ctx.setAutoClaim = setAutoClaim
ctx.unhookQuests = unhookQuests
end