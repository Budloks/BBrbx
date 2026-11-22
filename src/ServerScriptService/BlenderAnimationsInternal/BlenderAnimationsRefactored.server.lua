





--!native
--!strict
--!optimize 2

local State = require(script.Parent.state)
local PlaybackService = require(script.Parent.Services.PlaybackService)

-- Import our new services
local RigManager = require(script.Parent.Services.RigManager)
local AnimationManager = require(script.Parent.Services.AnimationManager)
local BlenderSyncManager = require(script.Parent.Services.BlenderSyncManager)
local ExportManager = require(script.Parent.Services.ExportManager)
local CameraManager = require(script.Parent.Services.CameraManager)
local RigPushService = require(script.Parent.Services.RigPushService)
local DeformBindService = require(script.Parent.Services.DeformBindService)
local BulkService = require(script.Parent.Services.BulkService)
local RigDoctor = require(script.Parent.Services.RigDoctor)

-- Import UI components
local PlayerTab = require(script.Parent.UI.Tabs.PlayerTab)
local RiggingTab = require(script.Parent.UI.Tabs.RiggingTab)
local ToolsTab = require(script.Parent.UI.Tabs.ToolsTab)
local MoreTab = require(script.Parent.UI.Tabs.MoreTab)
local SharedComponents = require(script.Parent.UI.SharedComponents)
local RigTabs = require(script.Parent.UI.Components.RigTabs)
local RigSessionManager = require(script.Parent.RigSessionManager)

local Plugin = plugin

local Components = script.Parent.Components
local Packages = script.Parent.Packages

local PluginComponents = Components:FindFirstChild("PluginComponents")
local Widget = require(PluginComponents.Widget)
local Toolbar = require(PluginComponents.Toolbar)
local ToolbarButton = require(PluginComponents.ToolbarButton)
local Selection = game:GetService("Selection")
local UserInputService = game:GetService("UserInputService")
local StudioComponents = Components:FindFirstChild("StudioComponents")

local ScrollFrame = require(StudioComponents.ScrollFrame)
local Button = require(StudioComponents.Button)
local Label = require(StudioComponents.Label)
local Loading = require(StudioComponents.Loading)
local TextInput = require(StudioComponents.TextInput)
local VerticalCollapsibleSection = require(StudioComponents.VerticalCollapsibleSection)

local StudioComponentsUtil = StudioComponents:FindFirstChild("Util")
local themeProvider = require(StudioComponentsUtil.themeProvider)

local Fusion = require(Packages.Fusion)

local New = Fusion.New
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Value = Fusion.Value
local Computed = Fusion.Computed
local OnChange = Fusion.OnChange
local Observer = Fusion.Observer

local GLOBAL_HEADER_HEIGHT = 108
local TAB_BAR_HEIGHT = 32
local Kit = require(script.Parent.UI.Kit)
local RIG_TABS_HEIGHT = 28  -- 0 when no rigs, 28 when rigs present
-- Measured height of the auto-sizing global header (warnings can make it grow).
local globalHeaderHeight = Value(GLOBAL_HEADER_HEIGHT)

-- Initialize services
local playbackService = PlaybackService.new(State) :: any
local cameraManager = CameraManager.new()
local rigManager = RigManager.new(playbackService, cameraManager)
local animationManager = AnimationManager.new(playbackService, Plugin)
local exportManager = ExportManager.new(Plugin)
local blenderSyncManager = BlenderSyncManager.new(playbackService, animationManager)
local rigPushService = RigPushService.new(rigManager, blenderSyncManager)
local deformBindService = DeformBindService.new(rigManager, blenderSyncManager)
local bulkService = BulkService.new(animationManager, blenderSyncManager, Plugin)
local rigDoctor = RigDoctor.new(rigManager)


State.rigManager = rigManager
local rigSessionManager = RigSessionManager.new(State)
State.rigSessionManager = rigSessionManager

-- Create services object for passing to UI components
local services = {
	playbackService = playbackService,
	rigManager = rigManager,
	animationManager = animationManager,
	exportManager = exportManager,
	cameraManager = cameraManager,
	blenderSyncManager = blenderSyncManager,
	rigPushService = rigPushService,
	deformBindService = deformBindService,
	bulkService = bulkService,
	rigDoctor = rigDoctor,
	plugin = Plugin,
}

local function importAnimationFromClipboard()
	if not State.enableClipboardExport:get() then
		warn("Clipboard import is disabled in Settings.")
		return
	end
	if not State.activeRigExists:get() then
		warn("No active rig selected.")
		return
	end

	services.playbackService:stopRigTrack(State.activeSessionRig:get())
	local importScriptText = "Paste the animation data below this line"

	services.exportManager:clearMetaParts()
	if State.importScript then
		State.importScript:Destroy()
	end
	State.importScript = Instance.new("Script", game.Workspace)
	assert(State.importScript)
	State.importScript.Archivable = false
	State.importScript.Source = "-- " .. importScriptText .. "\n"
	Plugin:OpenScript(State.importScript, 2)
	local tempConnection: RBXScriptConnection
	tempConnection = State.importScript.Changed:Connect(function(prop)
		if prop == "Source" then
			tempConnection:Disconnect()
			if State.importScript then
				local animData = select(
					3,
					string.find(
						State.importScript.Source,
						"^%-%- " .. importScriptText .. "\n(.*)$"
					)
				)
				State.importScript:Destroy()
				State.importScript = nil
				if animData then
					services.animationManager:loadAnimDataFromText(animData, false)
				end
			end
		end
	end)
end

local function cleanupAll()
	-- 1. Stop running processes (synchronously so it finishes before unload)
	playbackService:stopAnimationAndDisconnect()
	
	blenderSyncManager:cleanup()

	-- 2. Disconnect UI-related connections
	cameraManager:cleanup()

	-- 3. Reset state variables
	State.loadingEnabled:set(false)
	State.loadingTitle:set("Working")
	State.loadingStatus:set("Please wait...")
	State.loadingDetail:set("")
	State.loadingProgress:set(0)
	State.loadingCanEstimate:set(false)
	State.rigModelName:set("No Rig Selected")
	State.keyframeStats:set({ count = 0, totalDuration = 0 })
	State.playhead:set(0)
	State.keyframeNames:set({})
	State.savedAnimations:set({})
	State.selectedSavedAnim:set(nil)
	State.activeRigModel = nil
	State.activeAnimator = nil
	State.activeRig = nil
	State.currentKeyframeSequence = nil
	State.isPlaying:set(false)
	State.isReversed:set(false)
	State.animationData = nil
	State.isSelectionLocked:set(false)
	State.activeRigExists:set(false)
	State.isFinished:set(false)
	rigManager:clearWarnings()

	-- 4. Clear multi-rig sessions and playback tracks
	playbackService._rigTracks = {}
	rigSessionManager:clear()
	State.rigTabOrder:set({})
	State.isAwaitingRigSelection:set(false)
end


-- Function to update the active rig based on the current selection in Studio
local function updateActiveRigFromSelection()
	if State.widgetsEnabled:get(true) and not State.isSelectionLocked:get() then
		local selection = Selection:Get()
		if #selection > 0 then
			local selectedObject = selection[1]

			-- BB fork: the legacy rig export selects its temporary clone (which still
			-- has a Humanoid); never treat that as a new active rig.
			for _, metaPart in ipairs(State.metaParts) do
				if selectedObject == metaPart or selectedObject:IsDescendantOf(metaPart) then
					return
				end
			end

			if rigManager:isKeyframeSequence(selectedObject) then
				State.lastSelectionWasKeyframeSequence = true
				return
			end

			if rigManager:isValidRig(selectedObject) then
				selectedObject = rigManager:resolveRigForSelection(selectedObject)
				if State.lastSelectionWasKeyframeSequence then
					State.lastSelectionWasKeyframeSequence = false
					return
				end

				if rigSessionManager:contains(selectedObject) then
					RigTabs._switchToRig(services, selectedObject)
					return
				end

				local currentRig = State.activeSessionRig:get()
				if currentRig and not State.isAwaitingRigSelection:get() then
					-- Outside explicit multi-rig selection, replace the sole session.
					playbackService:stopRigTrack(currentRig)
					rigSessionManager:remove(currentRig)
					State.rigTabOrder:set({})
					State.activeSessionRig:set(nil)
				end

				rigSessionManager:createAndActivate(selectedObject)
				RigTabs.addRigTab(selectedObject)
				State.isAwaitingRigSelection:set(false)
				State.animationLength:set(0)
				State.animationData = nil
				State.animationDirty:set(false)
				State.activeRigExists:set(true)
				rigManager:clearWarnings()
				State.loadingEnabled:set(true)
				-- BB fork: clear every per-rig field before snapshotting, otherwise the
				-- new rig's session briefly holds the previous rig's bone weights,
				-- saved animations and warnings (visible if you switch tabs while it loads).
				RigTabs._resetRigState(State, selectedObject)
				State.activeSessionRig:set(selectedObject)
				State.loadingEnabled:set(true)
				rigSessionManager:saveActive()

				task.spawn(function()
					rigManager:setRig(selectedObject)
					if State.activeSessionRig:get() == selectedObject then
						rigSessionManager:saveActive()
					end
				end)
			end
		elseif #selection == 0 then
			State.lastSelectionWasKeyframeSequence = false
		end
	end
end

-- BB fork: keep the camera on the active rig. Every rig change (selection, tab
-- switch, tab close) goes through activeSessionRig, so one observer covers all.
table.insert(
	State.observers,
	Observer(State.activeSessionRig):onChange(function()
		-- Switching rigs briefly sets the session to nil; react to where it ends up
		-- (deferred), otherwise the camera detaches instead of following the new rig.
		task.defer(function()
			cameraManager:onActiveRigChanged(State.activeSessionRig:get())
		end)
		local rigModel = State.activeSessionRig:get()
		-- BB fork: pick the Blender armature that belongs to this rig
		-- ("__<Rig>_Armature" from the importer) so you don't have to.
		if rigModel then
			local wanted = "__" .. rigModel.Name .. "_Armature"
			for _, arm in ipairs(State.availableArmatures:get() or {}) do
				if arm.name == wanted then
					local current = State.selectedArmature:get()
					if not current or (current :: any).name ~= wanted then
						State.selectedArmature:set(arm)
					end
					break
				end
			end
		end
	end)
)

-- Start live sync if enabled when an armature is selected
table.insert(
	State.observers,
	Observer(State.selectedArmature):onChange(function()
		if State.selectedArmature:get() and State.liveSyncEnabled:get() then
			blenderSyncManager:startLiveSyncing()
		end
	end)
)

-- Auto-connect runs as a background loop (see "BBrbx auto-connect" below).

do -- Creates the plugin
	local pluginToolbar = Toolbar({
		Plugin = Plugin,
		Name = "BBrbx",
	})

	local importClipboardAction = Plugin:CreatePluginAction(
		"BlenderAnimations_ImportClipboard",
		"Import Animation (Clipboard)",
		"Import animation data from clipboard",
		""
	)

	table.insert(
		State.connections,
		importClipboardAction.Triggered:Connect(function()
			State.activeTab:set("Import/Export")
			importAnimationFromClipboard()
		end)
	)

	-- BB fork: bindable shortcut (File > Advanced > Customize Shortcuts)
	local toggleCameraAction = Plugin:CreatePluginAction(
		"BBrbx_ToggleCamera",
		"BBrbx: Attach/Detach Camera",
		"Attach the camera to the active rig's CameraBone/Head (or the picked part), or detach it",
		""
	)
	table.insert(
		State.connections,
		toggleCameraAction.Triggered:Connect(function()
			if State.isCameraAttached:get() then
				cameraManager:detachCamera()
			else
				cameraManager:updatePartsList()
				cameraManager:attachCameraByName(State.selectedPartName:get())
			end
		end)
	)

	State.widgetsEnabled = Value(false)
	State.helpWidgetEnabled = Value(false)
	
	-- Update image based on current theme using themeProvider like PlaybackControls
	local Studio = settings().Studio
	-- BBrbx logo (assets/bbrbx-icon-white.png / -dark.png): white for the dark theme, dark for the light one
	local ICON_FOR_DARK_THEME = "rbxassetid://94842823053587"
	local ICON_FOR_LIGHT_THEME = "rbxassetid://84525378854113"
	local function updateToolbarImage()
		local bg = Studio.Theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
		local dark = (bg.R + bg.G + bg.B) / 3 < 0.5
		State.toolbarButtonImage:set(dark and ICON_FOR_DARK_THEME or ICON_FOR_LIGHT_THEME)
	end
	table.insert(State.connections, Studio.ThemeChanged:Connect(updateToolbarImage))
	
	-- Initial update
	updateToolbarImage()
	
	local enableButton = ToolbarButton({
		Plugin = Plugin,
		Toolbar = pluginToolbar,
		ClickableWhenViewportHidden = true,
		Name = "BBrbx",
		ToolTip = "Open BBrbx (Blender ⇄ Roblox rigs and animations)",
		Image = State.toolbarButtonImage:get(),

		[OnEvent("Click")] = function()
			(State.widgetsEnabled :: any):set(not (State.widgetsEnabled :: any):get())
		end,
	})
	
	
	-- Add observer for toolbar button image changes
	table.insert(State.observers, Observer(State.toolbarButtonImage):onChange(function()
		if enableButton and enableButton.Parent then
			pcall(function()
				enableButton.Image = State.toolbarButtonImage:get()
			end)
		end
	end))

	-- Handle plugin unloading
	Plugin.Unloading:Connect(function()
		-- Disconnect observers first to prevent them from firing during cleanup
		for _, obs in ipairs(State.observers) do
			obs()
		end
		table.clear(State.observers)

		-- Run cleanup synchronously to ensure stopAnimationAndDisconnect finishes before unload
		cleanupAll()

		if State.selectionConnection then
			State.selectionConnection:Disconnect()
			State.selectionConnection = nil
		end

		for _, conn in ipairs(State.connections) do
			conn:Disconnect()
		end
		table.clear(State.connections)
	end)

	-- Handle widget enabled/disabled
	table.insert(
		State.observers,
		(Observer(State.widgetsEnabled :: any) :: any):onChange(function(isEnabled: boolean)
				if enableButton and enableButton.Parent then
					enableButton:SetActive(isEnabled)
				end
				if isEnabled then
					updateActiveRigFromSelection()
				end
				return nil
			end) :: any
	)
	


	-- Load saved settings
    local savedDockSide = plugin:GetSetting("DockSide")
	if savedDockSide and typeof(savedDockSide) == "EnumItem" then
		State.dockSide:set(savedDockSide)
	end

    -- merge saved tab order with defaults (forward-compatible)
    do
        local defaults = { "Import/Export", "Play/Upload", "Extras", "Settings" }
        local defaultSet = {}
        for _, name in ipairs(defaults) do defaultSet[name] = true end

        local saved = plugin:GetSetting("TabOrder")
        local merged = {}
        local seen = {}

        if typeof(saved) == "table" then
            for _, name in ipairs(saved) do
                if defaultSet[name] and not seen[name] then
                    table.insert(merged, name)
                    seen[name] = true
                end
            end
        end

        for _, name in ipairs(defaults) do
            if not seen[name] then
                table.insert(merged, name)
            end
        end

        State.tabs:set(merged)
    end

    -- load persisted settings (tools/settings toggles)
    local ef = plugin:GetSetting("EnableFileExport")
    if typeof(ef) == "boolean" then
        State.enableFileExport:set(ef)
    else
        State.enableFileExport:set(true)
    end
    local ec = plugin:GetSetting("EnableClipboardExport")
    if typeof(ec) == "boolean" then
        State.enableClipboardExport:set(ec)
    else
        State.enableClipboardExport:set(true)
    end
    local els = plugin:GetSetting("EnableLiveSync")
    if typeof(els) == "boolean" then State.enableLiveSync:set(els) end
    -- BBrbx: own key, on by default (the old RBXMonkey key could hold false)
    local ac = plugin:GetSetting("BBAutoConnect")
    if typeof(ac) == "boolean" then State.autoConnectToBlender:set(ac) end
	local rm = plugin:GetSetting("ReducedMotion")
	if typeof(rm) == "boolean" then State.reducedMotion:set(rm) end
    local sd = plugin:GetSetting("ShowDebugInfo")
    if typeof(sd) == "boolean" then State.showDebugInfo:set(sd) end
    
    -- BBrbx auto-connect: while the plugin is open, quietly ping Blender every
    -- few seconds. Connect as soon as it answers, drop the link when it stops
    -- answering (Blender closed), and connect again when it comes back.
    -- Closing the plugin disconnects (cleanupAll).
    task.spawn(function()
        local HttpService = game:GetService("HttpService")
        local misses = 0
        local lastSession: string? = nil
        local function ping(): boolean
            local ok, body = pcall(function()
                return HttpService:GetAsync("http://localhost:" .. tostring(State.serverPort:get()) .. "/bb/ping", true)
            end)
            if ok then
                -- Blender restarted / another file opened faster than three
                -- missed pings: refresh armatures and actions on our own.
                local decoded = select(2, pcall(HttpService.JSONDecode, HttpService, body))
                local session = if type(decoded) == "table" then decoded.session else nil
                if type(session) == "string" then
                    local changed = lastSession ~= nil and lastSession ~= session
                    lastSession = session
                    if changed and State.isServerConnected:get() then
                        require(script.Parent.UI.Components.BulkActions).refreshAll(services)
                    end
                end
            end
            return ok
        end
        task.wait(1)
        while true do
            if State.widgetsEnabled:get() and State.autoConnectToBlender:get() then
                if not State.isServerConnected:get() then
                    if ping() and not State.isServerConnected:get() then
                        blenderSyncManager:toggleServerConnection()
                    end
                    misses = 0
                elseif not State.liveSyncEnabled:get() then
                    if ping() then
                        misses = 0
                    else
                        misses += 1
                        if misses >= 3 and State.isServerConnected:get() then
                            misses = 0
                            blenderSyncManager:cleanupServerConnection()
                        end
                    end
                end
            end
            task.wait(3)
        end
    end)

	-- BBrbx: horizontal tab bar (Animate / Rig / Tools / Settings)
	local function createTabsUI()
		local function makeButtons()
		local buttons: { [any]: any } = {
			New("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalFlex = Enum.UIFlexAlignment.Fill,
				VerticalFlex = Enum.UIFlexAlignment.Fill,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 2),
			}),
			Kit.padding(0, 8, 0, 8),
		}
		for i, tabName in ipairs(State.tabs:get()) do
			local hovering = Value(false)
			local isActive = Computed(function()
				return State.activeTab:get() == tabName
			end)
			table.insert(buttons, New("TextButton")({
				Name = tabName .. "TabButton",
				LayoutOrder = i,
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				Text = tabName,
				Font = Computed(function()
					return if isActive:get() then Enum.Font.BuilderSansBold else Enum.Font.BuilderSansMedium
				end),
				TextSize = 13,
				-- Width follows the label (Import/Export is long); flex Fill
				-- shares what is left so short tabs do not steal space.
				Size = UDim2.new(0, 0, 1, 0),
				AutomaticSize = Enum.AutomaticSize.X,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Computed(function()
					local style = if isActive:get() or hovering:get()
						then Enum.StudioStyleGuideColor.BrightText
						else Enum.StudioStyleGuideColor.DimmedText
					return themeProvider:GetColor(style):get()
				end),
				[OnEvent("MouseEnter")] = function()
					hovering:set(true)
				end,
				[OnEvent("MouseLeave")] = function()
					hovering:set(false)
				end,
				[OnEvent("Activated")] = function()
					State.activeTab:set(tabName)
				end,
				[Children] = New("Frame")({
					Name = "ActiveUnderline",
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.fromScale(0.5, 1),
					Size = UDim2.new(1, -8, 0, 2),
					BorderSizePixel = 0,
					BackgroundColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.DialogMainButton),
					Visible = isActive,
				}),
			}))
		end
		return buttons
		end
		return New("Frame")({
			Name = "TabBar",
			-- The widget uses Global ZIndex: keep the bar at 1 so its buttons draw on top of it.
			ZIndex = 1,
			Position = UDim2.fromOffset(0, RIG_TABS_HEIGHT),
			Size = UDim2.new(1, 0, 0, TAB_BAR_HEIGHT),
			BackgroundColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.MainBackground),
			BorderSizePixel = 0,
			[Children] = {
				New("Frame")({
					Name = "Buttons",
					BackgroundTransparency = 1,
					Size = UDim2.fromScale(1, 1),
					[Children] = Computed(function()
						local _ = State.tabs:get()
						return makeButtons()
					end, Fusion.cleanup),
				}),
				New("Frame")({
					Name = "Divider",
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.fromScale(0, 1),
					Size = UDim2.new(1, 0, 0, 1),
					BorderSizePixel = 0,
					BackgroundColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.Border),
				}),
			},
		})
	end

	-- Build tab content once to avoid re-parent churn on tab switches
	-- BBrbx layout: cards are built once, then placed in the tab where they are used.
	local animateCards = PlayerTab.create(services)
	local rigCards = RiggingTab.create(services)
	local toolCards = ToolsTab.create(services)
	local function place(list: { any })
		local placed = {}
		for _, card in ipairs(list) do
			if card then
				table.insert(placed, card)
				card.LayoutOrder = #placed
			end
		end
		return placed
	end
	local tabContent = {
		["Import/Export"] = place({
			Kit.SectionHeader({ Text = "Import" }),
			animateCards.fromBlender,
			rigCards.rigFromBlender,
			animateCards.fromFile,
			Kit.SectionHeader({ Text = "Export", Gap = 12 }),
			rigCards.sendRig,
			animateCards.sendAnimation,
			rigCards.exportBones,
		}),
		["Play/Upload"] = place({
			Kit.SectionHeader({ Text = "Play" }),
			toolCards.camera or false,
			Kit.SectionHeader({ Text = "Save and upload", Gap = 12 }),
			animateCards.save,
			-- Bone toggles always go last
			toolCards.boneToggles,
		}),
		Extras = place({
			rigCards.weapon,
			toolCards.markers or false,
			toolCards.modifiers,
		}),
		Settings = MoreTab.create(services),
	}

	-- Build rig tabs bar once
	local rigTabsBar = RigTabs.create(services)

	-- Dynamic Y offset (rig tabs bar is always present with at least the + button)
	local rigTabsOffset = RIG_TABS_HEIGHT

	local function makeTabFrame(tabName: string, children)
		local tabChildren = {
			_UIListLayout = New("UIListLayout")({
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 10),
			}),
			_UIPadding = New("UIPadding")({
				PaddingLeft = UDim.new(0, 10),
				PaddingRight = UDim.new(0, 14),
				PaddingBottom = UDim.new(0, 16),
				PaddingTop = UDim.new(0, 10),
			}),
		}
		for i, child in ipairs(children) do
			tabChildren["child" .. i] = child
		end
		return New("Frame")({
			Name = tabName .. "Tab",
			BackgroundTransparency = 1,
			Size = Computed(function()
				return if State.activeTab:get() == tabName
					then UDim2.new(1, 0, 0, 0)
					else UDim2.new(1, 0, 0, 0)
			end),
			AutomaticSize = Computed(function()
				return if State.activeTab:get() == tabName
					then Enum.AutomaticSize.Y
					else Enum.AutomaticSize.None
			end),
			Visible = Computed(function()
				return State.activeTab:get() == tabName
			end),
			[Children] = tabChildren,
		})
	end

	local tabFrames = {
		_ImportExportTab = makeTabFrame("Import/Export", tabContent["Import/Export"]),
		_PlayUploadTab = makeTabFrame("Play/Upload", tabContent["Play/Upload"]),
		_ExtrasTab = makeTabFrame("Extras", tabContent.Extras),
		_SettingsTab = makeTabFrame("Settings", tabContent.Settings),
	}

	local function handleMainWidgetEnabledChanged(isEnabled: boolean)
		if not isEnabled then
			cleanupAll()
		end
		if State.widgetsEnabled:get() ~= isEnabled then
			(State.widgetsEnabled :: any):set(isEnabled)
		end
		if isEnabled then
			updateActiveRigFromSelection()
		end
	end

	local function handleHelpWidgetEnabledChanged(isEnabled: boolean)
		if State.helpWidgetEnabled:get() ~= isEnabled then
			(State.helpWidgetEnabled :: any):set(isEnabled)
		end
	end

	-- Create the main widget
	local function pluginWidget()
		-- The header auto-sizes with its content (warnings can add lines), so
		-- the scroll area below offsets by the measured height instead of a
		-- fixed constant; otherwise long warnings overflow the header box.
		local globalHeaderFrame = nil :: any
		local globalHeader = New("Frame")({
			Name = "GlobalHeader",
			ZIndex = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Position = UDim2.fromOffset(0, rigTabsOffset + TAB_BAR_HEIGHT),
			BackgroundTransparency = 1,
			[Children] = {
				SharedComponents.createHeaderUI(services),
				New("Frame")({
					Name = "HeaderDivider",
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 0, 1, 0),
					Size = UDim2.new(1, 0, 0, 1),
					BackgroundColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.Border),
					BorderSizePixel = 0,
				}),
			},
			[OnChange("AbsoluteSize")] = function()
				if globalHeaderFrame then
					globalHeaderHeight:set((globalHeaderFrame :: Frame).AbsoluteSize.Y)
				end
			end,
		})
		globalHeaderFrame = globalHeader

		return Widget({
			Plugin = Plugin,
			Id = "BlenderAnimationsMain",
			Name = "BBrbx",
			InitialDockTo = State.dockSide:get(),
			InitialEnabled = false,
			ForceInitialEnabled = false,
			FloatingSize = Vector2.new(300, 640),
			MinimumSize = Vector2.new(250, 600),
			Enabled = State.widgetsEnabled,
			[Children] = New("Frame")({
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				[Children] = {
					createTabsUI(),
					-- Horizontal rig tabs (multi-rig support)
					New("Frame")({
						Name = "RigTabsContainer",
						ZIndex = 2,
						Size = UDim2.new(1, -112, 0, RIG_TABS_HEIGHT),
						Position = UDim2.fromOffset(0, 0),
						BackgroundTransparency = 1,
						[Children] = {
							rigTabsBar,
						},
					}),
					Kit.StatusPill({
						Text = Computed(function()
							return if State.isServerConnected:get()
								then "Blender :" .. tostring(State.serverPort:get())
								else "Blender offline"
						end),
						Ok = State.isServerConnected,
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.new(1, -8, 0, RIG_TABS_HEIGHT / 2),
					}),
					globalHeader,
					ScrollFrame({
						ZIndex = 1,
						Size = Computed(function()
							return UDim2.new(1, 0, 1, -(globalHeaderHeight:get() + rigTabsOffset + TAB_BAR_HEIGHT))
						end),
						Position = Computed(function()
							return UDim2.fromOffset(0, globalHeaderHeight:get() + rigTabsOffset + TAB_BAR_HEIGHT)
						end),
						BackgroundTransparency = 1,
						AutomaticCanvasSize = Enum.AutomaticSize.Y,
						[Children] = {
							_ImportExportTab = tabFrames._ImportExportTab,
							_PlayUploadTab = tabFrames._PlayUploadTab,
							_ExtrasTab = tabFrames._ExtrasTab,
							_SettingsTab = tabFrames._SettingsTab,
						},
					}),
					Loading({
						Enabled = State.loadingEnabled,
						Title = State.loadingTitle,
						Status = State.loadingStatus,
						Detail = State.loadingDetail,
						Progress = State.loadingProgress,
						CanEstimate = State.loadingCanEstimate,
					}),
			},
			}),
		})
	end

	-- Create the main widget with tab content
	local mainWidget = pluginWidget()
	table.insert(State.connections, mainWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
		handleMainWidgetEnabledChanged(mainWidget.Enabled)
	end))
	mainWidget:BindToClose(function()
		handleMainWidgetEnabledChanged(false)
	end)
	

end

-- BB fork: remember the part/bone selected in Studio so the camera can be
-- attached to any part, not only to parts of a rig.
local function updateSelectedWorldPart()
	local picked: Instance? = nil
	for _, inst in ipairs(Selection:Get()) do
		if inst:IsA("BasePart") or inst:IsA("Bone") then
			picked = inst
			break
		end
	end
	if State.selectedWorldPart:get() ~= picked then
		State.selectedWorldPart:set(picked)
		-- the Camera dropdown shows the selected part right away
		cameraManager:updatePartsList()
	end
end
updateSelectedWorldPart()
table.insert(State.connections, Selection.SelectionChanged:Connect(updateSelectedWorldPart))

if not State.selectionConnection or not State.selectionConnection.Connected then
	State.selectionConnection = Selection.SelectionChanged:Connect(updateActiveRigFromSelection)
end

-- Tab hotkey (Tab / Shift+Tab) to cycle tabs
table.insert(
	State.connections,
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if not State.widgetsEnabled:get() then
			return
		end
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode ~= Enum.KeyCode.Tab then
			return
		end

		local tabs = State.tabs:get()
		if #tabs == 0 then
			return
		end
		local current = State.activeTab:get()
		local currentIndex = 1
		for i, t in ipairs(tabs) do
			if t == current then
				currentIndex = i
				break
			end
		end
		local isShift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local step = isShift and -1 or 1
		local nextIndex = currentIndex + step
		if nextIndex > #tabs then
			nextIndex = 1
		elseif nextIndex < 1 then
			nextIndex = #tabs
		end
		State.activeTab:set(tabs[nextIndex])
	end)
)



