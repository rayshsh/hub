return function(ctx)
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
end