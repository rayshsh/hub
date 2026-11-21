return function(ctx)
local ReplicatedStorage, State, gui = ctx.ReplicatedStorage, ctx.State, ctx.gui
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
AutoPotion.refreshConnection = AutoPotion.refreshEvent.Event:Connect(applyPotionOptions)
AutoPotion.refreshOptions = function()
	local ok, names = pcall(getPotionNames)
	if not ok then return end
	local signature = table.concat(names, "\0")
	if signature ~= potionRefreshSignature then
		potionRefreshSignature = signature
		AutoPotion.refreshEvent:Fire(names)
	end
end
AutoPotion.refreshOptions()
task.spawn(function()
	while gui.Parent do
		task.wait(5)
		if gui.Parent then AutoPotion.refreshOptions() end
	end
end)
makeToggle(potionBody, 4, "Auto Use", "AutoPotion")
ctx.FeatureHandlers.AutoPotion = AutoPotion.setEnabled
ctx.CleanupHandlers.potion = function()
	if AutoPotion.refreshConnection then pcall(function() AutoPotion.refreshConnection:Disconnect() end) end
	if AutoPotion.refreshEvent then pcall(function() AutoPotion.refreshEvent:Destroy() end) end
end


end