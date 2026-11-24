return function(ctx)
local Players, ReplicatedStorage = ctx.Players, ctx.ReplicatedStorage
local localPlayer = ctx.player
local create = ctx.create
local tab = ctx.addTab(6, "Trade")
local tradeBody = ctx.makeCard(tab.left, function(tile)
	create("TextLabel", {Parent = tile, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "⇄", Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = ctx.THEME.accent})
end, "Trade")
local Framework = ReplicatedStorage:WaitForChild("Framework", 10)
if not Framework then error("[Trade] Framework not found") end
local TradeConfig = require(Framework.Features.Trading.TradeConfig)
local DataController = require(Framework.Features.Data.DataController)
local EntryRegistry = require(Framework.Features.Inventory.EntryRegistry)
-- Names of every Unit entry — these are excluded from the item dropdown
local unitNames = {}
for name in EntryRegistry.entriesOfKind("Unit") do
	unitNames[name] = true
end

-- Trading remotes
local Network = ReplicatedStorage:WaitForChild("Network", 10)
local TradeRemotes = Network and Network:WaitForChild("TradeService", 10)
local RE = TradeRemotes and TradeRemotes:WaitForChild("RE", 10)
if not RE then
	error("[TradePanelTest] TradeService remotes not found under ReplicatedStorage.Network.TradeService.RE")
end

local RequestTradeRE = RE:WaitForChild("RequestTrade", 10)
local ChangeOfferRE = RE:WaitForChild("ChangeOffer", 10)
local AdvanceTradeRE = RE:WaitForChild("AdvanceTrade", 10)
local CancelTradeRE = RE:WaitForChild("CancelTrade", 10)
local TradeEventRE = RE:WaitForChild("TradeEvent", 10)
if not (RequestTradeRE and ChangeOfferRE and AdvanceTradeRE and CancelTradeRE and TradeEventRE) then
	error("[TradePanelTest] One or more trade RemoteEvents are missing")
end

local MAX_UNIQUE = TradeConfig.MAX_UNIQUE_ENTRIES or 20
local REQUEST_COOLDOWN = TradeConfig.REQUEST_COOLDOWN or 6

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local selectedPlayer = nil -- Player instance chosen as recipient
local selectedItems = {} -- [inventoryKey] = true
local sendMax = false -- "Send Max Quantity" toggle
local autoSend = false -- "Auto Send at Amount" toggle
local globalAmount = 1 -- the ONE global amount input value
local running = false -- a trading process is active
local stopRequested = false -- user asked to stop after the current batch

local lastTradeUpdate = nil -- most recent "Updated" payload from the server
local lastEndReason = nil -- most recent "Ended" reason

--------------------------------------------------------------------------------
-- Inventory helpers
--------------------------------------------------------------------------------

-- Returns a fresh map of itemName -> {key, name} for every registered entry
-- in the game that is tradable and not a Unit. The full game item list is
-- shown, regardless of what the player currently owns.
local function getTradableEntries()
	local result = {}
	local ok, allEntries = pcall(EntryRegistry.allEntries)
	if not ok or type(allEntries) ~= "table" then
		return result
	end
	for name, config in allEntries do
		if type(config) == "table" and not unitNames[name] then
			local tradable = false
			local okCheck, tradableValue = pcall(TradeConfig.IsTradeable, {name = name})
			if okCheck then
				tradable = tradableValue == true
			end
			if tradable then
				result[name] = {key = name, name = name}
			end
		end
	end
	return result
end

-- Returns a map of itemName -> total quantity currently owned by the player.
local function getAvailableAmounts()
	local result = {}
	local ok, inventory = pcall(function()
		return DataController.Inventory()
	end)
	if not ok or type(inventory) ~= "table" then
		return result
	end
	-- Stackable entries are keyed by their entry name and carry a numeric
	-- `amount`; non-stackable entries are keyed by a GUID, have NO `amount`
	-- field, and each one counts as a single unit. Map both cases onto the
	-- entry name so lookups by selected-item key work.
	for key, item in inventory do
		if type(item) == "table" then
			local name = item.name or key
			local amount = (type(item.amount) == "number") and item.amount or 1
			if amount > 0 then
				result[name] = (result[name] or 0) + amount
			end
		end
	end
	return result
end

-- Applies the priority rules to a single item:
--   * Send Max Quantity enabled  -> the entire available quantity.
--   * Otherwise                   -> min(global amount, available quantity).
-- Never returns more than the player owns; returns 0 when unavailable.
local function calcQuantity(available)
	if sendMax then
		return available
	end
	return math.min(globalAmount, available)
end

-- Resolves the selected item names into concrete inventory keys the
-- server's ChangeOffer understands. The server looks up Inventory[key]
-- directly: stackable entries are keyed by their entry name, while
-- non-stackable entries are keyed by unique GUIDs (one unit each), so
-- offering a NAME for a non-stackable item silently fails.
-- Returns an array of { key = inventoryKey, quantity = n, name = displayName }.
local function resolveSelectedOffers()
	local entries = {}
	local ok, inventory = pcall(function()
		return DataController.Inventory()
	end)
	if not ok or type(inventory) ~= "table" then
		return entries
	end

	-- Group inventory entries by their entry name
	local byName = {}
	for key, item in inventory do
		if type(item) == "table" then
			local name = item.name or key
			if not byName[name] then
				byName[name] = {}
			end
			table.insert(byName[name], {key = key, item = item})
		end
	end

	for name in selectedItems do
		local group = byName[name]
		if group then
			-- Total units available for this entry name
			local total = 0
			for _, e in group do
				total += (type(e.item.amount) == "number") and e.item.amount or 1
			end
			local desired = calcQuantity(total)
			if desired > 0 then
				local remaining = desired
				for _, e in group do
					if remaining <= 0 then
						break
				end
				local amt = (type(e.item.amount) == "number") and e.item.amount or 1
				local take = math.min(remaining, amt)
				if take > 0 then
					table.insert(entries, {key = e.key, quantity = take, name = name})
					remaining -= take
				end
			end
			end
		end
	end
	return entries
end

--------------------------------------------------------------------------------
-- Trade event waiting
--------------------------------------------------------------------------------

-- Waits for a TradeEvent message. Aborts early on trade-ending signals.
-- Returns: (data, nil) on success; (nil, reasonString) on timeout/abort.
-- Note: when the recipient ACCEPTS, the server fires RequestClosed (closing
-- the request popup) around the same time as Started. So a RequestClosed seen
-- while waiting for "Started" only aborts if Started does not follow within
-- a short grace period — a decline/close is followed by nothing.
local function waitForTradeEvent(expectedName, predicate, timeout)
	local result = nil
	local failReason = nil
	local requestClosedAt = nil
	local REQUEST_CLOSED_GRACE = 3
	local conn = TradeEventRE.OnClientEvent:Connect(function(name, data)
		if name == expectedName and (predicate == nil or predicate(data)) then
			if result == nil then
				result = data or true
			end
		elseif result == nil and expectedName ~= "Ended" then
			if name == "Ended" then
				failReason = "Trade ended (" .. ((data and data.reason) or "unknown") .. ")"
				result = false
			elseif expectedName == "Started" then
				if name == "RequestExpired" then
					failReason = "Trade request expired"
					result = false
				elseif name == "RequestClosed" then
					-- Either the popup is closing because the request was accepted,
				-- or the recipient declined — wait briefly for Started to decide.
					requestClosedAt = os.clock()
				end
			end
		end
	end)

	local deadline = os.clock() + timeout
	while result == nil and os.clock() < deadline do
		if requestClosedAt and os.clock() > requestClosedAt + REQUEST_CLOSED_GRACE then
			result = false
			failReason = "Trade request was declined or closed"
		else
			task.wait(0.1)
		end
	end
	conn:Disconnect()

	if result == nil then
		return nil, "Timed out waiting for '" .. expectedName .. "'"
	end
	if result == false then
		return nil, failReason or "Trade was interrupted"
	end
	return result, nil
end

-- Tracks the latest trade state for status display and offer verification.
table.insert(ctx.connections, TradeEventRE.OnClientEvent:Connect(function(name, data)
	if name == "Updated" then
		lastTradeUpdate = data
	elseif name == "Ended" then
		lastEndReason = data and data.reason
	end
end))

--------------------------------------------------------------------------------
-- Shared hub UI
--------------------------------------------------------------------------------
local makeDropdown, makeLine, makeToggle = ctx.makeDropdown, ctx.makeLine, ctx.makeToggle
local makeInput = ctx.makeInput
local THEME = ctx.THEME
local setStatus
local playerDropdown, itemDropdown
local function refreshPlayerOptions()
	local options = {}
	for _, candidate in Players:GetPlayers() do
		if candidate ~= localPlayer then
			table.insert(options, {key = candidate.Name, label = candidate.DisplayName .. " (" .. candidate.Name .. ")"})
		end
	end
	playerDropdown.SetOptions(options)
	if selectedPlayer and selectedPlayer.Parent ~= Players then
		selectedPlayer = nil
		playerDropdown.SetValue(nil)
	end
end

playerDropdown = makeDropdown(tradeBody, 1, {
	label = "Trade recipient",
	placeholder = "Select a player...",
	searchable = true,
	emptyText = "No players found",
	onSelect = function(name)
		selectedPlayer = name and Players:FindFirstChild(name) or nil
		if setStatus then setStatus("Recipient selected.") end
	end,
})

itemDropdown = makeDropdown(tradeBody, 2, {
	label = "Tradable items",
	placeholder = "Select items...",
	searchable = true,
	multi = true,
	emptyText = "No tradable items found",
	maxHeight = 200,
	onChange = function(selected)
		selectedItems = selected
		if setStatus then setStatus("Selection updated.") end
	end,
})

local amountBox = makeInput(tradeBody, 3, "Amount per item", "1", "Enter amount")

local sendButton = create("TextButton", {
	LayoutOrder = 7,
	Parent = tradeBody,
	Size = UDim2.new(1, 0, 0, 32),
	BackgroundColor3 = THEME.accent,
	TextColor3 = THEME.text,
	Font = Enum.Font.GothamBold,
	TextSize = 13,
	Text = "Send Trade",
	AutoButtonColor = true,
}, {ctx.corner(8), ctx.stroke(THEME.stroke)})

local statusLabel = makeLine(tradeBody, 8, 12, THEME.body)
statusLabel.Text = "Recipient: None\nItems: 0 (Amount 1)\nStatus: Idle."

local function refreshItemOptions()
	local options = {}
	for name in getTradableEntries() do table.insert(options, name) end
	table.sort(options)
	itemDropdown.SetOptions(options)
end

local function refreshTradeOptions()
	if not ctx.Alive then return end
	refreshPlayerOptions()
	refreshItemOptions()
end

refreshTradeOptions()
table.insert(ctx.connections, Players.PlayerAdded:Connect(refreshPlayerOptions))
table.insert(ctx.connections, Players.PlayerRemoving:Connect(function(candidate)
	if candidate == selectedPlayer then
		selectedPlayer = nil
		playerDropdown.SetValue(nil)
		stopRequested = running
	end
	refreshPlayerOptions()
end))

local function sanitizeAmount()
	local value = tonumber(amountBox.Text) or 1
	value = math.floor(math.max(1, value))
	globalAmount = value
	amountBox.Text = tostring(value)
end
amountBox.FocusLost:Connect(sanitizeAmount)

local function updateStatusLabel(message)
	local selectedItemCount = 0
	for _ in selectedItems do selectedItemCount += 1 end
	statusLabel.Text = string.format(
		"Recipient: %s\nItems: %d%s\nStatus: %s",
		selectedPlayer and selectedPlayer.Name or "None",
		selectedItemCount,
		sendMax and " (Send Max)" or (" (Amount " .. globalAmount .. ")"),
		message
	)
end
setStatus = updateStatusLabel

makeToggle(tradeBody, 5, "Send Max Quantity", "TradeSendMax")
makeToggle(tradeBody, 6, "Auto Send at Amount", "TradeAutoSend")

--------------------------------------------------------------------------------
-- Trading process (shared by manual Send Trade and Auto Send)
--------------------------------------------------------------------------------

-- Splits keys into sequential batches of at most MAX_UNIQUE keys each.
local function buildBatches(keys)
	local batches = {}
	local current = {}
	for _, key in keys do
		table.insert(current, key)
		if #current >= MAX_UNIQUE then
			table.insert(batches, current)
			current = {}
		end
	end
	if #current > 0 then
		table.insert(batches, current)
	end
	return batches
end

-- Verifies the server accepted exactly the expected offer.
local function offerMatches(ownOffer, expected)
	local expectedCount = 0
	for _ in expected do
		expectedCount += 1
	end
	local actualCount = 0
	for _ in ownOffer do
		actualCount += 1
	end
	if actualCount ~= expectedCount then
		return false
	end
	for key, amount in expected do
		if ownOffer[key] ~= amount then
			return false
		end
	end
	return true
end

local function runTradeProcess()
	-- ---- Validation before anything starts ----------------------------
	if not selectedPlayer then
		setStatus("No recipient selected.")
		return
	end
	if selectedPlayer.Parent ~= Players then
		setStatus("Selected player '" .. selectedPlayer.Name .. "' is no longer connected.")
		selectedPlayer = nil
		playerDropdown.SetValue(nil)
		return
	end

	-- Outer loop: with Auto Send on, a fully completed pass does NOT stop
	-- the process. It loops back to the waiting phase below and starts a new
	-- pass. Each pass rebuilds the batch plan dynamically from the CURRENT
	-- selection and live inventory, so the number of batches always reflects
	-- what is selected and available at that moment (e.g. 3/3 one pass,
	-- 7/7 the next). Quantities are also recalculated per batch from the
	-- live inventory. It only stops when the toggle is turned off, the user
	-- stops it, or the recipient disconnects.
	while true do

	-- ---- Auto Send at Amount: wait for the amount to be met ----------
	-- When the toggle is enabled, the trade request is sent automatically
	-- only once at least ONE selected item's available quantity is >= the
	-- entered Amount. The offer then includes ALL selected items (each at
	-- min(amount, available)); the other items do not need to meet the
	-- amount individually. "Send Max Quantity" bypasses the amount condition
	-- entirely -- any available quantity counts.
	-- With the toggle off, no trade is initiated automatically; the user
	-- must press "Send Trade" manually.
	if autoSend then
		setStatus("Auto Send: waiting for a selected item to reach the amount...")
		while not stopRequested do
			if selectedPlayer == nil or selectedPlayer.Parent ~= Players then
				setStatus("Auto Send stopped: recipient disconnected.")
				selectedPlayer = nil
				playerDropdown.SetValue(nil)
				return
			end
			local available = getAvailableAmounts()
			-- Trigger threshold: with Send Max Quantity enabled, any available
			-- quantity counts; otherwise at least ONE selected item must have
			-- available >= the entered amount.
			local required = sendMax and 1 or globalAmount
			local met = false
			local best = 0
			for key in selectedItems do
				local have = available[key] or 0
				if have > best then
					best = have
				end
				if have >= required then
					met = true
					break
				end
			end
			if met then
				break
			end
			setStatus(string.format(
				"Auto Send: waiting... need any selected item >= %d (best so far: %d).",
				required, best
			))
			task.wait(1)
		end
		if stopRequested then
			setStatus("Auto Send stopped by user.")
			return
		end
	end

	-- ---- Build the batch plan for this pass ----------------------------
	-- The plan is rebuilt every pass from the current selection and live
	-- inventory, so the batch count is dynamic: it depends on how many
	-- selected items are actually available right now.
	local selectedNames = {}
	for key in selectedItems do
		table.insert(selectedNames, key)
	end
	table.sort(selectedNames)
	if #selectedNames == 0 then
		setStatus("No tradable items selected.")
		return
	end

	-- Resolve the selected names into concrete inventory keys (names for
	-- stackable entries, GUIDs for non-stackable ones) before batching.
	local offers = resolveSelectedOffers()
	if #offers == 0 then
		if autoSend and not stopRequested then
			-- Nothing available right now; go back to the waiting phase
			-- instead of stopping the Auto Send process.
			continue
		end
		setStatus("None of the selected items are currently in your inventory.")
		break
	end

	local batches = buildBatches(offers)
	local totalBatches = #batches
	local offersCount = #offers
	local completedBatches = 0

	-- With Auto Send on, a failed batch (e.g. the request expired or was
	-- declined) is retried after the cooldown instead of aborting the run.
	-- Returns true when the whole process should stop, false to retry.
	local function failBatch(message)
		if autoSend and not stopRequested then
			setStatus(message .. " Retrying in " .. (REQUEST_COOLDOWN + 1) .. "s (Auto Send)...")
			task.wait(REQUEST_COOLDOWN + 1)
			return stopRequested
		end
		setStatus(message)
		return true
	end

	setStatus("Starting: " .. offersCount .. " offer entries in " .. totalBatches .. " batch(es).")

	local batchIndex = 1
	while batchIndex <= totalBatches do
		local batch = batches[batchIndex]
		if stopRequested then
			setStatus("Stopped by user after " .. completedBatches .. "/" .. totalBatches .. " batches.")
			return
		end
		if selectedPlayer.Parent ~= Players then
			setStatus("Recipient disconnected. Stopped after " .. completedBatches .. "/" .. totalBatches .. " batches.")
			return
		end

		local remaining = totalBatches - batchIndex + 1
		setStatus(string.format(
			"Batch %d/%d | Done: %d | Remaining: %d | Preparing offer...",
			batchIndex, totalBatches, completedBatches, remaining
		))

		-- ---- Recalculate quantities from the freshest inventory ----------
		local okInv, freshInventory = pcall(function()
			return DataController.Inventory()
		end)
		local fresh = (okInv and type(freshInventory) == "table") and freshInventory or {}
		local expected = {} -- inventoryKey -> quantity for this batch
		local displayNames = {} -- inventoryKey -> display name
		local offeredCount = 0
		for _, offer in batch do
			local item = fresh[offer.key]
			if type(item) == "table" then
				local amt = (type(item.amount) == "number") and item.amount or 1
				local quantity = math.min(offer.quantity, amt)
				if quantity > 0 then
					expected[offer.key] = quantity
				displayNames[offer.key] = offer.name
					offeredCount += 1
				end
			end
		end

		if offeredCount == 0 then
			-- Every item in this batch became unavailable; skip it safely
			completedBatches += 1
			setStatus(string.format(
				"Batch %d/%d skipped (items no longer available).",
				batchIndex, totalBatches
			))
			task.wait(1)
			batchIndex += 1
			continue
		end

		-- ---- Initiate the trade ------------------------------------------
		lastTradeUpdate = nil
		lastEndReason = nil
		RequestTradeRE:FireServer(selectedPlayer)

		-- Phase 1: confirm the server actually sent the request
		setStatus(string.format(
			"Batch %d/%d | Sending trade request to %s...",
			batchIndex, totalBatches, selectedPlayer.Name
		))
		local sent, sentErr = waitForTradeEvent("RequestSent", function(data)
			return data and data.player == selectedPlayer
		end, 10)
		if not sent then
			if failBatch("Batch " .. batchIndex .. " failed: " .. (sentErr or "trade request was not sent")) then
				return
			end
			continue
		end

		-- Phase 2: wait for the recipient to ACCEPT the request.
		-- The request expires after REQUEST_DURATION, so a RequestExpired or
		-- RequestClosed message aborts the wait here.
		setStatus(string.format(
			"Batch %d/%d | Waiting for %s to accept the trade request...",
			batchIndex, totalBatches, selectedPlayer.Name
		))
		local started, startErr = waitForTradeEvent("Started", function(data)
			return data and data.partner == selectedPlayer
		end, 30)
		if not started then
			if failBatch("Batch " .. batchIndex .. " failed: " .. (startErr or "recipient did not accept the trade request")) then
				return
			end
			continue
		end

		-- Phase 3: wait for the trade window to actually open (Offer phase)
		-- before adding any items. The server sends the first "Updated" (Offer
		-- phase) immediately when the trade starts, often BEFORE this wait begins,
		-- so check the already-recorded state (lastTradeUpdate) first, and only
		-- wait for a new event if it hasn't arrived yet.
		setStatus(string.format(
			"Batch %d/%d | Trade accepted | Waiting for trade window to open...",
			batchIndex, totalBatches
		))
		local opened = (lastTradeUpdate and lastTradeUpdate.phase == "Offer") and lastTradeUpdate or nil
		local openErr = nil
		if not opened then
			opened, openErr = waitForTradeEvent("Updated", function(data)
				return data and data.phase == "Offer"
			end, 10)
		end
		if not opened then
			CancelTradeRE:FireServer()
			if failBatch("Batch " .. batchIndex .. " failed: " .. (openErr or "trade window did not open")) then
				return
			end
			continue
		end

		setStatus(string.format(
			"Batch %d/%d | Trade open | Adding %d items...",
			batchIndex, totalBatches, offeredCount
		))

		-- ---- Add items and calculated quantities to the offer -----------
		for key, quantity in expected do
			ChangeOfferRE:FireServer(key, quantity)
			-- The server debounces ChangeOffer at 0.1s per player; wait
			-- slightly longer so no call is silently dropped.
			task.wait(0.15)
		end

		-- Let the server process the offer changes and report its state,
		-- then read what the server actually registered.
		task.wait(1)
		local ownOffer = (lastTradeUpdate and lastTradeUpdate.ownOffer) or {}

		-- Compare the accepted offer against what was requested: items the
		-- server did NOT register (missing/zero) are simply skipped, and the
		-- trade proceeds with whatever was accepted. Items registered at a
		-- lower quantity than requested keep the accepted quantity.
		local accepted = {} -- key -> quantity the server actually registered
		local skipped = {} -- names of items missing from the offer
		for key, quantity in expected do
			local actual = ownOffer[key]
			if actual and actual > 0 then
				accepted[key] = actual
				if actual < quantity then
					table.insert(skipped, (displayNames[key] or key) .. " (partial " .. actual .. "/" .. quantity .. ")")
				end
			else
				table.insert(skipped, displayNames[key] or key)
			end
		end

		local acceptedCount = 0
		for _ in accepted do
			acceptedCount += 1
		end

		if acceptedCount == 0 then
			-- Nothing made it into the offer; an empty trade is pointless.
			CancelTradeRE:FireServer()
			if failBatch(string.format(
				"Batch %d/%d failed: none of the offered items were accepted by the server. Skipped: %s",
				batchIndex, totalBatches, table.concat(skipped, ", ")
			)) then
				return
			end
			continue
		end

		if #skipped > 0 then
			setStatus(string.format(
				"Batch %d/%d | %d item(s) skipped: %s | Proceeding with %d item(s)...",
				batchIndex, totalBatches, #skipped, table.concat(skipped, ", "), acceptedCount
			))
		end

		-- ---- Ready up -----------------------------------------------------
		AdvanceTradeRE:FireServer()
		setStatus(string.format(
			"Batch %d/%d | Offer ready | Waiting for partner to ready up...",
			batchIndex, totalBatches
		))

		local confirmed, confirmErr = waitForTradeEvent("Updated", function(data)
			return data and data.phase == "Confirm"
		end, 180)
		if not confirmed then
			CancelTradeRE:FireServer()
			if failBatch("Batch " .. batchIndex .. " failed: " .. (confirmErr or "partner did not ready up")) then
				return
			end
			continue
		end

		-- ---- Accept the confirmation --------------------------------------
		AdvanceTradeRE:FireServer()
		setStatus(string.format(
			"Batch %d/%d | Accepted | Waiting for partner / countdown...",
			batchIndex, totalBatches
		))

		local ended, endedErr = waitForTradeEvent("Ended", nil, 60)
		if not ended then
			CancelTradeRE:FireServer()
			if failBatch("Batch " .. batchIndex .. " failed: " .. (endedErr or "trade did not complete")) then
				return
			end
			continue
		end
		if type(ended) == "table" and ended.reason ~= "Completed" then
			if failBatch("Batch " .. batchIndex .. " failed: trade ended (" .. tostring(ended.reason) .. ").") then
				return
			end
			continue
		end

		-- ---- Batch verified complete --------------------------------------
		completedBatches += 1
		setStatus(string.format(
			"Batch %d/%d completed successfully.",
			batchIndex, totalBatches
		))

		-- Respect the server's request cooldown before the next trade
		batchIndex += 1
		if batchIndex <= totalBatches then
			task.wait(REQUEST_COOLDOWN + 1)
		end
	end

	setStatus("All " .. totalBatches .. " batch(es) completed. " .. offersCount .. " offer entries traded.")

	-- Auto Send still on: do not stop here. Loop back to the waiting
	-- phase and keep sending trade requests as items become available.
	if not autoSend or stopRequested then
		break
	end
	end -- while true (Auto Send outer loop)
end

local function startTradeProcess()
	if running then
		return
	end
	running = true
	stopRequested = false
	sendButton.Active = false
	sendButton.AutoButtonColor = false
	sendButton.Text = "Trading..."

	local ok, err = pcall(runTradeProcess)
	if not ok then
		setStatus("Script error: " .. tostring(err))
	end

	running = false
	sendButton.Active = true
	sendButton.AutoButtonColor = true
	sendButton.Text = "Send Trade"
end

sendButton.MouseButton1Click:Connect(function()
	if not running then task.spawn(startTradeProcess) end
end)

ctx.FeatureHandlers.TradeSendMax = function(enabled)
	sendMax = enabled
	setStatus(enabled and "Send Max Quantity enabled. Amount input will be ignored." or "Send Max Quantity disabled. Amount input will be used.")
end
ctx.FeatureHandlers.TradeAutoSend = function(enabled)
	autoSend = enabled
	if enabled then
		setStatus("Auto Send enabled. Waiting for the selected amount...")
		if not running then task.spawn(startTradeProcess) end
	else
		stopRequested = true
		setStatus(running and "Auto Send disabled. Stopping after the current batch..." or "Auto Send disabled.")
	end
end

setStatus("Idle.")
ctx.CleanupHandlers.trade = function()
	stopRequested = true
	if running then pcall(function() CancelTradeRE:FireServer() end) end
end
end
