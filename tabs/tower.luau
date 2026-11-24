return function(ctx)
local ReplicatedStorage, State, CONFIG, notify = ctx.ReplicatedStorage, ctx.State, ctx.CONFIG, ctx.notify
local TOWER_MODES = ctx.TOWER_MODES
local BLUE, YELLOW, ORANGE, GRAY, RED = ctx.BLUE, ctx.YELLOW, ctx.ORANGE, ctx.GRAY, ctx.RED
local TOWER_STATUS = {
	Off             = { text = "Auto Tower: Off",                         color = GRAY },
	WaitingData     = { text = "Waiting for Player Data",                 color = GRAY },
	SingleStarting  = { text = "Single: Starting Selected Tower",         color = BLUE },
	SingleProgress  = { text = "Single: Tower In Progress",               color = YELLOW },
	SingleLocked    = { text = "Single: Tower Locked",                    color = ORANGE },
	BestSearching   = { text = "Best Leaf Tower: Searching",              color = BLUE },
	BestSelected    = { text = "Best Leaf Tower: Tower Selected",         color = BLUE },
	BestProgress    = { text = "Best Leaf Tower: Tower In Progress",      color = YELLOW },
	NoUnit          = { text = "No Unit Available",                       color = ORANGE },
	NoTowers        = { text = "No Suitable Tower",                       color = ORANGE },
	Error           = { text = "Error",                                   color = RED },
}

local function SetTowerStatus(key, detail)
	if State.TowerStatus == key and State.TowerDetail == (detail or "") then
		return
	end
	State.TowerStatus = key
	State.TowerDetail = detail or ""
	notify()
end

local TurkeyTowers, Towers, TowerController, DataController, BuffController, EntryRegistry
local RESTART_COOLDOWN = CONFIG.TowerRestartCooldown

local Tower = {
	loaded = false,
	lastLoadTry = -math.huge,
	loadError = nil,

	names = {},               
	options = {},
	displayByName = {},
	optionToName = {},
	catalog = {},
	activeName = nil,         
	lastStarted = false,      
	lockedSince = 0,          
	bestExtra = nil,          

	selectionEpoch = 0,       
	startInFlight = false,    
	workerActive = false,     
	wake = false,             
}

local towerRunId = 0
local lastAttemptTime = 0

local function towerAlive(id)
	return towerRunId == id and State.Features.AutoTower
end

local function loadTowerModules()
	if Tower.loaded then return true end
	if os.clock() - Tower.lastLoadTry < 3 then return false end
	Tower.lastLoadTry = os.clock()

	local ok, err = pcall(function()
		local features = ReplicatedStorage.Framework.Features
		local tt = require(features.Autumn.TurkeyTowers)
		local towers = require(features.Towers.Towers)
		local tc = require(features.Towers.TowerController)
		local dc = require(features.Data.DataController)
		local bc = require(features.Buffs.BuffController)
		local er = require(features.Inventory.EntryRegistry)
		TurkeyTowers, Towers, TowerController, DataController, BuffController, EntryRegistry = tt, towers, tc, dc, bc, er
	end)

	if not ok then
		Tower.loadError = tostring(err)
		return false
	end
	Tower.loaded = true
	Tower.loadError = nil
	return true
end

local function getMilestones()
	if not DataController then return nil end
	local ok, result = pcall(function()
		return DataController.Autumn.Milestones()
	end)

	if ok and type(result) == "table" then
		return result
	end

	return nil
end

local function findSectionByName(name)
	if not TurkeyTowers then return nil end
	for index, section in ipairs(TurkeyTowers.Sections) do
		if section.name == name then
			return section, index
		end
	end
	return nil
end

local function getBestUnit()
	if not DataController or not EntryRegistry then
		return nil, "unavailable"
	end

	local ok, best = pcall(function()
		local found = nil

		for key in DataController.Inventory() do
			local entry = DataController.Inventory[key]()
			if entry then
				local config = EntryRegistry.getEntryConfig(entry.name)
				if config and config.kind == "Unit" then
					local damage = config.damage(entry.attributes)

					if type(damage) == "number" and (not found or damage > found.damage) then
						found = {
							key = key,
							name = entry.name,
							damage = damage,
							health = config.health(entry.attributes),
						}
					end
				end
			end
		end

		return found
	end)

	if not ok then
		return nil, "unavailable"
	end
	if best then
		return best
	end
	return nil, "none"
end

local function getBuff(name)
	local ok, value = pcall(function()
		return BuffController.GetBuff(name)
	end)
	if ok and type(value) == "number" then
		return value
	end
	return 1
end

local function canDefeatFloor(section, floor, unit)
	local ok, enemyHealth, enemyDamage = pcall(function()
		return TurkeyTowers.EnemyHealth(section, floor), TurkeyTowers.EnemyDamage(section, floor)
	end)
	if not ok or type(enemyHealth) ~= "number" or type(enemyDamage) ~= "number" then
		return false
	end

	local damage = unit.damage * getBuff("Damage Multiplier")
	local health = (unit.health or 0) * getBuff("Health Multiplier")

	if damage <= 0 then
		return false 
	end

	local turnsNeeded = math.ceil(enemyHealth / damage)
	local damageTaken = (turnsNeeded - 1) * enemyDamage

	return health > damageTaken
end

local function canBestUnitDefeatFloor(section, floor)
	local bestUnit = getBestUnit()
	if not bestUnit then
		return false
	end

	return canDefeatFloor(section, floor or 1, bestUnit)
end

local isRunActive 

local function findNextSection()
	local milestones = getMilestones()
	if not milestones then
		return nil, "unavailable"
	end

	local unit, unitReason = getBestUnit()
	if not unit then
		return nil, (unitReason == "none") and "nounit" or "unavailable"
	end

	local pick = nil
	for index, section in ipairs(TurkeyTowers.Sections) do
		local okU, unlocked = pcall(TurkeyTowers.IsUnlocked, milestones, index)
		if okU and unlocked and canDefeatFloor(section, 1, unit) then
			pick = section
			if CONFIG.BestTowerPreference == "First" then
				break
			end
		end
	end

	if pick then
		return pick, unit
	end
	return nil, "none"
end

local function currentRunLocked()
	if not Tower.activeName then
		return false
	end

	local active = isRunActive()
	if active == true then
		return true
	end
	if active == nil and Tower.lastStarted and os.clock() - Tower.lockedSince < CONFIG.BestReevalInterval then
		return true
	end
	return false
end

local function selectBest()
	if currentRunLocked() then
		local locked = findSectionByName(Tower.activeName)
		if locked then
			return locked, nil, Tower.bestExtra
		end
	end

	local section, unitOrReason = findNextSection()
	if section then
		Tower.bestExtra = ("best unit: %s"):format(tostring(unitOrReason.name))
		return section, nil, Tower.bestExtra
	end

	if unitOrReason == "unavailable" then
		return nil, "WaitingData", "Player data is not loaded yet."
	elseif unitOrReason == "nounit" then
		return nil, "NoUnit", "You don't own any units."
	end
	return nil, "NoTowers", "The best unit cannot defeat floor 1 of any unlocked tower."
end

local function selectSingle(milestones)
	local name = State.SelectedTower
	if type(name) ~= "string" or name == "" then
		return nil, "Error", "No tower selected."
	end

	local section, index = findSectionByName(name)
	if section then
		if not milestones then
			return nil, "WaitingData", "Player data is not loaded yet."
		end
		local okU, unlocked = pcall(TurkeyTowers.IsUnlocked, milestones, index)
		if not okU then
			return nil, "Error", "Could not check whether the tower is unlocked."
		end
		if not unlocked then
			return nil, "SingleLocked", ("%s is locked."):format(name)
		end
		return section
	end

	if Towers and Tower.catalog[name] then
		return Tower.catalog[name]
	end
	return nil, "Error", ("\"%s\" is not an available tower."):format(name)
end

function isRunActive()
	if CONFIG.IsRunActive then
		local ok, result = pcall(CONFIG.IsRunActive)
		if ok and type(result) == "boolean" then
			return result
		end
		return nil
	end

	if TowerController then
		for _, fnName in ipairs(CONFIG.RunActiveCandidates) do
			local fn = TowerController[fnName]
			if type(fn) == "function" then
				local ok, result = pcall(fn)
				if ok and type(result) == "boolean" then
					return result
				end
			end
		end
	end

	return nil
end

local Equip = { signal = nil }

local function getEquipSignal()
	if Equip.signal then
		return Equip.signal
	end

	local ok, result = pcall(function()
		local Network = require(ReplicatedStorage.Packages.Network)
		local comm = Network.ClientComm.new(ReplicatedStorage.Network, false, "Towers")
		return comm:GetSignal("EquipBestTowerTeam")
	end)

	if ok and result then
		Equip.signal = result
		return result
	end
	return nil, tostring(result)
end

local function equipBestTeam()
	local signal, err = getEquipSignal()
	if not signal then
		return false, err or "EquipBestTowerTeam signal not found"
	end

	local ok, fireErr = pcall(function()
		signal:Fire()
	end)
	if not ok then
		return false, tostring(fireErr)
	end
	return true
end

local function tryStartTower(section, doEquip)
	if Tower.startInFlight then
		return false, "busy"
	end

	local now = os.clock()
	if now - lastAttemptTime < RESTART_COOLDOWN then
		return false, "cooldown"
	end

	lastAttemptTime = now
	Tower.startInFlight = true

	if doEquip then
		local epoch = Tower.selectionEpoch
		local equipped, equipErr = equipBestTeam()
		if not equipped then
			Tower.startInFlight = false
			return false, "equip failed: " .. tostring(equipErr)
		end

		task.wait(CONFIG.EquipDelay)

		if not State.Features.AutoTower or Tower.selectionEpoch ~= epoch then
			Tower.startInFlight = false
			return false, "cancelled"
		end
	end

	local ok, result = pcall(TowerController.startTower, section.name)
	Tower.startInFlight = false

	if ok and result == true then
		return true
	end
	if ok then
		return false, "declined"
	end
	return false, "error: " .. tostring(result)
end

local function driveTower(mode, section, extra)
	local single = (mode == "Single")
	local progressKey = single and "SingleProgress" or "BestProgress"
	local startKey = single and "SingleStarting" or "BestSelected"
	local detail = extra and (section.name .. " - " .. extra) or section.name

	if Tower.activeName ~= section.name then
		Tower.activeName = section.name
		Tower.lastStarted = false
	end

	local active = isRunActive()
	if active == true then
		Tower.lastStarted = true
		SetTowerStatus(progressKey, detail)
		return
	end

	if Tower.startInFlight or os.clock() - lastAttemptTime < RESTART_COOLDOWN then
		SetTowerStatus(Tower.lastStarted and progressKey or startKey, detail)
		return
	end

	local wasRunning = Tower.lastStarted
	local doEquip = State.Features.AutoEquipBest
		and (active == false or not wasRunning or CONFIG.EquipOnProbe)

	Tower.lastStarted = false
	SetTowerStatus(startKey, doEquip and (detail .. " - equipping best team") or detail)

	local started, reason = tryStartTower(section, doEquip)
	if started then
		Tower.lastStarted = true
		Tower.lockedSince = os.clock()
		SetTowerStatus(progressKey, detail)
	elseif reason == "cooldown" or reason == "busy" or reason == "cancelled" then
		-- nothing to do
	elseif reason == "declined" then
		if active == false then
			SetTowerStatus("Error", ("%s: the game declined to start the tower."):format(section.name))
		else
			Tower.lastStarted = true
			SetTowerStatus(progressKey, detail .. " (start declined, run likely active)")
		end
	else
		SetTowerStatus("Error", ("%s: %s"):format(section.name, reason))
	end
end

local function towerTick()
	if not loadTowerModules() then
		if not Tower.loaded then
			SetTowerStatus("Error", "Tower modules unavailable: " .. tostring(Tower.loadError or "retrying..."))
		end
		return
	end

	local mode = State.TowerMode
	local section, key, detail

	if mode == "Single" then
		section, key, detail = selectSingle(getMilestones())
	else
		mode = "Best Leaf Tower"
		section, key, detail = selectBest()
	end

	if not section then
		Tower.activeName = nil
		SetTowerStatus(key, detail)
		return
	end

	driveTower(mode, section, detail)
end

local function towerWorker(id)
	while Tower.workerActive do
		if not towerAlive(id) then return end
		task.wait(0.05)
	end
	if not towerAlive(id) then return end

	Tower.workerActive = true
	while towerAlive(id) do
		local ok, err = pcall(towerTick)
		if not ok then
			warn("[RayHub] Tower error: " .. tostring(err))
			SetTowerStatus("Error", tostring(err))
		end

		local t0 = os.clock()
		while towerAlive(id) and not Tower.wake and os.clock() - t0 < CONFIG.TowerTickInterval do
			task.wait(0.05)
		end
		Tower.wake = false
	end
	Tower.workerActive = false
end

local function resetTowerRuntime()
	Tower.selectionEpoch += 1
	Tower.activeName = nil
	Tower.lastStarted = false
	Tower.lockedSince = 0
	Tower.bestExtra = nil
	Tower.wake = true
end

local function SetTowerMode(mode)
	if not table.find(TOWER_MODES, mode) or State.TowerMode == mode then return end
	State.TowerMode = mode
	resetTowerRuntime()
	if State.Features.AutoTower then
		SetTowerStatus(mode == "Single" and "SingleStarting" or "BestSearching", "Mode changed to " .. mode .. ".")
	end
	notify()
end

local function SetSelectedTower(name)
	if type(name) ~= "string" then return end
	name = Tower.optionToName[name] or name
	if not table.find(Tower.names, name) or State.SelectedTower == name then return end
	State.SelectedTower = name
	Tower.selectionEpoch += 1
	Tower.activeName = nil
	Tower.lastStarted = false
	Tower.wake = true
	notify()
end

local FloorTracker = { label = nil, labelConn = nil, original = nil, wrapped = false, alive = true }

local function readFloorText(text)
	return tonumber(tostring(text):match("Floor%s+(%d+)"))
end

local function updateFloor()
	local label = FloorTracker.label
	if not label then return end
	local floor = readFloorText(label.Text)
	if not floor then return end

	local S = State.TowerStats
	if S.LastFloor then
		if floor > S.LastFloor then
			S.Floors += floor - S.LastFloor
		elseif floor < S.LastFloor then
			S.LastFloor = nil 
		end
	end
	S.Best = math.max(S.Best, floor)
	S.LastFloor = floor
	S.Floor = floor
	S.Tracking = true
	notify()
end

local function connectFloorLabel()
	if FloorTracker.label then return true end
	local ok, label = pcall(function()
		local features = ReplicatedStorage.Framework.Features
		local UIReferences = require(features.UI.UIReferences)
		return UIReferences.Root.Tower.Screen.Floor
	end)
	if not ok or typeof(label) ~= "Instance" then return false end

	FloorTracker.label = label
	FloorTracker.labelConn = label:GetPropertyChangedSignal("Text"):Connect(updateFloor)
	updateFloor()
	return true
end

local function wrapStartTower()
	if FloorTracker.wrapped then return true end
	if not loadTowerModules() or not TowerController then return false end
	local original = TowerController.startTower
	if type(original) ~= "function" then return false end

	FloorTracker.original = original
	TowerController.startTower = function(...)
		local result = table.pack(original(...))
		if result[1] then
			local S = State.TowerStats
			S.Runs += 1
			S.LastFloor = nil
			S.Floor = nil
			notify()
		end
		return table.unpack(result, 1, result.n)
	end
	FloorTracker.wrapped = true
	return true
end

local function uninstallFloorHook()
	FloorTracker.alive = false
	if FloorTracker.labelConn then
		FloorTracker.labelConn:Disconnect()
		FloorTracker.labelConn = nil
	end
	if FloorTracker.wrapped and TowerController and FloorTracker.original then
		pcall(function() TowerController.startTower = FloorTracker.original end)
		FloorTracker.wrapped = false
	end
end

task.spawn(function()
	while FloorTracker.alive do
		local labelOk = connectFloorLabel()
		local wrapOk = wrapStartTower()
		if labelOk and wrapOk then break end
		task.wait(2)
	end
end)

local lastSignature, pendingSignature = nil, nil
local towerOptionsEvent = Instance.new("BindableEvent")
table.insert(ctx.connections, towerOptionsEvent.Event:Connect(function(options, signature)
	if not ctx.Alive or pendingSignature ~= signature or not ctx.TowerUI.towerDropdown then return end
	local ok, err = pcall(ctx.TowerUI.towerDropdown.SetOptions, options)
	if not ok then
		pendingSignature = nil
		warn("[Auto Tower] Dropdown refresh failed: " .. tostring(err))
		return
	end
	lastSignature, pendingSignature = signature, nil
end))

local function refreshTowerOptions()
	if not ctx.Alive then return end
	if not loadTowerModules() then return end
	if not ctx.Alive then return end

	local ok, all = pcall(Towers.GetAll)
	if not ok or type(all) ~= "table" then return end

	local turkeyNames, catalog = {}, {}
	for _, section in ipairs(TurkeyTowers.Sections) do
		if type(section) == "table" and type(section.name) == "string" then
			turkeyNames[section.name] = true
		end
	end

	for key, tower in pairs(all) do
		local name = type(tower) == "table" and (tower.name or tower.Name) or tower
		name = type(name) == "string" and name or (type(key) == "string" and key or nil)
		if name then
			local order = type(tower) == "table" and tonumber(tower.order or tower.Order) or nil
			catalog[name] = { name = name, order = order or math.huge }
		end
	end

	local entries = {}
	for _, tower in pairs(catalog) do table.insert(entries, tower) end
	table.sort(entries, function(a, b)
		if a.order == b.order then return a.name < b.name end
		return a.order < b.order
	end)

	local names, options, displayByName, optionToName = {}, {}, {}, {}
	for _, tower in ipairs(entries) do
		local name = tower.name
		local display = turkeyNames[name] and ("Turkey · " .. name) or name
		table.insert(names, name)
		table.insert(options, display)
		displayByName[name] = display
		optionToName[display] = name
	end

	local signature = table.concat(options, "\n")
	if signature == lastSignature or signature == pendingSignature then return end
	if not ctx.Alive then return end
	pendingSignature = signature

	Tower.names, Tower.options = names, options
	Tower.displayByName, Tower.optionToName, Tower.catalog = displayByName, optionToName, catalog
	if Tower.pendingConfigSelection then
		if table.find(names, Tower.pendingConfigSelection) then
			State.SelectedTower = Tower.pendingConfigSelection
		end
		Tower.pendingConfigSelection = nil
	end
	towerOptionsEvent:Fire(options, signature)

	if not State.SelectedTower or not table.find(names, State.SelectedTower) then
		State.SelectedTower = names[1]
		Tower.activeName = nil
		Tower.lastStarted = false
	end
	Tower.wake = true
	notify()
end

local addTab, makeCard, makeToggle = ctx.addTab, ctx.makeCard, ctx.makeToggle
local create, THEME, pill = ctx.create, ctx.THEME, ctx.pill
local makeDropdown, makeLine, vlist = ctx.makeDropdown, ctx.makeLine, ctx.vlist
ctx.TowerUI = {}
local towerTab = addTab(3, "Tower")
local towerBody = makeCard(towerTab.left, function(tile)
	for _, rot in ipairs({ 45, -45 }) do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(3, 17),
			Rotation = rot,
			BackgroundColor3 = THEME.accent,
			BorderSizePixel = 0,
			Parent = tile,
		}, { pill() })
	end
end, "Auto Tower")

local modeDropdown = makeDropdown(towerBody, 1, {
	label = "Mode",
	onSelect = function(choice) SetTowerMode(choice) end,
})
modeDropdown.SetOptions(TOWER_MODES)

local towerDropdown = makeDropdown(towerBody, 2, {
	label = "Tower",
	emptyText = "No towers found",
	onSelect = function(choice) SetSelectedTower(choice) end,
})
towerDropdown.SetOptions({})

makeToggle(towerBody, 3, "Auto Equip Best Team", "AutoEquipBest")
makeToggle(towerBody, 4, "Auto Tower", "AutoTower")


local towerInfo = create("Frame", {
	LayoutOrder = 5,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Parent = towerBody,
}, { vlist(4) })

local towerLine = makeLine(towerInfo, 1, 12, THEME.body, Enum.Font.GothamMedium)

local statsLine = makeLine(towerInfo, 2, 10, THEME.subtext)
statsLine.TextWrapped = false
statsLine.TextTruncate = Enum.TextTruncate.AtEnd

ctx.TowerUI.modeDropdown = modeDropdown
ctx.TowerUI.towerDropdown = towerDropdown
ctx.TowerUI.towerLine = towerLine
ctx.TowerUI.statsLine = statsLine
ctx.Tower = Tower
ctx.SetTowerMode = SetTowerMode
ctx.SetSelectedTower = SetSelectedTower
Tower.setMode = SetTowerMode
Tower.setSelected = SetSelectedTower
ctx.ConfigAdapters.tower = {
	get = function()
		return { mode = State.TowerMode, selected = State.SelectedTower }
	end,
	set = function(value)
		if type(value) ~= "table" then return end
		if table.find(TOWER_MODES, value.mode) then SetTowerMode(value.mode) end
		if type(value.selected) == "string" then
			if table.find(Tower.names, value.selected) then
				SetSelectedTower(value.selected)
			else
				Tower.pendingConfigSelection = value.selected
			end
		end
	end,
}
local function refreshTowerUI()
	local S = State.TowerStats
	local floorText = S.Floor and (" floor " .. S.Floor) or ""
	towerLine.Text = Tower.activeName and ("Tower: " .. (Tower.displayByName[Tower.activeName] or Tower.activeName) .. floorText) or "Tower: -"
	statsLine.Text = ("%d Runs | %s Floors Cleared | Best Floor %s"):format(S.Runs, S.Tracking and tostring(S.Floors) or "-", (S.Tracking and S.Best > 0) and tostring(S.Best) or "-")
	modeDropdown.SetValue(State.TowerMode)
	towerDropdown.SetValue(Tower.displayByName[State.SelectedTower] or State.SelectedTower)
	towerDropdown.SetDimmed(State.TowerMode ~= "Single")
end
table.insert(ctx.refreshers, refreshTowerUI)
task.spawn(function()
	while ctx.Alive and ctx.gui.Parent do
		pcall(refreshTowerOptions)
		pcall(refreshTowerUI)
		task.wait(0.5)
	end
end)
ctx.FeatureHandlers.AutoTower = function(enabled)
	towerRunId += 1
	if enabled then
		local id = towerRunId
		resetTowerRuntime()
		SetTowerStatus(State.TowerMode == "Single" and "SingleStarting" or "BestSearching", "Starting Auto Tower.")
		task.spawn(towerWorker, id)
	else
		Tower.activeName = nil
		SetTowerStatus("Off", "Auto Tower is disabled.")
	end
end
ctx.CleanupHandlers.tower = function()
	towerRunId += 1
	uninstallFloorHook()
	pcall(function() towerOptionsEvent:Destroy() end)
end
end
