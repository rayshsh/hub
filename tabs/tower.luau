return function(ctx)
local addTab, makeCard, makeToggle = ctx.addTab, ctx.makeCard, ctx.makeToggle
local create, THEME, pill = ctx.create, ctx.THEME, ctx.pill
local makeDropdown, makeLine, vlist = ctx.makeDropdown, ctx.makeLine, ctx.vlist
local TOWER_MODES, SetTowerMode, SetSelectedTower = ctx.TOWER_MODES, ctx.SetTowerMode, ctx.SetSelectedTower
ctx.TowerUI = {}
local towerTab = addTab(3, "Auto Tower")
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
end