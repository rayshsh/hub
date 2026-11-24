return function(ctx)
	local create, THEME = ctx.create, ctx.THEME
	local makeCard, makeLine, makeInput = ctx.makeCard, ctx.makeLine, ctx.makeInput
	local makeDropdown, makeButton, makeToggle = ctx.makeDropdown, ctx.makeButton, ctx.makeToggle
	local CONFIG_VERSION = 1
	local ROOT = "RayHub"
	local CONFIG_FOLDER = ROOT .. "/Configs"
	local USERDATA_FOLDER = ROOT .. "/Userdata"
	local MANAGER_FILE = ROOT .. "/Settings.json"
	local AUTOSAVE_FEATURE = "ConfigsAutosave"
	local MANAGER_FEATURES = { [AUTOSAVE_FEATURE] = true, ConfigsPerAccount = true }
	local AUTOLOAD_MODES = { "Disabled", "Default", "Last Used" }
	local managerSettings = {
		version = CONFIG_VERSION,
		defaultConfig = nil,
		autoloadMode = "Disabled",
		perAccount = false,
		lastConfigName = nil,
		autosave = false,
	}
	local selectedConfigName, loadedConfigName
	local loadedUserdata = false
	local autosaveEnabled = false
	local applyingConfig = false
	local autosaveQueued = false
	local lastSavedSnapshot
	local configNameInput, configDropdown, autoloadDropdown
	local refreshAutomationInfo

	local function fsFunction(name)
		local fn = _G[name]
		if type(fn) == "function" then return fn end
		local environment = (getgenv and getgenv()) or _G
		fn = environment[name]
		return type(fn) == "function" and fn or nil
	end

	local function jsonFunction(name)
		local candidates = { _G }
		if getgenv then
			local ok, environment = pcall(getgenv)
			if ok and type(environment) == "table" and environment ~= _G then
				table.insert(candidates, 1, environment)
			end
		end
		for _, environment in ipairs(candidates) do
			local ok, api = pcall(function() return environment.json end)
			if ok and api ~= nil then
				local found, fn = pcall(function() return api[name] end)
				if found and type(fn) == "function" then return fn end
			end
		end
		local ok, api = pcall(function() return json end)
		if ok and api ~= nil then
			local found, fn = pcall(function() return api[name] end)
			if found and type(fn) == "function" then return fn end
		end
		return nil
	end

	local function ensureFolder(path)
		local isfolderFn, makefolderFn = fsFunction("isfolder"), fsFunction("makefolder")
		if not makefolderFn then return false, "Project Real makefolder is unavailable." end
		local current = ""
		for part in path:gmatch("[^/]+") do
			current = current == "" and part or (current .. "/" .. part)
			local exists = false
			if isfolderFn then
				local checked, result = pcall(isfolderFn, current)
				exists = checked and result == true
			end
			if not exists then
				local ok, err = pcall(makefolderFn, current)
				if not ok then
					if isfolderFn then
						local verified, result = pcall(isfolderFn, current)
						if verified and result == true then continue end
					end
					return false, tostring(err)
				end
			end
		end
		return true
	end

	local function readJson(path)
		local readfileFn = fsFunction("readfile")
		if not readfileFn then return nil, "Project Real readfile is unavailable." end
		local ok, contents = pcall(readfileFn, path)
		if not ok or type(contents) ~= "string" then return nil, tostring(contents) end
		local decode = jsonFunction("decode")
		if decode then
			local decoded, value = pcall(decode, contents)
			if decoded and type(value) == "table" then return value end
			if not decoded then return nil, tostring(value) end
		end
		local decoded, value = pcall(function()
			return game:GetService("HttpService"):JSONDecode(contents)
		end)
		if not decoded or type(value) ~= "table" then
			return nil, decoded and "JSON data must be an object." or ("JSON decode failed: " .. tostring(value))
		end
		return value
	end

	local function encodeJson(value)
		local encode = jsonFunction("encode")
		if encode then
			local ok, contents = pcall(encode, value)
			if ok and type(contents) == "string" then return contents end
		end
		local ok, contents = pcall(function()
			return game:GetService("HttpService"):JSONEncode(value)
		end)
		if not ok or type(contents) ~= "string" then return nil, tostring(contents) end
		return contents
	end

	local function writeJson(path, value)
		local writefileFn = fsFunction("writefile")
		if not writefileFn then return false, "Project Real writefile is unavailable." end
		local contents, encodeError = encodeJson(value)
		if not contents then return false, encodeError end
		local ok, err = pcall(writefileFn, path, contents)
		if not ok then return false, tostring(err) end
		return true
	end

	local function fileExists(path)
		local isfileFn = fsFunction("isfile")
		if not isfileFn then return false end
		local ok, exists = pcall(isfileFn, path)
		return ok and exists == true
	end

	local function configPath(name)
		return CONFIG_FOLDER .. "/" .. name .. ".json"
	end

	local function accountPath()
		local userId = ctx.player and ctx.player.UserId
		if type(userId) ~= "number" or userId <= 0 then return nil end
		return USERDATA_FOLDER .. "/" .. tostring(math.floor(userId)) .. ".json"
	end

	local function saveManagerSettings()
		return writeJson(MANAGER_FILE, managerSettings)
	end

	local function loadManagerSettings()
		local value = readJson(MANAGER_FILE)
		if type(value) ~= "table" or value.version ~= CONFIG_VERSION then return end
		if type(value.defaultConfig) == "string" then managerSettings.defaultConfig = value.defaultConfig end
		if table.find(AUTOLOAD_MODES, value.autoloadMode) then managerSettings.autoloadMode = value.autoloadMode end
		if type(value.perAccount) == "boolean" then managerSettings.perAccount = value.perAccount end
		if type(value.lastConfigName) == "string" then managerSettings.lastConfigName = value.lastConfigName end
		if type(value.autosave) == "boolean" then managerSettings.autosave = value.autosave end
	end

	local function normalizeName(raw)
		if type(raw) ~= "string" then return nil, "Enter a configuration name." end
		local name = raw:match("^%s*(.-)%s*$")
		if #name == 0 then return nil, "Enter a configuration name." end
		if #name > 32 or not name:match("^[%w _%-]+$") then
			return nil, "Use up to 32 letters, numbers, spaces, underscores, or hyphens."
		end
		local lower = string.lower(name)
		if lower == "con" or lower == "prn" or lower == "aux" or lower == "nul"
			or lower:match("^com[1-9]$") or lower:match("^lpt[1-9]$") then
			return nil, "That name is reserved by the filesystem."
		end
		return name
	end

	local function sortedConfigNames()
		local ok, err = ensureFolder(CONFIG_FOLDER)
		if not ok then return nil, err end
		local listfilesFn = fsFunction("listfiles")
		if not listfilesFn then return nil, "Project Real listfiles is unavailable." end
		local listed, paths = pcall(listfilesFn, CONFIG_FOLDER)
		if not listed or type(paths) ~= "table" then return nil, tostring(paths) end
		local names, seen = {}, {}
		for _, path in ipairs(paths) do
			if type(path) == "string" then
				local normalized = path:gsub("\\", "/")
				local base = normalized:match("([^/]+)$")
				if base and string.lower(base:sub(-5)) == ".json" then
					local name = base:sub(1, -6)
					local valid = normalizeName(name)
					local key = string.lower(name)
					if valid and not seen[key] then
						seen[key] = true
						table.insert(names, name)
					end
				end
			end
		end
		table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
		return names
	end

	local function refreshList()
		local names = sortedConfigNames()
		if not names then return false end
		configDropdown.SetOptions(names)
		if selectedConfigName and table.find(names, selectedConfigName) then
			configDropdown.SetValue(selectedConfigName)
		elseif selectedConfigName then
			selectedConfigName = nil
			configDropdown.SetValue(nil)
		end
		return true
	end

	local function collectSettings()
		local features = {}
		for key, value in pairs(ctx.State.Features) do
			if not MANAGER_FEATURES[key] and type(value) == "boolean" then features[key] = value end
		end
		local modules = {}
		for key, adapter in pairs(ctx.ConfigAdapters) do
			if type(adapter) == "table" and type(adapter.get) == "function" then
				local ok, value = pcall(adapter.get)
				if not ok then return nil, "Could not capture " .. tostring(key) .. " settings: " .. tostring(value) end
				if type(value) == "table" then modules[key] = value end
			end
		end
		return {
			features = features,
			hotkey = ctx.State.Hotkey and ctx.State.Hotkey.Name or nil,
			modules = modules,
		}
	end

	local function snapshotEncoded()
		local settings, err = collectSettings()
		if not settings then return nil, err end
		local encoded, encodeError = encodeJson(settings)
		if not encoded then return nil, encodeError end
		return encoded, settings
	end

	local function applySettings(settings)
		if type(settings) ~= "table" or type(settings.features) ~= "table" then
			return false, "Configuration has an invalid settings section."
		end
		local warnings = {}
		applyingConfig = true
		local modules = type(settings.modules) == "table" and settings.modules or {}
		for key, adapter in pairs(ctx.ConfigAdapters) do
			local moduleSettings = modules[key]
			if moduleSettings ~= nil and type(adapter.set) == "function" then
				local ok, err = pcall(adapter.set, moduleSettings)
				if not ok then table.insert(warnings, tostring(key) .. ": " .. tostring(err)) end
			end
		end
		if type(settings.hotkey) == "string" then
			local ok, hotkey = pcall(function() return Enum.KeyCode[settings.hotkey] end)
			if ok and hotkey then ctx.State.Hotkey = hotkey end
		end
		for key in pairs(ctx.State.Features) do
			if not MANAGER_FEATURES[key] and type(settings.features[key]) == "boolean" then
				local ok, err = pcall(ctx.SetFeature, key, settings.features[key])
				if not ok then table.insert(warnings, key .. ": " .. tostring(err)) end
			end
		end
		applyingConfig = false
		ctx.notify()
		return true, #warnings > 0 and table.concat(warnings, "; ") or nil
	end

	local function makePayload(settings)
		return { version = CONFIG_VERSION, settings = settings }
	end

	local function saveAccountSettings(settings)
		local path = accountPath()
		if not path then return false, "Player account ID is unavailable." end
		local ok, err = ensureFolder(USERDATA_FOLDER)
		if not ok then return false, err end
		return writeJson(path, makePayload(settings))
	end

	local function saveAutosavedSettings()
		if not ctx.Alive or not autosaveEnabled or not (loadedConfigName or loadedUserdata) then return end
		local encoded, settings = snapshotEncoded()
		if not encoded then return end
		if encoded == lastSavedSnapshot then return end
		local errors = {}
		if loadedConfigName then
			local ok, err = writeJson(configPath(loadedConfigName), makePayload(settings))
			if not ok then table.insert(errors, tostring(err)) end
		end
		if loadedUserdata or managerSettings.perAccount then
			local ok, err = saveAccountSettings(settings)
			if not ok then table.insert(errors, tostring(err)) end
		end
		if #errors == 0 then
			lastSavedSnapshot = encoded
		end
	end

	ctx.SetConfigDirtyHandler(function(featureName)
		if not autosaveEnabled or applyingConfig or MANAGER_FEATURES[featureName] then return end
		if autosaveQueued then return end
		autosaveQueued = true
		task.defer(function()
			autosaveQueued = false
			saveAutosavedSettings()
		end)
	end)

	local function saveConfig(name, creating)
		local safeName = normalizeName(name)
		if not safeName then return false end
		local path = configPath(safeName)
		if creating and fileExists(path) then return false end
		if creating and not fsFunction("isfile") then return false end
		local encoded, settingsOrError = snapshotEncoded()
		if not encoded then return false end
		local payload = makePayload(settingsOrError)
		local ok = writeJson(path, payload)
		if not ok then return false end
		selectedConfigName, loadedConfigName, loadedUserdata = safeName, safeName, false
		configNameInput.Text = safeName
		lastSavedSnapshot = encoded
		managerSettings.lastConfigName = safeName
		saveManagerSettings()
		if managerSettings.perAccount then
			saveAccountSettings(settingsOrError)
		end
		refreshList()
		return true
	end

	local function readPayload(path)
		local payload, err = readJson(path)
		if not payload then return nil, err end
		if payload.version ~= CONFIG_VERSION or type(payload.settings) ~= "table" then
			return nil, "Unsupported or invalid config format."
		end
		return payload
	end

	local function applyPayload(payload, isUserdata, configName)
		local ok, warnings = applySettings(payload.settings)
		if not ok then return false end
		if warnings then warn("[RayHub] Config loaded with skipped settings: " .. warnings) end
		local encoded = encodeJson(payload.settings)
		lastSavedSnapshot = encoded
		if isUserdata then loadedConfigName = nil else loadedConfigName = configName end
		loadedUserdata = isUserdata
		return true
	end

	local function loadConfig(name)
		local safeName = normalizeName(name)
		if not safeName then return false end
		local payload = readPayload(configPath(safeName))
		if not payload then return false end
		selectedConfigName = safeName
		configDropdown.SetValue(safeName)
		configNameInput.Text = safeName
		managerSettings.lastConfigName = safeName
		local ok = applyPayload(payload, false, safeName)
		if ok and ctx.Alive then saveManagerSettings() end
		return ok
	end

	local function loadUserdata()
		local path = accountPath()
		if not path then return false end
		local payload = readPayload(path)
		if not payload then return false end
		return applyPayload(payload, true)
	end

	local function selectedName()
		local input = configNameInput and configNameInput.Text or ""
		if input:match("^%s*$") then return selectedConfigName end
		return input
	end

	local function createAction()
		local safeName = normalizeName(configNameInput.Text)
		if not safeName then return end
		saveConfig(safeName, true)
	end

	local function saveAction()
		local name = selectedName()
		if not name then return end
		saveConfig(name, false)
	end

	local function loadAction()
		local name = selectedName()
		if not name then return end
		loadConfig(name)
	end

	local function deleteAction()
		local name = normalizeName(selectedName())
		if not name then return end
		local path = configPath(name)
		local delfileFn = fsFunction("delfile")
		if not delfileFn then return end
		if not fileExists(path) then return end
		local ok = pcall(delfileFn, path)
		if not ok then return end
		if managerSettings.defaultConfig == name then managerSettings.defaultConfig = nil; saveManagerSettings() end
		if loadedConfigName == name then loadedConfigName = nil; lastSavedSnapshot = nil end
		selectedConfigName = nil
		configNameInput.Text = ""
		configDropdown.SetValue(nil)
		refreshList()
	end

	local function setDefaultAction()
		local name = normalizeName(selectedName())
		if not name then return end
		if not fileExists(configPath(name)) then return end
		managerSettings.defaultConfig = name
		saveManagerSettings()
		if refreshAutomationInfo then refreshAutomationInfo() end
	end

	local function clearDefaultAction()
		managerSettings.defaultConfig = nil
		saveManagerSettings()
		if refreshAutomationInfo then refreshAutomationInfo() end
	end

	local function buttonRow(parent, order, firstText, firstFn, secondText, secondFn)
		local row = create("Frame", {
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 24),
			BackgroundTransparency = 1,
			Parent = parent,
		})
		local first = makeButton({
			Position = UDim2.new(0, 0, 0, 0), Size = UDim2.new(0.5, -4, 1, 0),
			Text = firstText, Parent = row,
		})
		first.Activated:Connect(firstFn)
		if secondText then
			local second = makeButton({
				Position = UDim2.new(0.5, 4, 0, 0), Size = UDim2.new(0.5, -4, 1, 0),
				Text = secondText, Parent = row,
			})
			second.Activated:Connect(secondFn)
		end
	end

	local tab = ctx.addTab(7, "Settings")
	local configBody = makeCard(tab.left, function(tile)
		create("TextLabel", {
			Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "⚙",
			Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = THEME.accent, Parent = tile,
		})
	end, "Configs")

	configNameInput = makeInput(configBody, 1, "Configuration name", "", "e.g. Main")
	configDropdown = makeDropdown(configBody, 2, {
		label = "Select configuration",
		placeholder = "Choose a config...",
		emptyText = "No configs found",
		searchable = true,
		onSelect = function(name)
			selectedConfigName = name
			configNameInput.Text = name or ""
		end,
	})
	buttonRow(configBody, 3, "Create", createAction, "Save", saveAction)
	buttonRow(configBody, 4, "Load", loadAction, "Delete", deleteAction)
	buttonRow(configBody, 5, "Set as Default", setDefaultAction, "Clear Default", clearDefaultAction)
	local refreshButton = makeButton({
		LayoutOrder = 6, Size = UDim2.new(1, 0, 0, 24), Text = "Refresh List", Parent = configBody,
	})
refreshButton.Activated:Connect(refreshList)

	autoloadDropdown = makeDropdown(configBody, 7, {
		label = "Autoload Mode",
		placeholder = "Disabled",
		onSelect = function(value)
			if not table.find(AUTOLOAD_MODES, value) then return end
			managerSettings.autoloadMode = value
			saveManagerSettings()
			if refreshAutomationInfo then refreshAutomationInfo() end
		end,
	})
	autoloadDropdown.SetOptions(AUTOLOAD_MODES)
	autoloadDropdown.SetValue(managerSettings.autoloadMode)
	ctx.FeatureHandlers[AUTOSAVE_FEATURE] = function(enabled)
		autosaveEnabled = enabled
		managerSettings.autosave = enabled
		if ctx.Alive then saveManagerSettings() end
	end
	makeToggle(configBody, 8, "Autosave Loaded Config", AUTOSAVE_FEATURE)
	local userdataButton = makeButton({
		LayoutOrder = 9, Size = UDim2.new(1, 0, 0, 24), Text = "Load Userdata", Parent = configBody,
	})
	userdataButton.Activated:Connect(loadUserdata)
	makeToggle(configBody, 10, "Per Account", "ConfigsPerAccount")
	ctx.FeatureHandlers.ConfigsPerAccount = function(enabled)
		managerSettings.perAccount = enabled
		if ctx.Alive then saveManagerSettings() end
		if refreshAutomationInfo then refreshAutomationInfo() end
	end
	local defaultLine = makeLine(configBody, 11, 11, THEME.subtext)
	local autoloadLine = makeLine(configBody, 12, 11, THEME.subtext)
	refreshAutomationInfo = function()
		defaultLine.Text = "Default: " .. (managerSettings.defaultConfig or "None")
		autoloadLine.Text = "Autoload: " .. managerSettings.autoloadMode .. (managerSettings.perAccount and " • Per Account" or "")
		autoloadDropdown.SetValue(managerSettings.autoloadMode)
	end
	refreshAutomationInfo()
	ctx.SetFeature(AUTOSAVE_FEATURE, managerSettings.autosave)

	loadManagerSettings()
	autosaveEnabled = managerSettings.autosave
	if managerSettings.autosave ~= ctx.GetFeature(AUTOSAVE_FEATURE) then
		ctx.SetFeature(AUTOSAVE_FEATURE, managerSettings.autosave)
	end
	if managerSettings.perAccount ~= ctx.GetFeature("ConfigsPerAccount") then
		ctx.SetFeature("ConfigsPerAccount", managerSettings.perAccount)
	end
	if managerSettings.defaultConfig then
		selectedConfigName = managerSettings.defaultConfig
		configDropdown.SetValue(selectedConfigName)
		configNameInput.Text = selectedConfigName
	end
	refreshAutomationInfo()
	refreshList()
	if managerSettings.perAccount then
		task.defer(function() if ctx.Alive then loadUserdata() end end)
	elseif managerSettings.autoloadMode == "Default" and managerSettings.defaultConfig then
		task.defer(function() if ctx.Alive then loadConfig(managerSettings.defaultConfig) end end)
	elseif managerSettings.autoloadMode == "Last Used" and managerSettings.lastConfigName then
		task.defer(function() if ctx.Alive then loadConfig(managerSettings.lastConfigName) end end)
	end
end
