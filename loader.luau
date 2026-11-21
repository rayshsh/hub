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

local BLUE = Color3.fromRGB(120, 170, 255)
local GREEN = Color3.fromRGB(90, 215, 120)
local YELLOW = Color3.fromRGB(255, 200, 80)
local ORANGE = Color3.fromRGB(255, 150, 70)
local GRAY = Color3.fromRGB(150, 150, 160)
local RED = Color3.fromRGB(240, 85, 85)

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


local FeatureHandlers, CleanupHandlers = {}, {}
local function SetFeature(name, value)
	if State.Features[name] == nil then return end
	value = value and true or false
	if State.Features[name] == value then return end
	State.Features[name] = value
	local handler = FeatureHandlers[name]
	if handler then handler(value) end
	notify()
end
local function GetFeature(name)
	return State.Features[name]
end

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
	State = State, CONFIG = CONFIG, TOWER_MODES = TOWER_MODES,
	AutumnTravel = AutumnTravel,
	SetFeature = SetFeature, GetFeature = GetFeature, FeatureHandlers = FeatureHandlers, CleanupHandlers = CleanupHandlers, notify = notify, onChange = onChange,
	addTab = addTab, makeCard = makeCard, makeToggle = makeToggle, makeDropdown = makeDropdown, makeLine = makeLine,
	create = create, corner = corner, stroke = stroke, pill = pill, vlist = vlist, pad = pad, formatNumber = formatNumber,
	THEME = THEME, gui = gui, connections = connections, refreshers = refreshers,
	getHRP = getHRP, getRemote = getRemote, invoke = invoke, pathString = pathString,
	BLUE = BLUE, GREEN = GREEN, YELLOW = YELLOW, ORANGE = ORANGE, GRAY = GRAY, RED = RED,
}
env.AutumnDiceLoadModule = function(fileName)
	local url = "https://raw.githubusercontent.com/rayshsh/hub/refs/heads/main/tabs/" .. fileName
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

local function refreshGui()
	for _, fn in ipairs(refreshers) do pcall(fn) end
	refreshHotkey()
end
onChange(refreshGui)
refreshGui()
local function Unload()
	for name, handler in pairs(FeatureHandlers) do
		pcall(handler, false)
		State.Features[name] = false
	end
	for _, cleanup in pairs(CleanupHandlers) do pcall(cleanup) end
	for name in pairs(State.Features) do State.Features[name] = false end
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	if gui then gui:Destroy() end
	env.AutumnDiceContext = nil
	env.AutumnDiceLoadModule = nil
	env.AutumnDice = nil
end
closeBtn.MouseButton1Click:Connect(Unload)

env.AutumnDice = {
	SetFeature = SetFeature,
	GetFeature = GetFeature,
	SetTowerMode = function(mode)
		local tower = env.AutumnDiceContext and env.AutumnDiceContext.Tower
		if tower and tower.setMode then tower.setMode(mode) end
	end,
	SetSelectedTower = function(name)
		local tower = env.AutumnDiceContext and env.AutumnDiceContext.Tower
		if tower and tower.setSelected then tower.setSelected(name) end
	end,
	GetStatus = function() return State.Status, State.Detail end,
	GetTowerStatus = function() return State.TowerStatus, State.TowerDetail end,
	SetHotkey = function(keyCode) State.Hotkey = keyCode notify() end,
	Unload = Unload,
	Travel = AutumnTravel,
}

for _, name in ipairs({ "AntiAfk", "AutoDice" }) do
	SetFeature(name, true)
end
