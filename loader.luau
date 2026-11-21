local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local STARTUP_DELAY = 6   
do
	if not game:IsLoaded() then game.Loaded:Wait() end

	local lp = Players.LocalPlayer
	while not lp do
		task.wait(0.25)
		lp = Players.LocalPlayer
	end

	lp:WaitForChild("PlayerGui")
	ReplicatedStorage:WaitForChild("Framework", 60) 

	local deadline = os.clock() + 30
	while not lp.Character and os.clock() < deadline do
		task.wait(0.25)
	end
	local char = lp.Character
	if char then
		char:WaitForChild("HumanoidRootPart", 15)
	end

	task.wait(STARTUP_DELAY)
end

local player = Players.LocalPlayer
local env = (getgenv and getgenv()) or _G

if env.AutumnDice and env.AutumnDice.Unload then
	pcall(env.AutumnDice.Unload)
end

local CONFIG = {
	DefaultHotkey = Enum.KeyCode.LeftControl,

	RollAmount = 5,           
	RollDelay = 0.1,          
	MaxRollErrors = 5,        
	RollErrorDelay = 3,       

	RemoteWaitTimeout = 10,
	InvokeTimeout = 15,
	StepDelay = 1,
	TeleportSettle = 2,

	ArriveDistance = 8,

	TowerRestartCooldown = 3, 
	TowerTickInterval = 1,    
	BestTowerPreference = "MostAdvanced",
	BestReevalInterval = 30,
	EquipDelay = 1,
	EquipOnProbe = false,
	IsRunActive = nil,

	RunActiveCandidates = { "isInTower", "isRunning", "isInRun", "hasActiveRun" },
}

local TOWER_MODES = { "Single", "Best Leaf Tower" }
local State = {
	Features = {
		AutoDice = false, AutoTower = false, AutoEquipBest = false, AutoQuest = false, AutoBuy = false, AutoPotion = false,
		AntiAfk = false, AutoReconnect = false, AutoClaimQuest = false,
	},
	Status = "Idle",
	Detail = "Enable \"Auto Roll Autumn Dice\" to start.",
	Hotkey = CONFIG.DefaultHotkey,
	Rolls = 0,
	RollResultPool = {},

	TowerMode = "Best Leaf Tower",
	SelectedTower = nil,
	TowerStatus = "Off",
	TowerDetail = "Auto Tower is disabled.",

	TowerStats = {
		Runs = 0,          
		Floors = 0,        
		Best = 0,          
		Floor = nil,      
		LastFloor = nil,  
		Tracking = false, 
	},
}

local listeners = {}
local function onChange(fn) table.insert(listeners, fn) end
local function notify()
	for _, fn in ipairs(listeners) do
		pcall(fn)
	end
end

local STATUS = {
	Idle             = { text = "Idle",               color = Color3.fromRGB(150, 150, 160) },
	Initializing     = { text = "Initializing",       color = Color3.fromRGB(120, 170, 255) },
	Teleporting      = { text = "Teleporting",        color = Color3.fromRGB(120, 170, 255) },
	Syncing          = { text = "Syncing",            color = Color3.fromRGB(120, 170, 255) },
	Moving           = { text = "Moving",             color = Color3.fromRGB(120, 170, 255) },
	Rolling          = { text = "Rolling",            color = Color3.fromRGB(255, 200, 80) },
	AutoRollEnabled  = { text = "Auto Roll Enabled",  color = Color3.fromRGB(90, 215, 120) },
	AutoRollDisabled = { text = "Auto Roll Disabled", color = Color3.fromRGB(255, 150, 70) },
	Error            = { text = "Error",              color = Color3.fromRGB(240, 85, 85) },
}

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
	notify()
end

local BLUE = Color3.fromRGB(120, 170, 255)
local GREEN = Color3.fromRGB(90, 215, 120)
local YELLOW = Color3.fromRGB(255, 200, 80)
local ORANGE = Color3.fromRGB(255, 150, 70)
local GRAY = Color3.fromRGB(150, 150, 160)
local RED = Color3.fromRGB(240, 85, 85)

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

local function getRemote(path, timeout, shouldContinue)
    local node = ReplicatedStorage
    for _, name in ipairs(path) do
        if shouldContinue then
            local deadline = timeout and (os.clock() + timeout)
            local child
            repeat
                if not shouldContinue() then return nil end
                child = node:FindFirstChild(name)
                if child then break end
                if deadline and os.clock() >= deadline then return nil end
                task.wait(0.05)
            until false
            node = child
        else
            node = node:WaitForChild(name, timeout)
            if not node then return nil end
        end
    end
    return node
end
local function pathString(path)
	return "ReplicatedStorage." .. table.concat(path, ".")
end

local inFlight = {}
local function invoke(remote, ...)
	local args = table.pack(...)
	local done, ok, result = false, false, nil

	local waited = os.clock()
	while inFlight[remote] do
		if os.clock() - waited > CONFIG.InvokeTimeout then
			return false, "previous call still pending"
		end
		task.wait(0.1)
	end

	inFlight[remote] = true
	task.spawn(function()
		ok, result = pcall(function()
			return remote:InvokeServer(table.unpack(args, 1, args.n))
		end)
		done = true
		inFlight[remote] = nil
	end)

	local t0 = os.clock()
	while not done do
		if os.clock() - t0 > CONFIG.InvokeTimeout then
			return false, "timed out"
		end
		task.wait(0.05)
	end
	return ok, result
end

local function getHRP(timeout)
	local deadline = os.clock() + (timeout or 0)
	repeat
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hrp and hum and hum.Health > 0 then
			return hrp
		end
		if timeout then task.wait(0.2) end
	until not timeout or os.clock() > deadline
	return nil
end

local AutumnTravel = { travelRemote = nil, traveling = false, movementOwner = nil, questRequested = false, autoQuestMoving = false, autoQuestRequested = false, autoQuestRequestCount = 0,
	buyRequested = false } 

local function canContinue(shouldContinue)
	return not shouldContinue or shouldContinue()
end

function AutumnTravel.acquire(owner, shouldContinue)
	local deadline = os.clock() + 90
	while ((AutumnTravel.movementOwner and AutumnTravel.movementOwner ~= owner) or (AutumnTravel.rollRemote and inFlight[AutumnTravel.rollRemote])) and canContinue(shouldContinue) and os.clock() < deadline do
		task.wait(0.1)
	end
	if not canContinue(shouldContinue) or os.clock() >= deadline then return false end
	AutumnTravel.movementOwner = owner
	return true
end

function AutumnTravel.release(owner)
	if AutumnTravel.movementOwner == owner then AutumnTravel.movementOwner = nil end
end
function AutumnTravel.findZone(zoneName)
	if type(zoneName) ~= "string" or zoneName == "" then return nil end
	local zones = workspace:FindFirstChild("Zones")
	local zone = zones and zones:FindFirstChild(zoneName)
	return zone and (zone:IsA("BasePart") or zone:IsA("Model")) and zone or nil
end

function AutumnTravel.isNearZone(zoneName, margin)
	local zone, root = AutumnTravel.findZone(zoneName), getHRP()
	if not zone or not root then return false end
	local frame, size = zone:IsA("Model") and zone:GetBoundingBox() or zone.CFrame, zone:IsA("Model") and select(2, zone:GetBoundingBox()) or zone.Size
	local localPosition = frame:PointToObjectSpace(root.Position)
	local half = size / 2 + Vector3.new(margin or 0, margin or 0, margin or 0)
	return math.abs(localPosition.X) <= half.X and math.abs(localPosition.Y) <= half.Y and math.abs(localPosition.Z) <= half.Z
end

function AutumnTravel.isInAutumnWorld()
	local zone = AutumnTravel.findZone("AutumnWorld")
	local root = getHRP()
	if not zone or not root then return false end
	local frame, size
	if zone:IsA("Model") then
		frame, size = zone:GetBoundingBox()
	else
		frame, size = zone.CFrame, zone.Size
	end
	local position = frame:PointToObjectSpace(root.Position)
	local half = size / 2
	return math.abs(position.X) <= half.X and math.abs(position.Y) <= half.Y and math.abs(position.Z) <= half.Z
end

function AutumnTravel.ensureInAutumnWorld(shouldContinue)
	local characterDeadline = os.clock() + 15
	while canContinue(shouldContinue) and not getHRP() and os.clock() < characterDeadline do
		task.wait(0.2)
	end
	if not canContinue(shouldContinue) then return false, "Cancelled." end
	if not getHRP() then return false, "Character not found." end
	if AutumnTravel.isInAutumnWorld() then return true end

	local waitDeadline = os.clock() + CONFIG.InvokeTimeout * 2
	while AutumnTravel.traveling and canContinue(shouldContinue) and os.clock() < waitDeadline do
		if AutumnTravel.isInAutumnWorld() then return true end
		task.wait(0.1)
	end
	if not canContinue(shouldContinue) then return false, "Cancelled." end
	if AutumnTravel.isInAutumnWorld() then return true end
	if AutumnTravel.traveling then return false, "Travel is still in progress." end

	AutumnTravel.traveling = true
	local function finish(success, reason)
		AutumnTravel.traveling = false
		return success, reason
	end

	local found, remote = pcall(function()
		return AutumnTravel.travelRemote or getRemote({ "Network", "AutumnService", "RF", "Travel" }, CONFIG.RemoteWaitTimeout, shouldContinue)
	end)
	if not found or not remote then return finish(false, "Travel remote not found.") end
	AutumnTravel.travelRemote = remote

	local called, ok, result = pcall(invoke, remote, "Autumn")
	if not called then return finish(false, tostring(ok)) end
	if not canContinue(shouldContinue) then return finish(false, "Cancelled.") end
	if not ok or result == false then return finish(false, "Travel failed: " .. tostring(result)) end

	local deadline = os.clock() + 15
	while canContinue(shouldContinue) and not AutumnTravel.isInAutumnWorld() and os.clock() < deadline do
		task.wait(0.25)
	end
	if not canContinue(shouldContinue) then return finish(false, "Cancelled.") end
	if not AutumnTravel.isInAutumnWorld() then return finish(false, "Timed out waiting for Autumn World.") end
	return finish(true)
end
function AutumnTravel.pivotToZone(zoneName, shouldContinue, margin, destinationOffset)
    local zone = AutumnTravel.findZone(zoneName)
    if not zone then return false, "Zone not found: " .. tostring(zoneName) end
    local root = getHRP(15)
    if not canContinue(shouldContinue) then return false, "Cancelled." end
    if not root then return false, "Character not found." end
    local frame, size = zone:IsA("Model") and zone:GetBoundingBox() or zone.CFrame, zone:IsA("Model") and select(2, zone:GetBoundingBox()) or zone.Size
    local offsets = zoneName == "LeafDice"
        and { Vector3.zero, Vector3.new(12, 0, 0), Vector3.new(-12, 0, 0), Vector3.new(0, 0, 12), Vector3.new(0, 0, -12) }
        or { Vector3.zero, Vector3.new(3, 0, 0), Vector3.new(-3, 0, 0), Vector3.new(0, 0, 3), Vector3.new(0, 0, -3) }
    if destinationOffset then table.insert(offsets, 1, destinationOffset) end
    local character = player.Character
    local rootOffset = character:GetPivot():ToObjectSpace(root.CFrame)
    for _, offset in ipairs(offsets) do
        if not canContinue(shouldContinue) then return false, "Cancelled." end
        local localPoint = Vector3.new(offset.X, 0, offset.Z)
        if math.abs(localPoint.X) <= size.X / 2 + (margin or 0) and math.abs(localPoint.Z) <= size.Z / 2 + (margin or 0) then
            local destination = frame * CFrame.new(localPoint)
            local ok = pcall(function() character:PivotTo(CFrame.new(destination.Position) * (root.CFrame - root.Position) * rootOffset:Inverse()) end)
            if ok then
                task.wait()
                if player.Character == character and AutumnTravel.isNearZone(zoneName, margin) then return true end
            end
        end
    end
    return false, "Could not verify arrival at zone: " .. tostring(zoneName)
end


local runId = 0               
local workerActive = false   

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
			warn("[AutumnDice] Tower error: " .. tostring(err))
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
local setAutoClaim
local AutoBuy = {} 
local AutoPotion = {} 
local setAutoQuest

local function SetFeature(name, value)
	if State.Features[name] == nil then return end
	value = value and true or false
	if State.Features[name] == value then return end
	State.Features[name] = value

	if name == "AutoDice" then
		runId += 1
		if value then
			local id = runId
			SetStatus("Initializing")
			task.spawn(worker, id)
		else
			
			SetStatus("AutoRollDisabled")
		end
	elseif name == "AutoTower" then
		towerRunId += 1
		if value then
			local id = towerRunId
			resetTowerRuntime()
			SetTowerStatus(State.TowerMode == "Single" and "SingleStarting" or "BestSearching", "Starting Auto Tower.")
			task.spawn(towerWorker, id)
		else
			Tower.activeName = nil
			SetTowerStatus("Off", "Auto Tower is disabled.")
		end
		notify()
	elseif name == "AntiAfk" then
		setAntiAfk(value)
		notify()
	elseif name == "AutoReconnect" then
		setAutoReconnect(value)
		notify()
	elseif name == "AutoClaimQuest" then
		setAutoClaim(value)
		notify()
	elseif name == "AutoQuest" then
		if setAutoQuest then setAutoQuest(value) end
		notify()
	elseif name == "AutoPotion" then
		if AutoPotion.setEnabled then AutoPotion.setEnabled(value) end
		notify()
	else
		notify()
	end
end

local function GetFeature(name)
	return State.Features[name]
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

local TweenService = game:GetService("TweenService")

local function create(class, props, children)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		inst[k] = v
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	return inst
end

local function corner(r) return create("UICorner", { CornerRadius = UDim.new(0, r or 6) }) end
local function pill() return create("UICorner", { CornerRadius = UDim.new(1, 0) }) end
local function stroke(color, thickness)
	return create("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end
local function pad(l, t, r, b)
	return create("UIPadding", {
		PaddingLeft = UDim.new(0, l), PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r), PaddingBottom = UDim.new(0, b),
	})
end
local function vlist(gap)
	return create("UIListLayout", { Padding = UDim.new(0, gap or 8), SortOrder = Enum.SortOrder.LayoutOrder })
end

local function formatNumber(n)
	local s = (n % 1 == 0) and string.format("%d", n) or string.format("%.2f", n)
	local int, frac = s:match("^(%d+)(%.?%d*)$")
	if not int then return s end
	local r = int:reverse():gsub("(%d%d%d)", "%1,")
	r = r:reverse():gsub("^,", "")
	return r .. frac
end

local function makeChevron(parent, position, color)
	local box = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = UDim2.fromOffset(12, 12),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	for _, spec in ipairs({ { 45, 3.75 }, { -45, 8.25 } }) do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(spec[2], 5.75),
			Size = UDim2.fromOffset(7, 2),
			Rotation = spec[1],
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Parent = box,
		}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	end
	return box
end

local THEME = {
	bg = Color3.fromRGB(18, 19, 22),
	card = Color3.fromRGB(26, 27, 31),
	field = Color3.fromRGB(35, 36, 41),
	popup = Color3.fromRGB(40, 41, 47),
	stroke = Color3.fromRGB(46, 47, 54),
	text = Color3.fromRGB(240, 241, 245),
	body = Color3.fromRGB(196, 198, 208),
	subtext = Color3.fromRGB(128, 130, 142),
	accent = Color3.fromRGB(255, 132, 44),
	accentDim = Color3.fromRGB(62, 38, 26),
	off = Color3.fromRGB(62, 63, 71),
	knobOn = Color3.fromRGB(20, 20, 22),
	knobOff = Color3.fromRGB(150, 152, 162),
}

local function resolveParent()
	local ok, parent = pcall(function()
		if gethui then return gethui() end
		return game:GetService("CoreGui")
	end)
	if ok and parent then return parent end
	return player:WaitForChild("PlayerGui")
end

local gui = create("ScreenGui", {
	Name = "AutumnDiceAutoRoll",
	ResetOnSpawn = false,
	IgnoreGuiInset = true, 
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
pcall(function() gui.Parent = resolveParent() end)
if not gui.Parent then gui.Parent = player:WaitForChild("PlayerGui") end

local connections = {}
local refreshers = {}

local main = create("Frame", {
	Name = "Main",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(380, 460),
	BackgroundColor3 = THEME.bg,
	BorderSizePixel = 0,
	Parent = gui,
}, {
	corner(16),
	stroke(THEME.stroke),
	pad(8, 6, 8, 8),
})

local titleBar = create("Frame", {
	LayoutOrder = 1,
	Size = UDim2.new(1, 0, 0, 20),
	BackgroundTransparency = 1,
	Parent = main,
})
create("TextLabel", {
	Size = UDim2.new(1, -36, 1, 0),
	Position = UDim2.fromOffset(4, 0),
	BackgroundTransparency = 1,
	Text = "Autumn Dice",
	Font = Enum.Font.GothamBold,
	TextSize = 11,
	TextColor3 = THEME.subtext,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = titleBar,
})
local closeBtn = create("TextButton", {
	Size = UDim2.fromOffset(20, 20),
	Position = UDim2.new(1, -20, 0.5, -10),
	BackgroundColor3 = THEME.field,
	Text = "",
	AutoButtonColor = true,
	Parent = titleBar,
}, { corner(8) })
for _, rot in ipairs({ 45, -45 }) do
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(10, 2),
		Rotation = rot,
		BackgroundColor3 = THEME.subtext,
		BorderSizePixel = 0,
		Parent = closeBtn,
	}, { create("UICorner", { CornerRadius = UDim.new(1, 0) }) })
end

local openDropdown = nil

local catcher = create("TextButton", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	Visible = false,
	ZIndex = 15,
	Parent = gui,
})

local function closeDropdowns()
	if openDropdown then
		openDropdown.Close()
		openDropdown = nil
	end
	catcher.Visible = false
end
catcher.MouseButton1Click:Connect(closeDropdowns)


local SIDEBAR_GAP = 8

local bodyRow = create("Frame", {
	Position = UDim2.fromOffset(0, 26),
	Size = UDim2.new(1, 0, 1, -52),
	BackgroundTransparency = 1,
	Parent = main,
})

local sidebar = create("ScrollingFrame", {
	Size = UDim2.new(0, 208, 1, 0),
	BackgroundColor3 = THEME.card,
	BorderSizePixel = 0,
	ScrollBarThickness = 0,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	Parent = bodyRow,
}, { corner(10), stroke(THEME.stroke), pad(6, 6, 6, 6), vlist(4) })

local content = create("ScrollingFrame", {
	Position = UDim2.fromOffset(208 + SIDEBAR_GAP, 0),
	Size = UDim2.new(1, -(208 + SIDEBAR_GAP), 1, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = THEME.accent,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	Parent = bodyRow,
}, { pad(0, 0, 6, 0) })

local COLUMN_GAP = 10
local twoColumnMode = false
local columnSets = {}

local function columnSize(two)
	return two and UDim2.new(0.5, -COLUMN_GAP / 2, 0, 0) or UDim2.new(1, 0, 0, 0)
end

local function makeColumns(parent, order)
	local layout = create("UIListLayout", {
		FillDirection = twoColumnMode and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, twoColumnMode and COLUMN_GAP or 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Top,
	})
	local container = create("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = parent,
	}, { layout })

	local function column(columnOrder)
		return create("Frame", {
			LayoutOrder = columnOrder,
			Size = columnSize(twoColumnMode),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Parent = container,
		}, { vlist(8) })
	end

	local set = { layout = layout, left = column(1), right = column(2) }
	table.insert(columnSets, set)
	return set
end

local function layoutColumnSet(set)
	local two = twoColumnMode
	set.layout.FillDirection = two and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
	set.layout.Padding = UDim.new(0, two and COLUMN_GAP or 8)
	set.left.Size = columnSize(two)
	set.right.Size = columnSize(two)
end

local function refreshColumns()
	for _, set in ipairs(columnSets) do layoutColumnSet(set) end
end

local function setColumnMode(two)
	twoColumnMode = two
	refreshColumns()
end

local function applyLayout()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local w = math.min(math.clamp(math.floor(vp.X * 0.5), 320, 640), vp.X - 16)
	local h = math.min(math.clamp(math.floor(vp.Y * 0.75), 220, 580), vp.Y - 16)
	local sideW = (w >= 340) and 208 or 176

	local contentW = w - 16 - (sideW + SIDEBAR_GAP) - 6
	setColumnMode(contentW >= 380)

	main.Size = UDim2.fromOffset(w, h)
	sidebar.Size = UDim2.new(0, sideW, 1, 0)
	content.Position = UDim2.fromOffset(sideW + SIDEBAR_GAP, 0)
	content.Size = UDim2.new(1, -(sideW + SIDEBAR_GAP), 1, 0)

	task.delay(0.1, function()
		if not main.Parent then return end
		local pos, size = main.AbsolutePosition, main.AbsoluteSize
		if pos.X < 0 or pos.Y < 0 or pos.X + size.X > vp.X or pos.Y + size.Y > vp.Y then
			main.Position = UDim2.fromScale(0.5, 0.5)
		end
	end)
end
applyLayout()

local cameraConn
local function watchCamera()
	if cameraConn then cameraConn:Disconnect() cameraConn = nil end
	local cam = workspace.CurrentCamera
	if cam then
		cameraConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayout)
		table.insert(connections, cameraConn)
	end
end
watchCamera()
table.insert(connections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	watchCamera()
	applyLayout()
end))

local tabs = {}

local function selectTab(name)
	closeDropdowns()
	content.CanvasPosition = Vector2.new(0, 0)
	for tabName, tab in pairs(tabs) do
		local on = (tabName == name)
		tab.page.Visible = on
		tab.bar.Visible = on
		tab.button.BackgroundTransparency = on and 0 or 1
		tab.label.TextColor3 = on and THEME.accent or THEME.body
	end
end

local function addTab(order, name)
	local button = create("TextButton", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = THEME.accentDim,
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = sidebar,
	}, { corner(8) })
	local bar = create("Frame", {
		Size = UDim2.fromOffset(3, 14),
		Position = UDim2.new(0, 0, 0.5, -7),
		BackgroundColor3 = THEME.accent,
		BorderSizePixel = 0,
		Visible = false,
		Parent = button,
	}, { pill() })
	local label = create("TextLabel", {
		Size = UDim2.new(1, -14, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		BackgroundTransparency = 1,
		Text = name,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = THEME.body,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = button,
	})
	local page = create("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Visible = false,
		Parent = content,
	}, { vlist(8) })

	tabs[name] = { button = button, label = label, bar = bar, page = page }
	button.MouseButton1Click:Connect(function() selectTab(name) end)
	return makeColumns(page, 1)
end

local function makeCard(parent, buildIcon, title, order)
	local card = create("Frame", {
		LayoutOrder = order or 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = THEME.card,
		BorderSizePixel = 0,
		Parent = parent,
	}, {
		corner(10),
		stroke(THEME.stroke),
		pad(10, 8, 10, 10),
		vlist(8),
	})

	local header = create("TextButton", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = card,
	})
	local tile = create("Frame", {
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = THEME.accentDim,
		BorderSizePixel = 0,
		Parent = header,
	}, { corner(8) })
	buildIcon(tile)
	create("TextLabel", {
		Size = UDim2.new(1, -62, 1, 0),
		Position = UDim2.fromOffset(36, 0),
		BackgroundTransparency = 1,
		Text = title,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = THEME.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = header,
	})
	local chevron = makeChevron(header, UDim2.new(1, -10, 0.5, 0), THEME.subtext)

	local body = create("Frame", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = card,
	}, { vlist(8) })

	header.MouseButton1Click:Connect(function()
		closeDropdowns()
		body.Visible = not body.Visible
		chevron.Rotation = body.Visible and 0 or 180
	end)

	return body
end

local function makeLine(parent, order, size, color, font)
	return create("TextLabel", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, size + 4),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = "",
		Font = font or Enum.Font.Gotham,
		TextSize = size,
		TextColor3 = color,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = parent,
	})
end

local function makeToggle(parent, order, labelText, featureName)
	local row = create("TextButton", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Parent = parent,
	})
	create("TextLabel", {
		Size = UDim2.new(1, -46, 1, 0),
		BackgroundTransparency = 1,
		Text = labelText,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = THEME.text,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
	local track = create("Frame", {
		Size = UDim2.fromOffset(36, 20),
		Position = UDim2.new(1, -36, 0.5, -10),
		BackgroundColor3 = THEME.off,
		BorderSizePixel = 0,
		Parent = row,
	}, { pill() })
	local knob = create("Frame", {
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.fromOffset(3, 3),
		BackgroundColor3 = THEME.knobOff,
		BorderSizePixel = 0,
		Parent = track,
	}, { pill() })

	row.MouseButton1Click:Connect(function()
		SetFeature(featureName, not GetFeature(featureName))
	end)

	local last = nil
	table.insert(refreshers, function()
		local on = GetFeature(featureName) and true or false
		if on == last then return end
		last = on
		local ti = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(track, ti, { BackgroundColor3 = on and THEME.accent or THEME.off }):Play()
		TweenService:Create(knob, ti, {
			Position = on and UDim2.fromOffset(19, 3) or UDim2.fromOffset(3, 3),
			BackgroundColor3 = on and THEME.knobOn or THEME.knobOff,
		}):Play()
	end)
end

local DROPDOWN_ITEM_H = 26
local DROPDOWN_GAP = 4         
local DROPDOWN_MARGIN = 8      

local function makeDropdown(parent, order, config)
	config = config or {}
	local multi = config.multi == true
	local searchable = config.searchable == true
	local actions = multi and config.actions ~= false
	local maxListH = config.maxHeight or 130
	local placeholder = config.placeholder or "None"

	local wrap = create("Frame", {
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = parent,
	}, { vlist(4) })
	local labelText = create("TextLabel", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 16),
		BackgroundTransparency = 1,
		Text = config.label or "",
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = THEME.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Visible = config.label ~= nil,
		Parent = wrap,
	})
	local btn = create("TextButton", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = THEME.field,
		Text = "",
		AutoButtonColor = false,
		Parent = wrap,
	}, { corner(8), stroke(THEME.stroke) })
	local valueLabel = create("TextLabel", {
		Size = UDim2.new(1, -32, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		BackgroundTransparency = 1,
		Text = placeholder,
		Font = Enum.Font.GothamMedium,
		TextSize = 12,
		TextColor3 = THEME.text,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = btn,
	})
	makeChevron(btn, UDim2.new(1, -14, 0.5, 0), THEME.body)

	local panel = create("Frame", {
		BackgroundColor3 = THEME.popup,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Visible = false,
		ZIndex = 20,
		Parent = gui,
	}, { corner(8), stroke(THEME.stroke) })

	local headerH = 0
	local searchBox = nil
	if searchable then
		searchBox = create("TextBox", {
			Position = UDim2.fromOffset(6, 6),
			Size = UDim2.new(1, -12, 0, 22),
			BackgroundColor3 = THEME.field,
			BorderSizePixel = 0,
			Text = "",
			PlaceholderText = "Search...",
			PlaceholderColor3 = THEME.subtext,
			TextColor3 = THEME.text,
			Font = Enum.Font.GothamMedium,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			ClearTextOnFocus = false,
			ZIndex = 21,
			Parent = panel,
		}, { corner(6), pad(8, 0, 8, 0) })
		headerH += 34
	end

	local selectAllBtn, clearBtn = nil, nil
	if actions then
		if not searchable then headerH += 6 end
		local function actionButton(text, x)
			return create("TextButton", {
				Position = UDim2.new(x, x == 0 and 6 or 3, 0, headerH),
				Size = UDim2.new(0.5, -9, 0, 22),
				BackgroundColor3 = THEME.field,
				BorderSizePixel = 0,
				Text = text,
				Font = Enum.Font.GothamMedium,
				TextSize = 11,
				TextColor3 = THEME.body,
				AutoButtonColor = true,
				ZIndex = 21,
				Parent = panel,
			}, { corner(6) })
		end
		selectAllBtn = actionButton("Select All", 0)
		clearBtn = actionButton("Clear", 0.5)
		headerH += 28
	end
	if headerH > 0 then headerH += 2 end

	local list = create("ScrollingFrame", {
		Position = UDim2.fromOffset(0, headerH),
		Size = UDim2.new(1, 0, 1, -headerH),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = THEME.accent,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ZIndex = 20,
		Parent = panel,
	}, { create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }) })

	local emptyLabel = create("TextLabel", {
		LayoutOrder = 0,
		Size = UDim2.new(1, 0, 0, DROPDOWN_ITEM_H),
		BackgroundTransparency = 1,
		Text = config.emptyText or "No options",
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextColor3 = THEME.subtext,
		ZIndex = 21,
		Parent = list,
	})

	local dd = { options = {}, byKey = {}, itemList = {}, value = nil, selected = {}, panel = panel }
	local visibleCount = 0
	local watchConn = nil

	local function updateTrigger()
		local text
		if multi then
			local names = {}
			for _, option in ipairs(dd.options) do
				if dd.selected[option.key] then table.insert(names, option.label) end
			end
			text = #names > 0 and table.concat(names, ", ") or placeholder
		else
			local option = dd.value ~= nil and dd.byKey[dd.value] or nil
			text = option and option.label or (dd.value ~= nil and tostring(dd.value)) or placeholder
		end
		if valueLabel.Text ~= text then valueLabel.Text = text end
	end

	local function paintItem(item)
		local key = item.option.key
		local on = (multi and dd.selected[key] == true) or (not multi and key == dd.value)
		item.button.TextColor3 = on and THEME.accent or item.option.color or THEME.text
	end

	local function paintAll()
		for _, item in ipairs(dd.itemList) do paintItem(item) end
		updateTrigger()
	end

	function dd.Reposition()
		if dd.isOpen ~= true or not panel.Parent then return end
		local origin, viewport = gui.AbsolutePosition, gui.AbsoluteSize
		local trigPos, trigSize = btn.AbsolutePosition, btn.AbsoluteSize

		local screenTop, screenBottom = origin.Y + DROPDOWN_MARGIN, origin.Y + viewport.Y - DROPDOWN_MARGIN
		local screenLeft, screenRight = origin.X + DROPDOWN_MARGIN, origin.X + viewport.X - DROPDOWN_MARGIN

		local width = math.max(math.min(trigSize.X, screenRight - screenLeft), 0)
		local wanted = headerH + math.min(math.max(visibleCount, 1) * DROPDOWN_ITEM_H, maxListH)

		local belowTop = trigPos.Y + trigSize.Y + DROPDOWN_GAP
		local aboveBottom = trigPos.Y - DROPDOWN_GAP
		local spaceBelow = math.max(screenBottom - belowTop, 0)
		local spaceAbove = math.max(aboveBottom - screenTop, 0)

		local placeBelow
		if spaceBelow >= wanted then
			placeBelow = true
		elseif spaceAbove >= wanted then
			placeBelow = false
		else
			placeBelow = spaceBelow >= spaceAbove
		end

		local height = math.min(wanted, placeBelow and spaceBelow or spaceAbove)
		local top = placeBelow and belowTop or (aboveBottom - height)
		local x = math.clamp(trigPos.X, screenLeft, math.max(screenLeft, screenRight - width))

		panel.Position = UDim2.fromOffset(x - origin.X, top - origin.Y)
		panel.Size = UDim2.fromOffset(width, height)
		dd.placement = placeBelow and "below" or "above"
	end

	local function triggerVisible()
		local pos, size = btn.AbsolutePosition, btn.AbsoluteSize
		local node = btn
		while node and node ~= gui do
			if node:IsA("GuiObject") then
				if not node.Visible then return false end
				if node ~= btn and (node.ClipsDescendants or node:IsA("ScrollingFrame")) then
					local p, s = node.AbsolutePosition, node.AbsoluteSize
					if pos.X + size.X <= p.X or pos.X >= p.X + s.X or pos.Y + size.Y <= p.Y or pos.Y >= p.Y + s.Y then
						return false
					end
				end
			end
			node = node.Parent
		end
		return node == gui
	end

	local function applyFilter()
		local query = searchBox and string.lower(searchBox.Text) or ""
		local count = 0
		for _, item in ipairs(dd.itemList) do
			local match = query == "" or string.find(string.lower(item.option.label), query, 1, true) ~= nil
			item.button.Visible = match
			if match then count += 1 end
		end
		visibleCount = count
		emptyLabel.Visible = count == 0
		emptyLabel.Text = (#dd.options == 0) and (config.emptyText or "No options") or "No matches"
		dd.Reposition()
	end
	if searchBox then searchBox:GetPropertyChangedSignal("Text"):Connect(applyFilter) end

	function dd.Close()
		dd.isOpen = false
		panel.Visible = false
		if watchConn then
			watchConn:Disconnect()
			watchConn = nil
		end
	end

	function dd.Open()
		closeDropdowns()
		openDropdown = dd
		dd.isOpen = true
		if searchBox and searchBox.Text ~= "" then searchBox.Text = "" end
		applyFilter()
		panel.Visible = true
		catcher.Visible = true
		dd.Reposition()

		local last = { 0, 0, 0, 0, 0, 0, 0, 0, -1 }
		watchConn = game:GetService("RunService").Heartbeat:Connect(function()
			if not panel.Parent or not btn.Parent then
				closeDropdowns()
				return
			end
			if not triggerVisible() then
				closeDropdowns()
				return
			end
			local pos, size = btn.AbsolutePosition, btn.AbsoluteSize
			local origin, viewport = gui.AbsolutePosition, gui.AbsoluteSize
			if pos.X ~= last[1] or pos.Y ~= last[2] or size.X ~= last[3] or size.Y ~= last[4]
				or viewport.X ~= last[5] or viewport.Y ~= last[6] or origin.X ~= last[7] or origin.Y ~= last[8]
				or visibleCount ~= last[9] then
				last = { pos.X, pos.Y, size.X, size.Y, viewport.X, viewport.Y, origin.X, origin.Y, visibleCount }
				dd.Reposition()
			end
		end)
	end

	btn.MouseButton1Click:Connect(function()
		if openDropdown == dd then
			closeDropdowns()
		else
			dd.Open()
		end
	end)

	local function notifyChange()
		if config.onChange then config.onChange(dd.selected) end
	end

	local function choose(option)
		if multi then
			local on = not dd.selected[option.key]
			dd.selected[option.key] = on and true or nil
			paintAll()
			if config.onSelect then config.onSelect(option.key, on) end
			notifyChange()
		else
			dd.value = option.key
			paintAll()
			closeDropdowns()
			if config.onSelect then config.onSelect(option.key, true) end
			notifyChange()
		end
	end

	if selectAllBtn then
		selectAllBtn.MouseButton1Click:Connect(function()
			for _, item in ipairs(dd.itemList) do
				local key = item.option.key
				if item.button.Visible and not dd.selected[key] then
					dd.selected[key] = true
					if config.onSelect then config.onSelect(key, true) end
				end
			end
			paintAll()
			notifyChange()
		end)
		clearBtn.MouseButton1Click:Connect(function()
			for key in pairs(dd.selected) do
				dd.selected[key] = nil
				if config.onSelect then config.onSelect(key, false) end
			end
			paintAll()
			notifyChange()
		end)
	end

	local function normalize(option)
		if type(option) == "table" then
			local label = tostring(option.label or option.key)
			return { key = option.key ~= nil and option.key or label, label = label, color = option.color }
		end
		return { key = option, label = tostring(option) }
	end

	function dd.SetOptions(options)
		for _, item in ipairs(dd.itemList) do item.button:Destroy() end
		dd.itemList, dd.byKey, dd.options = {}, {}, {}

		for i, raw in ipairs(options or {}) do
			local option = normalize(raw)
			table.insert(dd.options, option)
			dd.byKey[option.key] = option

			local button = create("TextButton", {
				Size = UDim2.new(1, 0, 0, DROPDOWN_ITEM_H),
				LayoutOrder = i,
				BackgroundTransparency = 1,
				Text = option.label,
				Font = Enum.Font.GothamMedium,
				TextSize = 12,
				TextColor3 = THEME.text,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutoButtonColor = false,
				ZIndex = 21,
				Parent = list,
			}, { pad(10, 0, 6, 0) })
			button.MouseButton1Click:Connect(function() choose(option) end)
			table.insert(dd.itemList, { option = option, button = button })
		end

		for key in pairs(dd.selected) do
			if not dd.byKey[key] then dd.selected[key] = nil end
		end
		applyFilter()
		paintAll()
	end

	function dd.SetValue(value)
		if dd.value == value then return end
		dd.value = value
		paintAll()
	end

	function dd.SetSelected(keys)
		for key in pairs(dd.selected) do dd.selected[key] = nil end
		for k, v in pairs(keys or {}) do
			if type(k) == "number" then dd.selected[v] = true
			elseif v then dd.selected[k] = true end
		end
		paintAll()
	end

	function dd.GetSelected()
		local copy = {}
		for key in pairs(dd.selected) do copy[key] = true end
		return copy
	end

	function dd.SetDimmed(dimmed)
		valueLabel.TextTransparency = dimmed and 0.45 or 0
	end

	function dd.SetLabel(text)
		labelText.Text = text or ""
		labelText.Visible = text ~= nil
	end

	function dd.SetPlaceholder(text)
		placeholder = text or "None"
		updateTrigger()
	end

	return dd
end

env.AutumnDiceContext = {
	Players = Players, ReplicatedStorage = ReplicatedStorage, player = player,
	State = State, CONFIG = CONFIG, TOWER_MODES = TOWER_MODES, Tower = Tower,
	AutoBuy = AutoBuy, AutoPotion = AutoPotion, AutumnTravel = AutumnTravel,
	SetFeature = SetFeature, GetFeature = GetFeature, SetTowerMode = SetTowerMode, SetSelectedTower = SetSelectedTower,
	addTab = addTab, makeCard = makeCard, makeToggle = makeToggle, makeDropdown = makeDropdown, makeLine = makeLine,
	create = create, corner = corner, stroke = stroke, pill = pill, vlist = vlist, pad = pad, formatNumber = formatNumber,
	THEME = THEME, gui = gui, connections = connections, refreshers = refreshers,
	getHRP = getHRP, getRemote = getRemote, invoke = invoke,
	BLUE = BLUE, GREEN = GREEN, YELLOW = YELLOW, ORANGE = ORANGE, GRAY = GRAY, RED = RED,
}
env.AutumnDiceLoadModule = function(fileName)
	local url = "https://raw.githubusercontent.com/rayshsh/ray-hub/refs/heads/main/tabs/" .. fileName
	local source = game:HttpGet(url)
	local chunk, compileError = loadstring(source)
	if type(chunk) ~= "function" then error(compileError or "Could not compile " .. fileName, 0) end
	local initialize = chunk()
	if type(initialize) ~= "function" then error("Invalid tab module: " .. fileName, 0) end
	return initialize(env.AutumnDiceContext)
end
env.AutumnDiceLoadModule("event.luau")
env.AutumnDiceLoadModule("potion.luau")
env.AutumnDiceLoadModule("tower.luau")
env.AutumnDiceLoadModule("misc.luau")
env.AutumnDiceLoadModule("roll.luau")
setAutoClaim = env.AutumnDiceContext.setAutoClaim
refreshColumns()
selectTab("Event")
local hotkeyRow = create("Frame", {
	Position = UDim2.new(0, 0, 1, -22),
	Size = UDim2.new(1, 0, 0, 22),
	BackgroundTransparency = 1,
	Parent = main,
}, { pad(2, 0, 2, 0) })
create("TextLabel", {
	Size = UDim2.new(0.5, 0, 1, 0),
	BackgroundTransparency = 1,
	Text = "Show / hide GUI",
	Font = Enum.Font.Gotham,
	TextSize = 11,
	TextColor3 = THEME.subtext,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = hotkeyRow,
})
local hotkeyBtn = create("TextButton", {
	Size = UDim2.fromOffset(104, 20),
	Position = UDim2.new(1, -104, 0.5, -10),
	BackgroundColor3 = THEME.field,
	Text = "",
	Font = Enum.Font.GothamBold,
	TextSize = 11,
	TextColor3 = THEME.accent,
	AutoButtonColor = false,
	Parent = hotkeyRow,
}, { corner(8), stroke(THEME.stroke) })

local listeningForKey = false
local function refreshHotkey()
	hotkeyBtn.Text = listeningForKey and "Press a key..." or ("[ " .. State.Hotkey.Name .. " ]")
end

hotkeyBtn.MouseButton1Click:Connect(function()
	if listeningForKey then return end
	listeningForKey = true
	refreshHotkey()
	local conn
	conn = UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		conn:Disconnect()
		if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.Unknown then
			State.Hotkey = input.KeyCode
		end
		task.delay(0.15, function()
			listeningForKey = false
			refreshHotkey()
		end)
	end)
end)

table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or listeningForKey then return end
	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == State.Hotkey then
		main.Visible = not main.Visible
		if not main.Visible then closeDropdowns() end
	end
end))

do
	local drag = {}
	table.insert(connections, titleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			closeDropdowns()
			drag.dragging, drag.dragStart, drag.startPos = true, input.Position, main.Position
		end
	end))
	table.insert(connections, UserInputService.InputChanged:Connect(function(input)
		if drag.dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - drag.dragStart
			main.Position = UDim2.new(drag.startPos.X.Scale, drag.startPos.X.Offset + delta.X, drag.startPos.Y.Scale, drag.startPos.Y.Offset + delta.Y)
		end
	end))
	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			drag.dragging = false
		end
	end))
end

local lastSignature = nil
local function refreshTowerOptions()
	if not loadTowerModules() then return end

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
	if signature == lastSignature then return end
	lastSignature = signature

	Tower.names, Tower.options = names, options
	Tower.displayByName, Tower.optionToName, Tower.catalog = displayByName, optionToName, catalog
	env.AutumnDiceContext.TowerUI.towerDropdown.SetOptions(options)

	if not State.SelectedTower or not table.find(names, State.SelectedTower) then
		State.SelectedTower = names[1]
		Tower.activeName = nil
		Tower.lastStarted = false
	end
	Tower.wake = true
	notify()
end

local function refreshGui()
	for _, fn in ipairs(refreshers) do fn() end

	env.AutumnDiceContext.Roll.rollCount.Text = ("Rolls: %s"):format(formatNumber(State.Rolls))
	env.AutumnDiceContext.Roll.leafBalance.Text = ("Leaf Balance: %s"):format(formatNumber(env.AutumnDiceContext.Roll.leafBalanceValue))
	local pooledResults = {}
	for unitId, counts in pairs(State.RollResultPool) do
		table.insert(pooledResults, ("%s x%d"):format(unitId, counts.total))
	end
	table.sort(pooledResults)
	env.AutumnDiceContext.Roll.rollResultsLine.Text = "Results: " .. (#pooledResults > 0 and table.concat(pooledResults, ", ") or "None yet")

	local S = State.TowerStats
	local floorText = S.Floor and (" floor " .. S.Floor) or ""
	env.AutumnDiceContext.TowerUI.towerLine.Text = Tower.activeName and ("Tower: " .. (Tower.displayByName[Tower.activeName] or Tower.activeName) .. floorText) or "Tower: -"
	env.AutumnDiceContext.TowerUI.statsLine.Text = ("%d Runs | %s Floors Cleared | Best Floor %s"):format(S.Runs, S.Tracking and tostring(S.Floors) or "-", (S.Tracking and S.Best > 0) and tostring(S.Best) or "-")

	env.AutumnDiceContext.TowerUI.modeDropdown.SetValue(State.TowerMode)
	env.AutumnDiceContext.TowerUI.towerDropdown.SetValue(Tower.displayByName[State.SelectedTower] or State.SelectedTower)
	env.AutumnDiceContext.TowerUI.towerDropdown.SetDimmed(State.TowerMode ~= "Single")

	refreshHotkey()
end
onChange(refreshGui)
refreshGui()

local syncAlive = true
task.spawn(function()
	while syncAlive and gui.Parent do
		pcall(refreshTowerOptions)
		refreshGui()
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
	env.AutumnDiceContext.autoQuestStatusLabel.Text = enabled and (towerStatus and (towerStatus .. " | " .. mainStatus) or mainStatus) or "Auto Quest is disabled."
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
	while enabled and not AutumnTravel.questRequested and not AutumnTravel.buyRequested and CONFIG.AUTO_BOARD_LEVELS and getRemaining(OBJECTIVES.BOARD) do
		local boughtAny = false
		for _, upgrade in AppleConfig.Upgrades do
			if not getRemaining(OBJECTIVES.BOARD) then
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
		return enabled and not AutumnTravel.questRequested and not AutumnTravel.buyRequested and getRemaining(OBJECTIVES.LEAF_ROLLS) ~= nil
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

	while enabled and not AutumnTravel.questRequested and not AutumnTravel.buyRequested and CONFIG.AUTO_LEAF_ROLLS and getRemaining(OBJECTIVES.LEAF_ROLLS) do
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

setAutoQuest = function(value)
	enabled = value
	setStatus(value and "Preparing Autumn quests" or "Disabled")
end

end

local function Unload()
	syncAlive = false
	setAntiAfk(false)
	setAutoReconnect(false)
	uninstallFloorHook()
	if env.AutumnDiceContext and env.AutumnDiceContext.unhookQuests then env.AutumnDiceContext.unhookQuests() end
	if AutoBuy.setEnabled then AutoBuy.setEnabled(false) end
	State.Features.AutoBuy = false
	if AutoPotion.setEnabled then AutoPotion.setEnabled(false) end
	State.Features.AutoPotion = false
	AutumnTravel.buyRequested = false
	setAutoClaim(false)
	setAutoQuest(false)
	State.Features.AutoQuest = false
	State.Features.AutoClaimQuest = false
	State.Features.AutoDice = false
	State.Features.AutoTower = false
	runId += 1
	towerRunId += 1
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	if AutoBuy.refreshEvent then pcall(function() AutoBuy.refreshEvent:Destroy() end) end
env.AutumnDiceContext = nil
env.AutumnDiceLoadModule = nil
	if AutoPotion.refreshConnection then pcall(function() AutoPotion.refreshConnection:Disconnect() end) end
	if AutoPotion.refreshEvent then pcall(function() AutoPotion.refreshEvent:Destroy() end) end
	for _, c in ipairs(AutoBuy.dataHooks) do pcall(function() c:Disconnect() end) end
	if gui then gui:Destroy() end
	env.AutumnDice = nil
end

closeBtn.MouseButton1Click:Connect(Unload)

env.AutumnDice = {
	SetFeature = SetFeature,
	GetFeature = GetFeature,
	SetTowerMode = SetTowerMode,
	SetSelectedTower = SetSelectedTower,
	GetStatus = function() return State.Status, State.Detail end,
	GetTowerStatus = function() return State.TowerStatus, State.TowerDetail end,
	SetHotkey = function(keyCode) State.Hotkey = keyCode notify() end,
	Unload = Unload,
	Travel = AutumnTravel,
}

for _, name in ipairs({ "AntiAfk", "AutoDice" }) do
	SetFeature(name, true)
end

initializeAutoQuest()
