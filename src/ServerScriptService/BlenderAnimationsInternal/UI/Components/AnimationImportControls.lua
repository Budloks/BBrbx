--!strict

-- BBrbx Animate tab: "From Blender" card (connect, pick armature, import the
-- actions you tick - the default - or just the current timeline, live sync) and a collapsed "From file or clipboard" card.

local State = require(script.Parent.Parent.Parent.state)
local Fusion = require(script.Parent.Parent.Parent.Packages.Fusion)

local New = Fusion.New
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local OnChange = Fusion.OnChange
local Value = Fusion.Value
local Computed = Fusion.Computed

local StudioComponents = script.Parent.Parent.Parent.Components:FindFirstChild("StudioComponents")
local Checkbox = require(StudioComponents.Checkbox)
local TextInput = require(StudioComponents.TextInput)
local VerticalCollapsibleSection = require(StudioComponents.VerticalCollapsibleSection)

local Kit = require(script.Parent.Parent.Kit)
local BulkActions = require(script.Parent.BulkActions)

local AnimationImportControls = {}

local function armatureRow(armature: any, order: number)
	local hovering = Value(false)
	local isSelected = Computed(function()
		local selected = State.selectedArmature:get()
		return selected ~= nil and (selected :: any).name == armature.name
	end)
	return New("TextButton")({
		Name = "Armature",
		LayoutOrder = order,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = Computed(function()
			local style = if isSelected:get()
				then Enum.StudioStyleGuideColor.DiffFilePathBackground
				elseif hovering:get() then Enum.StudioStyleGuideColor.Button
				else Enum.StudioStyleGuideColor.MainBackground
			return Kit.color(style):get()
		end),
		[OnEvent("MouseEnter")] = function()
			hovering:set(true)
		end,
		[OnEvent("MouseLeave")] = function()
			hovering:set(false)
		end,
		[OnEvent("Activated")] = function()
			State.selectedArmature:set(armature)
		end,
		[Children] = {
			Kit.corner(5),
			Kit.padding(0, 8),
			New("TextLabel")({
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -60, 1, 0),
				Text = armature.name,
				Font = Enum.Font.BuilderSansMedium,
				TextSize = Kit.TEXT,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Kit.color(Enum.StudioStyleGuideColor.MainText),
			}),
			New("TextLabel")({
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.new(0, 60, 1, 0),
				Text = string.format("%d bones", armature.num_bones or 0),
				Font = Enum.Font.BuilderSans,
				TextSize = Kit.SMALL_TEXT,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextColor3 = Kit.color(Enum.StudioStyleGuideColor.DimmedText),
			}),
		},
	})
end

function AnimationImportControls.createBlenderCard(services: any, layoutOrder: number)
	local hint = Value("")
	local connected = State.isServerConnected
	local disconnected = Computed(function()
		return not connected:get()
	end)
	local hasArmature = Computed(function()
		return connected:get() and State.selectedArmature:get() ~= nil
	end)

	local function hover(text: string)
		return function(on: boolean)
			hint:set(if on then text else "")
		end
	end

	return VerticalCollapsibleSection({
		Text = "From Blender",
		Subtitle = Computed(function()
			if not connected:get() then
				return "not connected"
			end
			local selected = State.selectedArmature:get()
			return if selected then (selected :: any).name else "pick an armature"
		end),
		Collapsed = false,
		LayoutOrder = layoutOrder,
		[Children] = {
			-- Not connected: port + connect
			Kit.FieldLabel({ Text = "Blender port", LayoutOrder = 1, Visible = disconnected }),
			Kit.Row({
				LayoutOrder = 2,
				Visible = disconnected,
				[Children] = {
					TextInput({
						PlaceholderText = "31337",
						LayoutOrder = 1,
						Size = UDim2.new(0, 70, 1, 0),
						Text = Computed(function()
							return tostring(State.serverPort:get())
						end),
						[OnChange("Text")] = function(newPort)
							local port = tonumber(newPort)
							if port and port >= 1024 and port <= 65535 then
								State.serverPort:set(port)
							end
						end,
					}),
					Kit.PrimaryButton({
						Text = "Connect",
						LayoutOrder = 2,
						Size = UDim2.new(0, 0, 1, 0),
						Activated = function()
							services.blenderSyncManager:toggleServerConnection()
						end,
						OnHover = hover("Connects to the BBrbx add-on in Blender (same port on both sides)."),
					}),
				},
			}),
			Kit.Hint({
				Text = Computed(function()
					local status = State.serverStatus:get()
					return if status and status ~= "" and status ~= "Disconnected"
						then status
						else "Blender starts the server by itself when BBrbx is enabled."
				end),
				LayoutOrder = 3,
				Visible = disconnected,
			}),

			-- Connected: armature list, import, live sync
			Kit.FieldLabel({ Text = "Armature", LayoutOrder = 4, Visible = connected }),
			New("Frame")({
				Name = "Armatures",
				LayoutOrder = 5,
				Visible = connected,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				[Children] = {
					Kit.vlist(2),
					Computed(function()
						local armatures = State.availableArmatures:get() :: any
						local rows = {}
						if #armatures == 0 then
							table.insert(rows, Kit.Hint({ Text = "No armatures in the open Blender file.", LayoutOrder = 1 }))
						end
						for i, armature in ipairs(armatures) do
							table.insert(rows, armatureRow(armature, i))
						end
						return rows
					end, Fusion.cleanup),
				},
			}),
			BulkActions.createBody(services, 6, connected),
			Kit.Row({
				LayoutOrder = 7,
				Visible = connected,
				[Children] = {
					Kit.Button({
						Text = "Import current timeline",
						LayoutOrder = 1,
						Size = UDim2.new(0, 0, 1, 0),
						Enabled = hasArmature,
						Activated = function()
							State.loadingEnabled:set(true)
							local ok = services.blenderSyncManager:importAnimationFromBlender()
							State.loadingEnabled:set(false)
							if not ok then
								services.rigManager:addWarning("Failed to import animation from Blender")
							end
						end,
						OnHover = hover("Imports only what's on the Blender timeline right now, without saving it."),
					}),
					Kit.Button({
						Text = "Send to Blender",
						LayoutOrder = 2,
						Size = UDim2.new(0, 0, 1, 0),
						Enabled = Computed(function()
							return State.animationLength:get() > 0
						end),
						Activated = function()
							State.loadingEnabled:set(true)
							local ok = services.blenderSyncManager:exportAnimationToBlender()
							State.loadingEnabled:set(false)
							if not ok then
								services.rigManager:addWarning("Failed to export animation to Blender")
							end
						end,
						OnHover = hover("Sends the animation playing in Studio to Blender."),
					}),
				},
			}),
			Checkbox({
				Text = "Live sync (update while you animate)",
				Value = State.liveSyncEnabled,
				LayoutOrder = 8,
				Visible = Computed(function()
					return connected:get() and State.enableLiveSync:get()
				end),
				Enabled = hasArmature,
				OnChange = function(newValue)
					State.liveSyncEnabled:set(newValue)
					if newValue then
						services.blenderSyncManager:startLiveSyncing()
					else
						services.blenderSyncManager:stopLiveSyncing()
					end
				end,
			}),
			Kit.Row({
				LayoutOrder = 9,
				Visible = connected,
				[Children] = {
					Kit.Button({
						Text = "Refresh armatures",
						LayoutOrder = 1,
						Size = UDim2.new(0, 0, 1, 0),
						Activated = function()
							services.blenderSyncManager:updateAvailableArmatures()
						end,
					}),
					Kit.Button({
						Text = "Disconnect",
						LayoutOrder = 2,
						Size = UDim2.new(0, 0, 1, 0),
						Activated = function()
							services.blenderSyncManager:toggleServerConnection()
						end,
					}),
				},
			}),
			Kit.Hint({
				Text = hint,
				LayoutOrder = 10,
				Visible = Computed(function()
					return hint:get() ~= ""
				end),
			}),
		},
	})
end

function AnimationImportControls.createLegacyCard(services: any, layoutOrder: number)
	local function importFromClipboard()
		services.playbackService:stopRigTrack(State.activeSessionRig:get())
		local marker = "Paste the animation data below this line"
		services.exportManager:clearMetaParts()
		if State.importScript then
			State.importScript:Destroy()
		end
		local plugin = script:FindFirstAncestorWhichIsA("Plugin")
		State.importScript = Instance.new("Script", game.Workspace)
		assert(State.importScript)
		State.importScript.Archivable = false
		State.importScript.Source = "-- " .. marker .. "\n"
		if plugin then
			plugin:OpenScript(State.importScript, 2)
		end
		local connection: RBXScriptConnection
		connection = State.importScript.Changed:Connect(function(prop)
			if prop ~= "Source" then
				return
			end
			connection:Disconnect()
			if State.importScript then
				local animData = select(3, string.find(State.importScript.Source, "^%-%- " .. marker .. "\n(.*)$"))
				State.importScript:Destroy()
				State.importScript = nil
				if animData then
					services.animationManager:loadAnimDataFromText(animData, false)
				end
			end
		end)
	end

	return VerticalCollapsibleSection({
		Text = "From file or clipboard",
		Subtitle = "baked in Blender",
		Collapsed = true,
		LayoutOrder = layoutOrder,
		Visible = Computed(function()
			return State.enableFileExport:get() or State.enableClipboardExport:get()
		end),
		[Children] = {
			Kit.Row({
				LayoutOrder = 1,
				[Children] = {
					Kit.Button({
						Text = "From file(s)",
						LayoutOrder = 1,
						Size = UDim2.new(0, 0, 1, 0),
						Visible = State.enableFileExport,
						Enabled = State.activeRigExists,
						Activated = function()
							services.animationManager:importAnimationsBulk()
						end,
					}),
					Kit.Button({
						Text = "From clipboard",
						LayoutOrder = 2,
						Size = UDim2.new(0, 0, 1, 0),
						Visible = State.enableClipboardExport,
						Enabled = State.activeRigExists,
						Activated = importFromClipboard,
					}),
				},
			}),
			Kit.Hint({
				Text = "For animations baked with Bake → File / Clipboard in Blender.",
				LayoutOrder = 2,
			}),
		},
	})
end

-- Kept for callers that still mount the combined control.
function AnimationImportControls.create(services: any, layoutOrder: number?)
	return AnimationImportControls.createBlenderCard(services, layoutOrder or 1)
end

return AnimationImportControls
