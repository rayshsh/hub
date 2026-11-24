return function(ctx)
local ReplicatedStorage, State, gui = ctx.ReplicatedStorage, ctx.State, ctx.gui
local AutumnTravel = ctx.AutumnTravel
local addTab, makeCard, makeToggle, makeDropdown, makeLine, makeInput = ctx.addTab, ctx.makeCard, ctx.makeToggle, ctx.makeDropdown, ctx.makeLine, ctx.makeInput
local create, corner, pad, vlist, THEME = ctx.create, ctx.corner, ctx.pad, ctx.vlist, ctx.THEME

local TraitReroll = ctx.TraitReroll or {}
ctx.TraitReroll = TraitReroll
TraitReroll.token = TraitReroll.token or 0
TraitReroll.workerActive = TraitReroll.workerActive or false
TraitReroll.mode = TraitReroll.mode or "Picked Units"
TraitReroll.travelRetryAt = 0

local GradeReroll = ctx.GradeReroll or {}
ctx.GradeReroll = GradeReroll
GradeReroll.token = GradeReroll.token or 0
GradeReroll.workerActive = GradeReroll.workerActive or false
GradeReroll.mode = GradeReroll.mode or "Picked Units"
GradeReroll.travelRetryAt = 0

local QuirkReroll = ctx.QuirkReroll or {}
ctx.QuirkReroll = QuirkReroll
QuirkReroll.token = QuirkReroll.token or 0
QuirkReroll.workerActive = QuirkReroll.workerActive or false
QuirkReroll.mode = QuirkReroll.mode or "Picked Units"
QuirkReroll.travelRetryAt = 0

local UnitFuse = ctx.UnitFuse or {}
ctx.UnitFuse = UnitFuse
UnitFuse.token = UnitFuse.token or 0
UnitFuse.workerActive = UnitFuse.workerActive or false
UnitFuse.priority = UnitFuse.priority or "Start with Highest"
UnitFuse.startRarityText = UnitFuse.startRarityText or "1"
UnitFuse.limitRarityText = UnitFuse.limitRarityText or "10No"
UnitFuse.skipAnimation = UnitFuse.skipAnimation or false
UnitFuse.pending = nil
UnitFuse.resultConnection = nil
UnitFuse.resultHookQueued = false
UnitFuse.attempted = 0
UnitFuse.successful = 0
UnitFuse.failed = 0
UnitFuse.timedOut = 0
UnitFuse.eligibleUnits = 0
UnitFuse.currentRarity = ""
UnitFuse.bestResult = ""
UnitFuse.bestResultChance = 0

local TRAIT_ZONE = "Traits"     -- existing zones under workspace.Zones, resolved by AutumnTravel.findZone
local GRADE_ZONE = "Grades"
local QUIRK_ZONE = "Quirks"
local ZONE_MARGIN = 10          -- matches the server's ZoneCheck.IsNearZone margin
local TRAIT_FRONT_OFFSET = 5    -- stand this far beyond the zone's positive Z face
local GRADE_FRONT_OFFSET = 5
local TRAIT_ROLL_INTERVAL = 0.3
local GRADE_ROLL_INTERVAL = 0.3
local QUIRK_ROLL_INTERVAL = 0.2
local QUIRK_INFLIGHT_TIMEOUT = 1
local QUIRK_TRAVEL_RETRY_DELAY = 5
local QUIRK_MAX_ATTEMPTS = 0
local TRAVEL_RETRY_DELAY = 3

local function newTraitSession()
	return {
		completed = {}, skipped = {},
		attempts = 0, lastRoll = 0, spent = 0, lastBalance = nil,
	}
end
local function newGradeSession()
	return {
		completed = {}, skipped = {},
		attempts = 0, lastFire = 0, spent = 0, lastBalance = nil,
	}
end
local function newQuirkSession()
	return {
		completed = {}, skipped = {}, inFlight = {},
		attempts = 0, successful = 0, lastRoll = 0,
	}
end
TraitReroll.session = TraitReroll.session or newTraitSession()
QuirkReroll.session = QuirkReroll.session or newQuirkSession()
GradeReroll.session = GradeReroll.session or newGradeSession()

----------------------------------------------------------------
-- Game modules (lazy + guarded so a failure can never break the hub loader)
----------------------------------------------------------------
local M = {}
local loadState = {}

local function tryLoad(name, fn)
	local s = loadState[name]
	if not s then s = { done = false, last = -math.huge }; loadState[name] = s end
	if s.done then return true end
	if os.clock() - s.last < 2 then return false end
	s.last = os.clock()
	s.done = (pcall(fn))
	return s.done
end

local function loadCore()
	return tryLoad("core", function()
		local features = ReplicatedStorage.Framework.Features
		M.Network = require(ReplicatedStorage.Packages.Network)
		M.Data = require(features.Data.DataController)
		M.Registry = require(features.Inventory.EntryRegistry)
	end)
end

local function loadTrait()
	if not loadCore() then return false end
	return tryLoad("trait", function()
		M.Traits = require(ReplicatedStorage.Framework.Features.Traits.Traits)
		M.TraitRoll = M.Network.ClientComm.new(ReplicatedStorage.Network, false, "TraitService"):GetSignal("Roll")
		assert(M.TraitRoll)
	end)
end

local function loadGrade()
	if not loadCore() then return false end
	return tryLoad("grade", function()
		M.Grades = require(ReplicatedStorage.Framework.Features.Grades.Grades)
		M.GradeRoll = M.Network.ClientComm.new(ReplicatedStorage.Network, false, "GradeService"):GetSignal("Roll")
		assert(M.GradeRoll)
	end)
end

local function loadQuirk()
	if not loadCore() then return false end
	return tryLoad("quirk", function()
		local features = ReplicatedStorage.Framework.Features
		M.Quirks = require(features.Quirks.Quirks)
		M.QuirkUtil = require(features.Quirks.QuirkUtil)
		M.QuirkRoll = M.Network.ClientComm.new(ReplicatedStorage.Network, false, "QuirkService"):GetSignal("Roll")
		assert(M.QuirkRoll)
	end)
end

local function loadFuse()
	if not loadCore() then return false end
	return tryLoad("fuse", function()
		local features = ReplicatedStorage.Framework.Features
		M.FusingUtil = require(features.Fusing.FusingUtil)
		M.FusingConfig = require(features.Fusing.FusingConfig)
		M.NumberFormatter = require(ReplicatedStorage.Packages.NumberFormatter)
		local comm = M.Network.ClientComm.new(ReplicatedStorage.Network, false, "FusingService")
		M.FuseSignal = comm:GetSignal("Fuse")
		M.FuseResult = comm:GetSignal("Result")
		assert(M.FuseSignal and M.FuseResult)
	end)
end

local function getWeather()
	if M.weather then return M.weather end
	local ok, prop = pcall(function()
		return M.Network.ClientComm.new(ReplicatedStorage.Network, false, "WeatherService"):GetProperty("ActiveWeather")
	end)
	if ok and prop then M.weather = prop end
	return M.weather
end

----------------------------------------------------------------
-- Shared data helpers (read-only)
----------------------------------------------------------------
local function countSet(t)
	local n = 0
	for _ in pairs(t) do n += 1 end
	return n
end

local function getEntry(key)
	local ok, entry = pcall(function() return M.Data.Inventory[key]() end)
	return ok and entry or nil
end

local function getUnitTrait(key)
	local ok, trait = pcall(function() return M.Data.Inventory[key].attributes.trait() end)
	return ok and trait or nil
end

local function getUnitGrade(key)
	local ok, grade = pcall(function() return M.Data.Inventory[key].attributes.grade() end)
	return ok and grade or nil
end

-- nil is a valid quirk (no quirk yet); use getEntry() to tell "no quirk" from "no unit".
local function getUnitQuirk(key)
	local ok, quirk = pcall(function() return M.Data.Inventory[key].attributes.quirk() end)
	return ok and quirk or nil
end

local function getTraitUnitLabel(key)
	local entry = getEntry(key)
	if not entry then return tostring(key) end
	local trait = getUnitTrait(key)
	if trait then return tostring(entry.name) .. " (" .. tostring(trait) .. ")" end
	return tostring(entry.name)
end

local function getGradeUnitLabel(key)
	local entry = getEntry(key)
	if not entry then return tostring(key) end
	local grade = getUnitGrade(key)
	if grade then return tostring(entry.name) .. " (" .. tostring(grade) .. ")" end
	return tostring(entry.name)
end

local function getQuirkUnitLabel(key)
	local entry = getEntry(key)
	if not entry then return tostring(key) end
	local quirk = getUnitQuirk(key)
	if quirk then return tostring(entry.name) .. " (" .. tostring(quirk) .. ")" end
	return tostring(entry.name)
end

local function isUnitKey(key)
	local entry = getEntry(key)
	if not entry then return false end
	local ok, config = pcall(M.Registry.getEntryConfig, entry.name)
	return ok and config ~= nil and config.kind == "Unit"
end

local function getInventoryUnitList()
	local list = {}
	local ok, inventory = pcall(function() return M.Data.Inventory() end)
	if not ok or type(inventory) ~= "table" then return list end
	for key, entry in pairs(inventory) do
		if type(entry) == "table" then
			local okConfig, config = pcall(M.Registry.getEntryConfig, entry.name)
			if okConfig and config and config.kind == "Unit" then
				table.insert(list, { key = key, name = tostring(entry.name) })
			end
		end
	end
	table.sort(list, function(a, b)
		if a.name == b.name then return tostring(a.key) < tostring(b.key) end
		return a.name < b.name
	end)
	return list
end

local function getEquippedUnitKeys()
	local keys, seen = {}, {}
	local ok, slots = pcall(function() return M.Data.Slots() end)
	if not ok or type(slots) ~= "table" then return keys end
	for _, slot in pairs(slots) do
		if type(slot) == "table" and slot.unitId and not seen[slot.unitId] then
			seen[slot.unitId] = true
			table.insert(keys, slot.unitId)
		end
	end
	return keys
end

local function getTargets(mode, unitDropdown)
	local source
	if mode == "All Equipped" then
		source = getEquippedUnitKeys()
	else
		source = {}
		for key in pairs(unitDropdown.selected) do table.insert(source, key) end
	end
	local list, seen = {}, {}
	for _, key in ipairs(source) do
		if not seen[key] and isUnitKey(key) then
			seen[key] = true
			table.insert(list, key)
		end
	end
	return list
end

local function getRerollBalance()
	local entry = getEntry("Trait Reroll")
	if entry and type(entry.amount) == "number" then return entry.amount end
	return 0
end

local function getGemBalance()
	local entry = getEntry("Gems")
	if entry and type(entry.amount) == "number" then return entry.amount end
	return 0
end

local function updateSpent(session, balance)
	if session.lastBalance and balance < session.lastBalance then
		session.spent = (session.spent or 0) + session.lastBalance - balance
	end
	session.lastBalance = balance
end

local function isWeatherActive(weatherName)
	local weather = getWeather()
	if not weather then return false end
	local ok, value = pcall(function() return weather:Get() end)
	return ok and value ~= nil and value.name == weatherName
end

-- Quirk rolls cost Money, and the cost is per unit (scales with the unit).
local function getMoneyBalance()
	local ok, money = pcall(function() return M.Data.Money() end)
	if ok and type(money) == "number" then return money end
	return 0
end

local MONEY_SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function formatMoney(n)
	n = math.floor(n)
	if n < 1000 then return tostring(n) end
	local index = math.floor(math.log10(n) / 3)
	local suffix = MONEY_SUFFIXES[index + 1]
	if not suffix then return tostring(n) end
	local scaled = n / (1000 ^ index)
	if string.format("%.2f", scaled) == "1000.00" and MONEY_SUFFIXES[index + 2] then
		index += 1
		suffix = MONEY_SUFFIXES[index + 1]
		scaled = n / (1000 ^ index)
	end
	local text = string.format("%.2f", scaled):gsub("%.?0+$", "")
	return text .. suffix
end

local function getRollCostForKey(key)
	local entry = getEntry(key)
	if not entry then return nil end
	local mutation
	pcall(function() mutation = M.Data.Inventory[key].attributes.mutation() end)
	local ok, cost = pcall(M.QuirkUtil.GetRollCost, entry.name, { mutation = mutation })
	if ok and type(cost) == "number" then return cost end
	return nil
end

local function isTraitEventActive() return isWeatherActive("Trait Event") end
local function isGradeEventActive() return isWeatherActive("Grade Event") end

----------------------------------------------------------------
-- Shared travel helper: one place that talks to the shared AutumnTravel system.
-- Takes the movement lock, travels (if needed) via pivotToZone, verifies arrival,
-- then runs onArrived() while still holding the lock.
-- Returns fired:boolean, failureMessage:string|nil
----------------------------------------------------------------
local function higherPriorityActive()
	return AutumnTravel.questRequested or AutumnTravel.autoQuestMoving
		or AutumnTravel.autoQuestRequested or AutumnTravel.buyRequested
end

local function getZoneFrontOffset(zoneName, distance)
	local zone = AutumnTravel.findZone(zoneName)
	if not zone then return nil end
	local size
	if zone:IsA("Model") then
		local _, bounds = zone:GetBoundingBox()
		size = bounds
	else
		size = zone.Size
	end
	return Vector3.new(0, 0, size.Z / 2 + distance)
end

local function runAtZone(keepGoing, zoneName, areaLabel, setStatus, onArrived, destinationOffset)
	local owner = {}
	if not AutumnTravel.acquire(owner, keepGoing) then return false, nil end

	local fired, failure = false, nil
	local ok, err = pcall(function()
		if not AutumnTravel.isNearZone(zoneName, ZONE_MARGIN) then
			setStatus("Moving to " .. areaLabel .. ".")
			local moved, moveErr = AutumnTravel.pivotToZone(zoneName, keepGoing, ZONE_MARGIN, destinationOffset)
			if not keepGoing() then return end
			if not moved then failure = moveErr or ("Could not reach the " .. areaLabel .. "."); return end
		end
		if not keepGoing() then return end
		if not AutumnTravel.isNearZone(zoneName, ZONE_MARGIN) then
			failure = "Could not verify arrival at the " .. areaLabel .. "."
			return
		end
		fired, failure = onArrived()
	end)
	AutumnTravel.release(owner)
	if not ok then failure = tostring(err) end
	return fired == true, failure
end

local uiQueue = {}
local uiQueueConnection = game:GetService("RunService").Heartbeat:Connect(function()
	local pending = uiQueue
	uiQueue = {}
	for _, callback in ipairs(pending) do
		pcall(callback)
	end
end)
table.insert(ctx.connections, uiQueueConnection)

local function queueUi(callback)
	table.insert(uiQueue, callback)
end

local function setText(label, text)
	queueUi(function()
		if label.Parent and label.Text ~= text then label.Text = text end
	end)
end

----------------------------------------------------------------
-- UI (hub builder only: addTab / makeCard / makeToggle / makeDropdown / makeLine)
----------------------------------------------------------------
local rerollTab = addTab(1.5, "Reroll") -- sorts directly below Event (see loader addTab change)

-- Trait Reroll card -------------------------------------------------------
local traitBody = makeCard(rerollTab.left, function(tile)
	create("TextLabel", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "↻",
		Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = THEME.accent, Parent = tile,
	})
end, "Trait Reroll")

makeToggle(traitBody, 1, "Auto Trait Reroll", "AutoTraitReroll")
makeToggle(traitBody, 2, "Only During Trait Event", "TraitRerollEventOnly")

local traitDropdown = makeDropdown(traitBody, 3, {
	label = "Traits", multi = true, searchable = true,
	placeholder = "Select Traits...", emptyText = "No traits found", maxHeight = 180,
})
local traitModeDropdown = makeDropdown(traitBody, 4, {
	label = "Target",
	onSelect = function(value) TraitReroll.mode = value end,
})
traitModeDropdown.SetOptions({ "Picked Units", "All Equipped" })
traitModeDropdown.SetValue(TraitReroll.mode)
local traitUnitDropdown = makeDropdown(traitBody, 5, {
	label = "Units", multi = true, searchable = true,
	placeholder = "Select Units...", emptyText = "No units found", maxHeight = 180,
})

local traitInfo = create("Frame", {
	LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1, Parent = traitBody,
}, { vlist(4) })
local traitTotalLine = makeLine(traitInfo, 1, 12, THEME.body, Enum.Font.GothamMedium)
local traitBalanceLine = makeLine(traitInfo, 2, 12, THEME.body, Enum.Font.GothamMedium)
local traitCompletedLine = makeLine(traitInfo, 3, 12, THEME.body, Enum.Font.GothamMedium)
local traitStatusLine = makeLine(traitInfo, 4, 11, THEME.subtext)
traitTotalLine.Text = "Total Rolls: 0 (Trait Rerolls Spent: 0)"
traitBalanceLine.Text = "Remaining Trait Rerolls: 0"
traitCompletedLine.Text = "Completed Units: 0 / 0"
traitStatusLine.Text = "Status: Auto Trait Reroll disabled."

local function setTraitStatus(message) setText(traitStatusLine, "Status: " .. message) end

-- Grade Reroll card -------------------------------------------------------
local gradeBody = makeCard(rerollTab.right, function(tile)
	create("TextLabel", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "★",
		Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = THEME.accent, Parent = tile,
	})
end, "Grade Reroll")

makeToggle(gradeBody, 1, "Auto Grade Reroll", "AutoGradeReroll")
makeToggle(gradeBody, 2, "Only During Event", "GradeRerollEventOnly")

local gradeDropdown = makeDropdown(gradeBody, 3, {
	label = "Grades", multi = true, searchable = true,
	placeholder = "Select Grades...", emptyText = "No grades found", maxHeight = 180,
})
local gradeModeDropdown = makeDropdown(gradeBody, 4, {
	label = "Target",
	onSelect = function(value) GradeReroll.mode = value end,
})
gradeModeDropdown.SetOptions({ "Picked Units", "All Equipped" })
gradeModeDropdown.SetValue(GradeReroll.mode)
local gradeUnitDropdown = makeDropdown(gradeBody, 5, {
	label = "Units", multi = true, searchable = true,
	placeholder = "Select Units...", emptyText = "No units found", maxHeight = 180,
})

local gradeInfo = create("Frame", {
	LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1, Parent = gradeBody,
}, { vlist(4) })
local gradeTotalLine = makeLine(gradeInfo, 1, 12, THEME.body, Enum.Font.GothamMedium)
local gradeGemsLine = makeLine(gradeInfo, 2, 12, THEME.body, Enum.Font.GothamMedium)
local gradeCompletedLine = makeLine(gradeInfo, 3, 12, THEME.body, Enum.Font.GothamMedium)
local gradeStatusLine = makeLine(gradeInfo, 4, 11, THEME.subtext)
gradeTotalLine.Text = "Total Rolls: 0 (Gems Spent: 0)"
gradeGemsLine.Text = "Remaining Gems: 0"
gradeCompletedLine.Text = "Completed Units: 0 / 0"
gradeStatusLine.Text = "Status: Auto Grade Reroll disabled."

local function setGradeStatus(message) setText(gradeStatusLine, "Status: " .. message) end

-- Quirk Reroll card -------------------------------------------------------
local quirkBody = makeCard(rerollTab.left, function(tile)
	create("TextLabel", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "✧",
		Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = THEME.accent, Parent = tile,
	})
end, "Quirk Reroll", 2)

makeToggle(quirkBody, 1, "Auto Quirk Reroll", "AutoQuirkReroll")

local quirkDropdown = makeDropdown(quirkBody, 2, {
	label = "Quirks", multi = true, searchable = true,
	placeholder = "Select Quirks...", emptyText = "No quirks found", maxHeight = 180,
})
local quirkModeDropdown = makeDropdown(quirkBody, 3, {
	label = "Target",
	onSelect = function(value) QuirkReroll.mode = value end,
})
quirkModeDropdown.SetOptions({ "Picked Units", "All Equipped" })
quirkModeDropdown.SetValue(QuirkReroll.mode)
local quirkUnitDropdown = makeDropdown(quirkBody, 4, {
	label = "Units", multi = true, searchable = true,
	placeholder = "Select Units...", emptyText = "No units found", maxHeight = 180,
})

local quirkInfo = create("Frame", {
	LayoutOrder = 5, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1, Parent = quirkBody,
}, { vlist(4) })
local quirkTotalLine = makeLine(quirkInfo, 1, 12, THEME.body, Enum.Font.GothamMedium)
local quirkMoneyLine = makeLine(quirkInfo, 2, 12, THEME.body, Enum.Font.GothamMedium)
local quirkCompletedLine = makeLine(quirkInfo, 3, 12, THEME.body, Enum.Font.GothamMedium)
local quirkStatusLine = makeLine(quirkInfo, 4, 11, THEME.subtext)
quirkTotalLine.Text = "Total Rolls: 0"
quirkMoneyLine.Text = "Money: $0"
quirkCompletedLine.Text = "Completed Units: 0 / 0"
quirkStatusLine.Text = "Status: Auto Quirk Reroll disabled."

local function setQuirkStatus(message) setText(quirkStatusLine, "Status: " .. message) end

local setFuseStatus
local parseFuseRarity

local fuseBody = makeCard(rerollTab.right, function(tile)
	create("TextLabel", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "⧉",
		Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = THEME.accent, Parent = tile,
	})
end, "Fuse Units", 2)

makeToggle(fuseBody, 1, "Fuse Units", "AutoUnitsFuse")
local fusePriorityDropdown = makeDropdown(fuseBody, 2, {
	label = "Fusion Priority",
	onSelect = function(value) UnitFuse.priority = value end,
})
fusePriorityDropdown.SetOptions({ "Start with Highest", "Start with Lowest" })
fusePriorityDropdown.SetValue(UnitFuse.priority)

local function makeRarityInput(order, labelText, initialText, onChanged)
	local box = makeInput(fuseBody, order, labelText, initialText, "e.g. 10K, 1.5No")
	box.FocusLost:Connect(function()
		onChanged(box.Text)
		local value = parseFuseRarity(box.Text)
		if value then
			local ok, formatted = pcall(M.NumberFormatter.FormatCompact, value)
			setFuseStatus(labelText .. " set to 1 in " .. (ok and formatted or tostring(value)) .. ".")
		else
			setFuseStatus("Invalid rarity value - use numbers or shorthand like 10K, 1.5No.")
		end
	end)
	return box
end

makeRarityInput(3, "Starting Rarity", UnitFuse.startRarityText, function(value)
	UnitFuse.startRarityText = value
end)
makeRarityInput(4, "Limit Rarity", UnitFuse.limitRarityText, function(value)
	UnitFuse.limitRarityText = value
end)
makeToggle(fuseBody, 5, "Skip Fusion Animation", "SkipFuseAnimation")

local fuseInfo = create("Frame", {
	LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1, Parent = fuseBody,
}, { vlist(4) })
local fuseMoneyLine = makeLine(fuseInfo, 1, 12, THEME.body, Enum.Font.GothamMedium)
local fuseRarityLine = makeLine(fuseInfo, 2, 12, THEME.body, Enum.Font.GothamMedium)
local fuseBestLine = makeLine(fuseInfo, 3, 12, THEME.body, Enum.Font.GothamMedium)
local fuseStatusLine = makeLine(fuseInfo, 4, 11, THEME.subtext)
fuseMoneyLine.Text = "Money: $0"
fuseRarityLine.Text = "Fusing: -"
fuseBestLine.Text = "Best: -"
fuseStatusLine.Text = "Status: Idle."
setFuseStatus = function(message) setText(fuseStatusLine, "Status: " .. message) end

----------------------------------------------------------------
-- Dropdown option refresh (single BindableEvent, same pattern as the Potion/Tower tabs)
----------------------------------------------------------------
local dropdownsByKind = {
	traits = traitDropdown, traitUnits = traitUnitDropdown,
	grades = gradeDropdown, gradeUnits = gradeUnitDropdown,
	quirks = quirkDropdown, quirkUnits = quirkUnitDropdown,
}
local signatures, pendingSignatures = {}, {}

local optionsEvent = Instance.new("BindableEvent")
table.insert(ctx.connections, optionsEvent.Event:Connect(function(kind, options, signature)
	if not ctx.Alive then return end
	local dropdown = dropdownsByKind[kind]
	if not dropdown then return end
	local ok, err = pcall(dropdown.SetOptions, options)
	pendingSignatures[kind] = nil
	if ok then
		signatures[kind] = signature
	else
		warn("[Reroll] Dropdown refresh failed (" .. tostring(kind) .. "): " .. tostring(err))
	end
end))

local function pushOptions(kind, options, signature)
	if signatures[kind] == signature or pendingSignatures[kind] == signature then return end
	pendingSignatures[kind] = signature
	queueUi(function() optionsEvent:Fire(kind, options, signature) end)
end

local function sortedConfigOptions(config)
	local sorted = {}
	for name, entry in pairs(config) do
		table.insert(sorted, { name = name, order = type(entry) == "table" and entry.order or 0 })
	end
	table.sort(sorted, function(a, b)
		if a.order == b.order then return a.name < b.name end
		return a.order < b.order
	end)
	local options, names = {}, {}
	for _, item in ipairs(sorted) do
		table.insert(options, { key = item.name, label = item.name })
		table.insert(names, item.name)
	end
	return options, table.concat(names, "\0")
end

local function refreshOptions()
	if loadTrait() then
		local options, signature = sortedConfigOptions(M.Traits)
		pushOptions("traits", options, signature)
	end
	if loadGrade() then
		local options, signature = sortedConfigOptions(M.Grades)
		pushOptions("grades", options, signature)
	end
	if loadQuirk() then
		local options, signature = sortedConfigOptions(M.Quirks)
		pushOptions("quirks", options, signature)
	end
	if not loadCore() then return end

	local units = getInventoryUnitList()
	for _, spec in ipairs({
		{ kind = "traitUnits", getLabel = getTraitUnitLabel },
		{ kind = "gradeUnits", getLabel = getGradeUnitLabel },
		{ kind = "quirkUnits", getLabel = getQuirkUnitLabel },
	}) do
		local options, parts = {}, {}
		for _, item in ipairs(units) do
			local label = spec.getLabel(item.key)
			table.insert(options, { key = item.key, label = label })
			table.insert(parts, tostring(item.key) .. "=" .. label)
		end
		pushOptions(spec.kind, options, table.concat(parts, "\0"))
	end
end

----------------------------------------------------------------
-- Trait Reroll logic (batched every 0.5 seconds, like the standalone script)
----------------------------------------------------------------
local function traitAlive(token)
	return TraitReroll.token == token and State.Features.AutoTraitReroll and ctx.Alive
end

local function traitPickBatch(session, targets)
	local selected = traitDropdown.selected
	local pending = {}
	for _, key in ipairs(targets) do
		local current = getUnitTrait(key)
		if current and selected[current] then
			session.completed[key] = true
		else
			session.completed[key] = nil
			table.insert(pending, key)
		end
	end
	return pending
end

local function traitFireBatch(token, session, pending)
	local keepGoing = function() return traitAlive(token) and not higherPriorityActive() end
	return runAtZone(keepGoing, TRAIT_ZONE, "Trait Area", setTraitStatus, function()
		for _, key in ipairs(pending) do
			local sent = pcall(function() M.TraitRoll:Fire(key, true) end)
			if not sent then
				return false, "Roll request failed to send."
			end
			session.attempts += 1
		end
		return true
	end, getZoneFrontOffset(TRAIT_ZONE, TRAIT_FRONT_OFFSET))
end

local function traitTick(token, session)
	if not loadTrait() then
		setTraitStatus("Waiting for game data.")
		return 1
	end
	local now = os.clock()

	local targets = getTargets(TraitReroll.mode, traitUnitDropdown)
	local pending = traitPickBatch(session, targets)
	local allDone = true
	for _, key in ipairs(targets) do
		if not session.completed[key] and not session.skipped[key] then allDone = false break end
	end

	if countSet(traitDropdown.selected) == 0 then
		setTraitStatus("Ready - choose at least one Trait in the Traits dropdown.")
		return 0.5
	elseif State.Features.TraitRerollEventOnly and not isTraitEventActive() then
		setTraitStatus("Waiting for Trait Event.")
		return 0.5
	elseif #targets == 0 then
		setTraitStatus("Ready - no eligible units.")
		return 2
	elseif allDone then
		setTraitStatus("Completed.")
		return 2
	elseif higherPriorityActive() then
		setTraitStatus("Waiting for another automation to finish.")
		return 0.2
	elseif now < TraitReroll.travelRetryAt then
		return 0.2 -- keep the travel error visible; do not roll or re-travel yet
	end

	if now - session.lastRoll < TRAIT_ROLL_INTERVAL then return 0.05 end

	if #pending > getRerollBalance() then
		setTraitStatus("Insufficient Trait Rerolls.")
		return 0.5
	elseif #pending == 0 then
		setTraitStatus("Completed.")
		return 0.5
	end

	local fired, failure = traitFireBatch(token, session, pending)
	if not traitAlive(token) then return 0 end
	if fired then
		session.lastRoll = os.clock()
		setTraitStatus("Rerolling " .. #pending .. " units.")
	elseif failure then
		setTraitStatus("Error - " .. failure)
		TraitReroll.travelRetryAt = os.clock() + TRAVEL_RETRY_DELAY
	end
	return 0.5
end

local function traitWorker(token)
	-- Never run two supervisors: wait for any previous one to exit first.
	while TraitReroll.workerActive and traitAlive(token) do task.wait(0.05) end
	if not traitAlive(token) then return end

	TraitReroll.workerActive = true
	local session = TraitReroll.session
	while traitAlive(token) do
		local ok, result = pcall(traitTick, token, session)
		if ok then
			task.wait(tonumber(result) or 0.1)
		else
			warn("[Trait Reroll] " .. tostring(result))
			setTraitStatus("Error - " .. tostring(result))
			task.wait(2)
		end
	end
	TraitReroll.workerActive = false
end

ctx.FeatureHandlers.AutoTraitReroll = function(enabled)
	TraitReroll.token += 1 -- invalidates any running supervisor
	if not enabled then
		updateSpent(TraitReroll.session, getRerollBalance())
		setTraitStatus("Auto Trait Reroll disabled.")
		return
	end
	TraitReroll.session = newTraitSession()
	TraitReroll.session.lastBalance = getRerollBalance()
	TraitReroll.travelRetryAt = 0
	setTraitStatus("Starting.")
	task.spawn(traitWorker, TraitReroll.token)
end

----------------------------------------------------------------
-- Grade Reroll logic (batched every 0.5 seconds, like the standalone script)
----------------------------------------------------------------
local function gradeAlive(token)
	return GradeReroll.token == token and State.Features.AutoGradeReroll and ctx.Alive
end

local function gradePickBatch(session, targets)
	local selected = gradeDropdown.selected
	local pending = {}
	for _, key in ipairs(targets) do
		local grade = getUnitGrade(key)
		if grade and selected[grade] then
			session.completed[key] = true
		else
			session.completed[key] = nil
			table.insert(pending, key)
		end
	end
	return pending
end

local function gradeFireBatch(token, session, pending)
	local keepGoing = function() return gradeAlive(token) and not higherPriorityActive() end
	return runAtZone(keepGoing, GRADE_ZONE, "Grade Area", setGradeStatus, function()
		for _, key in ipairs(pending) do
			local sent = pcall(function() M.GradeRoll:Fire(key, true) end)
			if not sent then return false, "Roll request failed to send." end
			session.attempts += 1
		end
		return true
	end, getZoneFrontOffset(GRADE_ZONE, GRADE_FRONT_OFFSET))
end

local function gradeTick(token, session)
	if not loadGrade() then
		setGradeStatus("Waiting for game data.")
		return 1
	end
	local now = os.clock()

	local targets = getTargets(GradeReroll.mode, gradeUnitDropdown)
	local pending = gradePickBatch(session, targets)
	local allDone = true
	for _, key in ipairs(targets) do
		if not session.completed[key] and not session.skipped[key] then allDone = false break end
	end

	if countSet(gradeDropdown.selected) == 0 then
		setGradeStatus("No Grades selected - choose at least one in the Grades dropdown.")
		return 0.5
	elseif #targets == 0 then
		setGradeStatus("Searching for eligible units.")
		return 0.5
	elseif State.Features.GradeRerollEventOnly and not isGradeEventActive() then
		-- Event gate: hold rolling until the game's Grade Event is active
		setGradeStatus("Waiting for Grade Event")
		return 0.5
	elseif allDone then
		setGradeStatus("All selected units completed.")
		return 0.5
	elseif higherPriorityActive() then
		setGradeStatus("Waiting for another automation to finish.")
		return 0.2
	elseif now < GradeReroll.travelRetryAt then
		return 0.2
	end

	if now - session.lastFire < GRADE_ROLL_INTERVAL then return 0.05 end
	if #pending == 0 then
		setGradeStatus("All selected units completed.")
		return 0.5
	end
	if getGemBalance() < #pending then
		setGradeStatus("Insufficient Gems.")
		return 0.5
	end

	local fired, failure = gradeFireBatch(token, session, pending)
	if not gradeAlive(token) then return 0 end
	if fired then
		session.lastFire = os.clock()
		setGradeStatus("Rerolling " .. getGradeUnitLabel(pending[1]) .. "...")
	elseif failure then
		setGradeStatus("Error - " .. failure)
		GradeReroll.travelRetryAt = os.clock() + TRAVEL_RETRY_DELAY
	end
	return 0.5
end

local function gradeWorker(token)
	while GradeReroll.workerActive and gradeAlive(token) do task.wait(0.05) end
	if not gradeAlive(token) then return end

	GradeReroll.workerActive = true
	local session = GradeReroll.session
	while gradeAlive(token) do
		local ok, result = pcall(gradeTick, token, session)
		if ok then
			task.wait(tonumber(result) or 0.1)
		else
			warn("[Grade Reroll] " .. tostring(result))
			setGradeStatus("Error - " .. tostring(result))
			task.wait(2)
		end
	end
	GradeReroll.workerActive = false
end

ctx.FeatureHandlers.AutoGradeReroll = function(enabled)
	GradeReroll.token += 1
	if not enabled then
		updateSpent(GradeReroll.session, getGemBalance())
		setGradeStatus("Auto Grade Reroll disabled.")
		return
	end
	GradeReroll.session = newGradeSession()
	GradeReroll.session.lastBalance = getGemBalance()
	GradeReroll.travelRetryAt = 0
	setGradeStatus("Starting.")
	task.spawn(gradeWorker, GradeReroll.token)
end

----------------------------------------------------------------
-- Quirk Reroll logic (batched by affordability, with per-unit Money costs)
----------------------------------------------------------------
local function quirkAlive(token)
	return QuirkReroll.token == token and State.Features.AutoQuirkReroll and ctx.Alive
end

local function normalizeQuirkName(name)
	return string.lower(tostring(name):gsub("%s+", ""))
end

local function quirkMatchesSelected(current, selected)
	local normalized = normalizeQuirkName(current)
	for name in pairs(selected) do
		if normalizeQuirkName(name) == normalized then return true end
	end
	return false
end

-- Checks each unit's live quirk and keeps completion in sync with the selection.
local function quirkPickBatch(session, targets)
	local selected = quirkDropdown.selected
	local pending = {}
	local available = 0
	local inFlight = 0
	for _, key in ipairs(targets) do
		if getEntry(key) then
			available += 1
			local current = getUnitQuirk(key)
			local flight = session.inFlight[key]
			if flight then
				if current ~= flight.quirkBefore then
					session.inFlight[key] = nil
				elseif os.clock() >= flight.deadline then
					session.inFlight[key] = nil
				end
			end
			if current and quirkMatchesSelected(current, selected) then
				session.completed[key] = true
				session.inFlight[key] = nil
			else
				session.completed[key] = nil
				if session.inFlight[key] then
					inFlight += 1
				else
					table.insert(pending, { key = key, cost = getRollCostForKey(key) })
				end
			end
		end
	end
	return pending, available, inFlight
end

local function quirkFireBatch(token, session, pending)
	local keepGoing = function() return quirkAlive(token) and not higherPriorityActive() end
	return runAtZone(keepGoing, QUIRK_ZONE, "Quirk Area", setQuirkStatus, function()
		local selected = quirkDropdown.selected
		local countedRollCycle = false
		for _, item in ipairs(pending) do
			local current = getUnitQuirk(item.key)
			if current and quirkMatchesSelected(current, selected) then
				session.completed[item.key] = true
			else
				session.inFlight[item.key] = {
					quirkBefore = current,
					deadline = os.clock() + QUIRK_INFLIGHT_TIMEOUT,
				}
				local sent = pcall(function() M.QuirkRoll:Fire(item.key, true) end)
				if not sent then
					session.inFlight[item.key] = nil
					return false, "Roll request failed to send."
				end
				session.attempts += 1
				if not countedRollCycle then
					session.successful += 1
					countedRollCycle = true
				end
			end
		end
		return true
	end, getZoneFrontOffset(QUIRK_ZONE, 5))
end

local function quirkTick(token, session)
	if not loadQuirk() then
		setQuirkStatus("Waiting for game data.")
		return 1
	end
	local now = os.clock()

	if countSet(quirkDropdown.selected) == 0 then
		setQuirkStatus("Ready - choose at least one Quirk in the Quirks dropdown.")
		return 0.5
	end

	local targets = getTargets(QuirkReroll.mode, quirkUnitDropdown)
	local pending, available, inFlight = quirkPickBatch(session, targets)
	local allDone = true
	for _, key in ipairs(targets) do
		if not session.completed[key] and not session.skipped[key] then allDone = false break end
	end

	if #targets == 0 then
		setQuirkStatus("Ready - no eligible units.")
		return 2
	elseif allDone then
		setQuirkStatus("Completed.")
		return 2
	elseif higherPriorityActive() then
		setQuirkStatus("Waiting for another automation to finish.")
		return 0.2
	elseif now < QuirkReroll.travelRetryAt then
		return 0.2 -- keep the travel error visible; do not roll or re-travel yet
	elseif now - session.lastRoll < QUIRK_ROLL_INTERVAL then
		return 0.1
	elseif QUIRK_MAX_ATTEMPTS > 0 and session.attempts >= QUIRK_MAX_ATTEMPTS then
		setQuirkStatus("Stopped after " .. session.attempts .. " attempts.")
		return 5
	end

	if #pending == 0 then
		if inFlight > 0 then
			-- setQuirkStatus("Waiting for Trait Update.")
			return 0.1
		end
		setQuirkStatus(available == #targets and "Completed." or "Waiting for units to be available.")
		return 0.5
	end

	-- Affordability is per unit; run every candidate whose cost fits the remaining Money.
	local balance = getMoneyBalance()
	local affordable = {}
	local firstUnaffordable
	for _, item in ipairs(pending) do
		if item.cost == nil or item.cost <= balance then
			table.insert(affordable, item)
			if item.cost then balance -= item.cost end
		elseif not firstUnaffordable then
			firstUnaffordable = item
		end
	end
	if #affordable == 0 then
		local label = firstUnaffordable and getQuirkUnitLabel(firstUnaffordable.key) or "any unit"
		setQuirkStatus("Insufficient Money for " .. label .. ".")
		return 0.5
	end

	local fired, failure = quirkFireBatch(token, session, affordable)
	if not quirkAlive(token) then return 0 end
	if fired then
		session.lastRoll = os.clock()
		local first = affordable[1]
		setQuirkStatus("Rolling: " .. getQuirkUnitLabel(first.key) .. ".")
	elseif failure then
		setQuirkStatus("Error - " .. failure)
		QuirkReroll.travelRetryAt = os.clock() + QUIRK_TRAVEL_RETRY_DELAY
	end
	return QUIRK_ROLL_INTERVAL
end

local function quirkWorker(token)
	while QuirkReroll.workerActive and quirkAlive(token) do task.wait(0.25) end
	if not quirkAlive(token) then return end

	QuirkReroll.workerActive = true
	local session = QuirkReroll.session
	session.completed = session.completed or {}
	session.skipped = session.skipped or {}
	session.inFlight = session.inFlight or {}
	session.attempts = session.attempts or 0
	session.successful = session.successful or 0
	session.lastRoll = session.lastRoll or 0
	local errorWait = 2
	while quirkAlive(token) do
		local ok, result = pcall(quirkTick, token, session)
		if ok then
			task.wait(math.max(tonumber(result) or 0.1, 0.05))
			errorWait = 2
		else
			warn("[Quirk Reroll] " .. tostring(result))
			setQuirkStatus("Error - " .. tostring(result))
			task.wait(errorWait)
			errorWait = math.min(errorWait * 2.5, 10)
		end
	end
	QuirkReroll.workerActive = false
end

ctx.FeatureHandlers.AutoQuirkReroll = function(enabled)
	QuirkReroll.token += 1
	if not enabled then
		setQuirkStatus("Auto Quirk Reroll disabled.")
		return
	end
	QuirkReroll.session = newQuirkSession()
	QuirkReroll.travelRetryAt = 0
	setQuirkStatus("Starting.")
	task.spawn(quirkWorker, QuirkReroll.token)
end

----------------------------------------------------------------
-- Auto Units Fuse
----------------------------------------------------------------
local FUSE_INTERVAL = 3.5
local FUSE_RESULT_TIMEOUT = 10
local FUSE_PRIORITY = { "Start with Highest", "Start with Lowest" }

parseFuseRarity = function(text)
	if type(text) ~= "string" or not loadFuse() then return nil end
	local ok, value = pcall(M.NumberFormatter.ParseCompact, text)
	if not ok or type(value) ~= "number" or value ~= value or value <= 0 then return nil end
	return value
end

local function getFuseRarityRange()
	local startValue = parseFuseRarity(UnitFuse.startRarityText)
	if not startValue then return nil, "Invalid Starting Rarity." end
	local limitValue = parseFuseRarity(UnitFuse.limitRarityText)
	if not limitValue then return nil, "Invalid Limit Rarity." end
	if startValue > limitValue then return nil, "Starting Rarity must not exceed Limit Rarity." end
	return startValue, limitValue
end

local function getFuseChance(key)
	local entry = getEntry(key)
	if not entry then return nil end
	local ok, chance = pcall(M.FusingUtil.GetChance, entry)
	return ok and type(chance) == "number" and chance or nil
end

local function getFuseInventoryUnitKeys()
	local keys = {}
	local ok, inventory = pcall(function() return M.Data.Inventory() end)
	if not ok or type(inventory) ~= "table" then return keys end
	for key, entry in pairs(inventory) do
		if type(entry) == "table" then
			local okConfig, config = pcall(M.Registry.getEntryConfig, entry.name)
			if okConfig and config and config.kind == "Unit" then table.insert(keys, key) end
		end
	end
	table.sort(keys, function(a, b)
		local entryA, entryB = getEntry(a), getEntry(b)
		local nameA, nameB = entryA and entryA.name or "", entryB and entryB.name or ""
		if nameA == nameB then return tostring(a) < tostring(b) end
		return nameA < nameB
	end)
	return keys
end

local function scanFuseUnits(startValue, limitValue)
	local units = {}
	for _, key in ipairs(getFuseInventoryUnitKeys()) do
		local chance = getFuseChance(key)
		if chance and startValue <= chance and chance <= limitValue then
			table.insert(units, { key = key, chance = chance })
		end
	end
	table.sort(units, function(a, b) return a.chance < b.chance end)
	return units
end

local function formatFuseChance(chance)
	local ok, text = pcall(M.NumberFormatter.FormatCompact, chance)
	return ok and text or tostring(chance)
end

local function ensureFuseResultConnection()
	if UnitFuse.resultConnection then return end
	UnitFuse.resultConnection = M.FuseResult:Connect(function(resultEntry, errMsg)
		if not UnitFuse.pending then return end
		if resultEntry then
			UnitFuse.successful += 1
			local name = type(resultEntry) == "table" and resultEntry.name or "unit"
			local okChance, chance = pcall(M.FusingUtil.GetChance, resultEntry)
			local rarity = (okChance and chance) and ("1 in " .. formatFuseChance(chance)) or "unknown rarity"
			UnitFuse.lastResult = tostring(name) .. " (" .. rarity .. ")"
			if okChance and chance and chance > UnitFuse.bestResultChance then
				UnitFuse.bestResultChance = chance
				UnitFuse.bestResult = UnitFuse.lastResult
			end
			setFuseStatus("Result: " .. UnitFuse.lastResult .. ".")
		else
			UnitFuse.failed += 1
			setFuseStatus("Fusion failed: " .. tostring(errMsg or "request rejected") .. ".")
		end
		UnitFuse.pending = nil
	end)
	table.insert(ctx.connections, UnitFuse.resultConnection)
end

local function unitFuseAlive(token)
	return UnitFuse.token == token and State.Features.AutoUnitsFuse and ctx.Alive
end

local function unitFuseTick(token)
	if not loadFuse() then
		setFuseStatus("Waiting for game data.")
		return 1
	end
	if not UnitFuse.resultConnection then
		if not UnitFuse.resultHookQueued then
			UnitFuse.resultHookQueued = true
			queueUi(function()
				UnitFuse.resultHookQueued = false
				ensureFuseResultConnection()
			end)
		end
		return 0.1
	end

	local now = os.clock()
	if UnitFuse.pending then
		if now > UnitFuse.pending.deadline then
			UnitFuse.pending = nil
			UnitFuse.failed += 1
			UnitFuse.timedOut += 1
			setFuseStatus("Fusion result timed out; units released.")
		else
			setFuseStatus("Waiting for fusion result.")
			return 0.1
		end
	end

	local startValue, limitValue = getFuseRarityRange()
	if not startValue then
		setFuseStatus(limitValue)
		return 0.5
	end

	local units = scanFuseUnits(startValue, limitValue)
	UnitFuse.eligibleUnits = #units
	if #units < 3 then
		UnitFuse.currentRarity = ""
		setFuseStatus("Need 3 eligible units in the selected rarity range.")
		return 2
	end

	local picks = {}
	if UnitFuse.priority == "Start with Highest" then
		for index = #units - 2, #units do table.insert(picks, units[index]) end
	else
		for index = 1, 3 do table.insert(picks, units[index]) end
	end

	local chances = {}
	for _, unit in ipairs(picks) do
		local chance = getFuseChance(unit.key)
		if not chance or chance < startValue or chance > limitValue then
			setFuseStatus("Finding eligible units.")
			return 0.1
		end
		table.insert(chances, chance)
	end

	local okCost, cost = pcall(M.FusingConfig.GetCost, chances[1] + chances[2] + chances[3])
	if not okCost or type(cost) ~= "number" then
		setFuseStatus("Could not calculate fusion cost.")
		return 1
	elseif getMoneyBalance() < cost then
		setFuseStatus("Insufficient Money for this fusion.")
		return 1
	end

	UnitFuse.currentRarity = "1 in " .. formatFuseChance(chances[1])
		.. " to 1 in " .. formatFuseChance(chances[3])
	setFuseStatus("Fusing units.")
	UnitFuse.pending = {
		keys = { picks[1].key, picks[2].key, picks[3].key },
		deadline = now + FUSE_RESULT_TIMEOUT,
	}
	UnitFuse.attempted += 1
	local sent = pcall(function()
		M.FuseSignal:Fire(picks[1].key, picks[2].key, picks[3].key)
	end)
	if not sent then
		UnitFuse.pending = nil
		UnitFuse.failed += 1
		setFuseStatus("Fusion request failed to send.")
		return 1
	end
	return FUSE_INTERVAL
end

local function unitFuseWorker(token)
	while UnitFuse.workerActive and unitFuseAlive(token) do task.wait(0.05) end
	if not unitFuseAlive(token) then return end
	UnitFuse.workerActive = true
	while unitFuseAlive(token) do
		local ok, delay = pcall(unitFuseTick, token)
		if ok then
			task.wait(tonumber(delay) or 0.1)
		else
			warn("[Unit Fuse] " .. tostring(delay))
			setFuseStatus("Error - " .. tostring(delay))
			task.wait(2)
		end
	end
	UnitFuse.workerActive = false
end

local function setSkipFuseAnimation(enabled)
	UnitFuse.skipAnimation = enabled
	if not enabled then
		if UnitFuse.originalPlayCutscene then
			local ok, controller = pcall(require, ReplicatedStorage.Framework.Features.Rolling.RollController)
			if ok then controller.PlayCutscene = UnitFuse.originalPlayCutscene end
			UnitFuse.originalPlayCutscene = nil
		end
		return
	end

	local ok, controller = pcall(require, ReplicatedStorage.Framework.Features.Rolling.RollController)
	if not ok then
		setFuseStatus("Skip Animation is on, but RollController could not be loaded.")
		return
	end
	if UnitFuse.originalPlayCutscene == nil then
		UnitFuse.originalPlayCutscene = controller.PlayCutscene
	end
	controller.PlayCutscene = function(_gradient, _chance, model)
		if model then model:Destroy() end
	end
	setFuseStatus("Skip Animation is on - fusion cutscenes are suppressed.")
end

ctx.FeatureHandlers.SkipFuseAnimation = setSkipFuseAnimation
ctx.FeatureHandlers.AutoUnitsFuse = function(enabled)
	UnitFuse.token += 1
	if not enabled then
		UnitFuse.pending = nil
		setFuseStatus("Auto Units Fuse disabled.")
		return
	end
	UnitFuse.attempted = 0
	UnitFuse.successful = 0
	UnitFuse.failed = 0
	UnitFuse.timedOut = 0
	UnitFuse.eligibleUnits = 0
	UnitFuse.currentRarity = ""
	UnitFuse.bestResult = ""
	UnitFuse.bestResultChance = 0
	UnitFuse.pending = nil
	setFuseStatus("Starting.")
	task.spawn(unitFuseWorker, UnitFuse.token)
end

----------------------------------------------------------------
-- Background refresh (options + stats). Independent of the active tab.
----------------------------------------------------------------
local function refreshTraitStats()
	local session = TraitReroll.session
	local balance = getRerollBalance()
	if State.Features.AutoTraitReroll then updateSpent(session, balance) else session.lastBalance = balance end
	setText(traitTotalLine, ("Total Rolls: %d"):format(session.spent or 0))
	setText(traitBalanceLine, "Trait Rerolls: " .. tostring(balance))
	local targets = getTargets(TraitReroll.mode, traitUnitDropdown)
	local done = 0
	for _, key in ipairs(targets) do
		if session.completed[key] or session.skipped[key] then done += 1 end
	end
	setText(traitCompletedLine, ("Completed Units: %d / %d"):format(done, #targets))
	queueUi(function() traitUnitDropdown.SetDimmed(TraitReroll.mode == "All Equipped") end)
end

local function refreshGradeStats()
	local session = GradeReroll.session
	local balance = getGemBalance()
	if State.Features.AutoGradeReroll then updateSpent(session, balance) else session.lastBalance = balance end
	setText(gradeTotalLine, ("Total Rolls: %d"):format(session.spent or 0))
	setText(gradeGemsLine, "Remaining Gems: " .. tostring(balance))
	local targets = getTargets(GradeReroll.mode, gradeUnitDropdown)
	local done = 0
	for _, key in ipairs(targets) do
		if session.completed[key] or session.skipped[key] then done += 1 end
	end
	setText(gradeCompletedLine, ("Completed Units: %d / %d"):format(done, #targets))
	queueUi(function() gradeUnitDropdown.SetDimmed(GradeReroll.mode == "All Equipped") end)
end

local function refreshQuirkStats()
	local session = QuirkReroll.session
	setText(quirkTotalLine, "Total Rolls: " .. tostring(session.successful or 0))
	setText(quirkMoneyLine, "Money: $" .. formatMoney(getMoneyBalance()))
	local targets = getTargets(QuirkReroll.mode, quirkUnitDropdown)
	local done = 0
	for _, key in ipairs(targets) do
		if session.completed[key] or session.skipped[key] then done += 1 end
	end
	setText(quirkCompletedLine, ("Completed Units: %d / %d"):format(done, #targets))
	queueUi(function() quirkUnitDropdown.SetDimmed(QuirkReroll.mode == "All Equipped") end)
end

local function refreshFuseStats()
	setText(fuseMoneyLine, "Money: $" .. formatMoney(getMoneyBalance()))
	setText(fuseRarityLine, "Fusing: " .. (UnitFuse.currentRarity ~= "" and UnitFuse.currentRarity or "-"))
	setText(fuseBestLine, "Best: " .. (UnitFuse.bestResult ~= "" and UnitFuse.bestResult or "-"))
end

task.spawn(function()
	local n = 0
	while ctx.Alive do
		pcall(function()
			if loadCore() then
				if n % 6 == 0 then refreshOptions() end
				refreshTraitStats()
				refreshGradeStats()
				if loadQuirk() then refreshQuirkStats() end
				refreshFuseStats()
			end
		end)
		n += 1
		task.wait(0.5)
	end
end)

ctx.CleanupHandlers.reroll = function()
	TraitReroll.token += 1
	GradeReroll.token += 1
	QuirkReroll.token += 1
	UnitFuse.token += 1
	UnitFuse.pending = nil
	setSkipFuseAnimation(false)
	pcall(function() optionsEvent:Destroy() end)
end
end
