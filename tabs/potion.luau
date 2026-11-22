return function(ctx)
local ReplicatedStorage, State, gui = ctx.ReplicatedStorage, ctx.State, ctx.gui
local player, AutumnTravel = ctx.player, ctx.AutumnTravel
local AutoPotion = ctx.AutoPotion or {}
ctx.AutoPotion = AutoPotion
local addTab, makeCard, makeToggle = ctx.addTab, ctx.makeCard, ctx.makeToggle
local create, THEME, makeDropdown = ctx.create, ctx.THEME, ctx.makeDropdown
local POTION_CATEGORIES = {
	Luck = { buffKey = "Luck" },
	Income = { buffKey = "Money Multiplier" },
	Damage = { buffKey = "Damage Multiplier" },
}
local potionSelection = { mode = "By Category", category = "Luck", name = nil }
AutoPotion.pendingFamilies = AutoPotion.pendingFamilies or {}
AutoPotion.lastSelectedByFamily = AutoPotion.lastSelectedByFamily or {}
local potionModules, potionToken = nil, 0
local potionRefreshSignature = nil
local fuseBusy, fuseToken = false, 0
local selectedFusePotions = {}

local function loadPotionModules()
	if potionModules then return potionModules end
	local features = ReplicatedStorage.Framework.Features
	potionModules = {
		registry = require(features.Inventory.EntryRegistry),
		data = require(features.Data.DataController),
		boost = require(features.Inventory.Kinds.Boost.BoostController),
	}
	return potionModules
end

local function getPotionNames()
	local names = {}
	local registry = loadPotionModules().registry
	for name, config in registry.allEntries() do
		if type(config) == "table" and config.kind == "Boost" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

local function getFusablePotionNames()
	local features = ReplicatedStorage.Framework.Features
	local registry = loadPotionModules().registry
	local fusing = require(features.PotionFusing.PotionFusingUtil)
	local potions = {}
	for name, config in registry.allEntries() do
		if config.kind == "Boost" and config.category and config.tier and fusing.GetNextTier(name) then
			table.insert(potions, name)
		end
	end
	table.sort(potions)
	return potions
end

local function getEligibleFusePotions(onlySelected, fusing, data, registry)
	local eligible = {}
	for _, entry in data.Inventory() do
		if type(entry) == "table" and type(entry.name) == "string"
			and (not onlySelected or selectedFusePotions[entry.name])
			and (tonumber(entry.amount) or 0) >= fusing.FUSE_COST
			and fusing.GetNextTier(entry.name) then
			local ok, config = pcall(registry.expectEntryConfig, entry.name)
			if ok and config and tonumber(config.tier) then
				table.insert(eligible, {
					name = entry.name,
					amount = tonumber(entry.amount),
					tier = tonumber(config.tier),
				})
			end
		end
	end
	table.sort(eligible, function(a, b)
		if a.tier ~= b.tier then return a.tier < b.tier end
		return a.name < b.name
	end)
	return eligible
end

local function fusePotions(onlySelected, shouldContinue)
	local features = ReplicatedStorage.Framework.Features
	local data = loadPotionModules().data
	local registry = loadPotionModules().registry
	local fusing = require(features.PotionFusing.PotionFusingUtil)
	require(features.Inventory.EntryTypes)
	local network = require(ReplicatedStorage.Packages.Network)
	local fuse = network.ClientComm.new(ReplicatedStorage.Network, false, "PotionFusingService"):GetFunction("Fuse")
	local eligible = getEligibleFusePotions(onlySelected, fusing, data, registry)
	if #eligible == 0 then return 0 end

	local owner = {}
	if not AutumnTravel.acquire(owner, shouldContinue) then error("Could not acquire the shared travel lock.", 0) end
	local total = 0
	local ok, err = pcall(function()
		if not shouldContinue() then return end
		local arrived, travelErr = AutumnTravel.ensureInAutumnWorld(shouldContinue)
		if not arrived then error(travelErr or "Could not enter Autumn World.", 0) end
		local moved, moveErr = AutumnTravel.pivotToZone("PotionFusing", shouldContinue, 15)
		if not moved then error(moveErr or "Could not reach the Potion Fuser.", 0) end
		while shouldContinue() do
			eligible = getEligibleFusePotions(onlySelected, fusing, data, registry)
			if #eligible == 0 then break end
			local tier, request, count = eligible[1].tier, {}, 0
			for _, entry in ipairs(eligible) do
				if entry.tier ~= tier then break end
				local amount = math.floor(entry.amount / fusing.FUSE_COST)
				if amount > 0 then request[entry.name], count = amount, count + amount end
			end
			if next(request) == nil then break end
			local called, result, message = pcall(fuse, request)
			if not called then error("Fusion request failed, please try again.", 0) end
			if result ~= true then error(type(message) == "string" and message or "Fusion failed, please try again.", 0) end
			total += count
			task.wait(0.25)
		end
	end)
	AutumnTravel.release(owner)
	if not ok then error(err, 0) end
	return total
end

local function runFuse(onlySelected)
	if fuseBusy then return end
	fuseBusy = true
	local ok, total = pcall(fusePotions, onlySelected, function()
		return ctx.Alive and gui.Parent ~= nil
	end)
	fuseBusy = false
	if not ok then ctx.notify("error", "Auto fuse failed: " .. tostring(total))
	elseif total > 0 then ctx.notify("success", ("Fused %d new potions!"):format(total))
	elseif ctx.Alive and gui.Parent then
		ctx.notify("error", "No potions are eligible for fusing!")
	end
end

local function setAutoFuse(enabled)
	fuseToken += 1
	if not enabled then return end
	local token = fuseToken
	task.spawn(function()
		while token == fuseToken and State.Features.AutoFusePotion and gui.Parent do
			task.wait(0.5)
			if token == fuseToken and not fuseBusy then
				local ok, total = pcall(fusePotions, true, function()
					return token == fuseToken and State.Features.AutoFusePotion and gui.Parent ~= nil
				end)
				if not ok then ctx.notify("error", "Auto fuse failed: " .. tostring(total))
				elseif total > 0 then ctx.notify("success", ("Auto fused %d new potions!"):format(total)) end
			end
		end
	end)
end

local function potionInventory()
	local inventory = loadPotionModules().data.Inventory()
	return type(inventory) == "table" and inventory or {}
end

local function potionActiveFamilies()
	local modules = loadPotionModules()
	local entries = modules.data.ActiveEntries()
	local active = {}
	if type(entries) ~= "table" then return active end
	for key, entry in entries do
		local name = type(entry) == "table" and entry.name or (type(key) == "string" and key or nil)
		if name then
			local config = modules.registry.getEntryConfig(name)
			if config and config.kind == "Boost" and config.category then
				active[config.category] = true
			end
		end
	end
	return active
end

local function getPotionsToUse(active, pending)
	local modules = loadPotionModules()
	local owned = {}
	for _, item in potionInventory() do
		if type(item) == "table" and item.name then
			owned[item.name] = (owned[item.name] or 0) + (tonumber(item.amount) or 0)
		end
	end

	local byFamily = {}
	local function add(family, candidate, preferHighestTier)
		if active[family] or pending[family] then return end
		local list = byFamily[family]
		if not list then list = {}; byFamily[family] = list end
		if preferHighestTier then
			local current = list[1]
			if not current or candidate.tier > current.tier then list[1] = candidate end
		else
			table.insert(list, candidate)
		end
	end

	if potionSelection.mode == "Selected" then
		for name, selected in pairs(potionSelection.names or {}) do
			if selected and (owned[name] or 0) > 0 then
				local config = modules.registry.getEntryConfig(name)
				if config and config.kind == "Boost" and config.category then
					add(config.category, { name = name, family = config.category, tier = tonumber(config.tier) or 0 }, false)
				end
			end
		end
		local candidates = {}
		for family, list in pairs(byFamily) do
			table.sort(list, function(a, b)
				if a.tier ~= b.tier then return a.tier > b.tier end
				return a.name < b.name
			end)
			local last = AutoPotion.lastSelectedByFamily[family]
			local nextIndex = 1
			for index, candidate in ipairs(list) do
				if candidate.name == last then nextIndex = (index % #list) + 1 break end
			end
			table.insert(candidates, list[nextIndex])
		end
		return candidates
	end

	local category = POTION_CATEGORIES[potionSelection.category]
	if not category then return {} end
	for name, amount in pairs(owned) do
		if amount > 0 then
			local config = modules.registry.getEntryConfig(name)
			local buff = config and config.buffs and config.buffs[category.buffKey]
			if config and config.kind == "Boost" and config.category and buff and buff.bucket == "multiplier" then
				add(config.category, {
					name = name, family = config.category, tier = tonumber(config.tier) or 0,
					amount = tonumber(buff.amount) or 0,
				}, true)
			end
		end
	end
	local candidates = {}
	for _, list in pairs(byFamily) do table.insert(candidates, list[1]) end
	return candidates
end
AutoPotion.setEnabled = function(enabled)
	potionToken += 1
	if not enabled then return end
	local token = potionToken
	task.spawn(function()
		while token == potionToken and State.Features.AutoPotion do
			local ok = pcall(function()
				local now = os.clock()
				local active = potionActiveFamilies()
				local pending = AutoPotion.pendingFamilies
				for family, state in pairs(pending) do
					if active[family] then
						state.seen = true
					elseif state.seen or now - state.started >= 10 then
						pending[family] = nil
					end
				end

				local candidates = getPotionsToUse(active, pending)
				local activated = {}
				for _, candidate in ipairs(candidates) do
					if not activated[candidate.family] and not active[candidate.family] and not pending[candidate.family]
						and token == potionToken and State.Features.AutoPotion then
						local called, result = pcall(loadPotionModules().boost.UseBoost, candidate.name, 1)
						if called and result ~= false then
							pending[candidate.family] = { started = now, seen = false }
							activated[candidate.family] = true
							if potionSelection.mode == "Selected" then
								AutoPotion.lastSelectedByFamily[candidate.family] = candidate.name
							end
						end
					end
				end
			end)
			task.wait(ok and 1 or 2)
		end
	end)
end
local potionTab = addTab(2, "Potion")
local potionBody = makeCard(potionTab.left, function(tile)
	create("TextLabel", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "✦",
		Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = THEME.accent, Parent = tile,
	})
end, "Auto Potion")
local potionModeDropdown = makeDropdown(potionBody, 1, {
	label = "Use Mode",
	onSelect = function(value) potionSelection.mode = value end,
})
potionModeDropdown.SetOptions({ "By Category", "Selected" })
potionModeDropdown.SetValue(potionSelection.mode)
local potionCategoryDropdown = makeDropdown(potionBody, 2, {
	label = "Category",
	onSelect = function(value) potionSelection.category = value end,
})
potionCategoryDropdown.SetOptions({ "Luck", "Income", "Damage" })
potionCategoryDropdown.SetValue(potionSelection.category)
local potionDropdown = makeDropdown(potionBody, 3, {
	label = "Potions",
	multi = true,
	searchable = true,
	placeholder = "Select Potions...",
	emptyText = "No potions found",
	maxHeight = 180,
	onChange = function(selected) potionSelection.names = selected end,
})
potionSelection.names = potionDropdown.selected
local function applyPotionOptions(names)
	potionDropdown.SetOptions(names)
	potionSelection.names = potionDropdown.selected
end
AutoPotion.refreshEvent = Instance.new("BindableEvent")
AutoPotion.refreshConnection = AutoPotion.refreshEvent.Event:Connect(function(names, signature)
	if not ctx.Alive then return end
	local ok, err = pcall(applyPotionOptions, names)
	if not ok then
		warn("[Auto Potion] Dropdown refresh failed: " .. tostring(err))
		return
	end
	potionRefreshSignature = signature
end)
AutoPotion.refreshOptions = function()
	if not ctx.Alive then return end
	local ok, names = pcall(getPotionNames)
	if not ok then return end
	local signature = table.concat(names, "\0")
	if ctx.Alive and signature ~= potionRefreshSignature then
		AutoPotion.refreshEvent:Fire(names, signature)
	end
end
AutoPotion.refreshOptions()
task.spawn(function()
	while ctx.Alive and gui.Parent do
		task.wait(5)
		if gui.Parent then AutoPotion.refreshOptions() end
	end
end)
makeToggle(potionBody, 4, "Auto Use", "AutoPotion")

local fuseBody = makeCard(potionTab.left, function(tile)
	create("TextLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "⚗", Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = THEME.accent, Parent = tile })
end, "Auto Fuse Potion", 2)
local fuseDropdown = makeDropdown(fuseBody, 1, {
	label = "Potions to Fuse", multi = true, searchable = true,
	placeholder = "Select Potions...", emptyText = "No fusable potions found", maxHeight = 180,
	onChange = function(selected) selectedFusePotions = selected end,
})
local fuseOptions = getFusablePotionNames()
fuseDropdown.SetOptions(fuseOptions)
selectedFusePotions = fuseDropdown.selected
makeToggle(fuseBody, 2, "Auto Fuse Potion", "AutoFusePotion")
local fuseAll = create("TextButton", {
	LayoutOrder = 3, Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = THEME.accentDim,
	Text = "Fuse All Potions", Font = Enum.Font.GothamBold, TextSize = 12,
	TextColor3 = THEME.text, AutoButtonColor = true, Parent = fuseBody,
}, { ctx.corner(8), ctx.stroke(THEME.stroke) })
fuseAll.Activated:Connect(function() task.spawn(runFuse, false) end)
ctx.FeatureHandlers.AutoFusePotion = setAutoFuse
if State.Features.AutoFusePotion then setAutoFuse(true) end
ctx.FeatureHandlers.AutoPotion = AutoPotion.setEnabled
ctx.CleanupHandlers.potion = function()
	if AutoPotion.refreshConnection then pcall(function() AutoPotion.refreshConnection:Disconnect() end) end
	if AutoPotion.refreshEvent then pcall(function() AutoPotion.refreshEvent:Destroy() end) end
end


end
