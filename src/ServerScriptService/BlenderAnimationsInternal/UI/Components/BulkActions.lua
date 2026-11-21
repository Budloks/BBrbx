--!strict

-- BBrbx action list. One shared model (rows from Blender + AnimSaves, status,
-- busy flag, settings) and two views of it:
--   * importBody  - Import/Export tab: tick actions, import them into AnimSaves
--   * uploadBody  - Play/Upload tab:   tick actions or saves, upload to Roblox
-- Both views share the same rows and ticks, so what you pick in one shows in
-- the other.

local State = require(script.Parent.Parent.Parent.state)
local Fusion = require(script.Parent.Parent.Parent.Packages.Fusion)

local New = Fusion.New
local Children = Fusion.Children
local Value = Fusion.Value
local Computed = Fusion.Computed
local ForValues = Fusion.ForValues
local OnEvent = Fusion.OnEvent
local OnChange = Fusion.OnChange

local StudioComponents = script.Parent.Parent.Parent.Components:FindFirstChild("StudioComponents")
local Checkbox = require(StudioComponents.Checkbox)
local Dropdown = require(StudioComponents.Dropdown)
local TextInput = require(StudioComponents.TextInput)
local VerticalCollapsibleSection = require(StudioComponents.VerticalCollapsibleSection)
local Kit = require(script.Parent.Parent.Kit)

local PRIORITIES = { "Core", "Idle", "Movement", "Action", "Action2", "Action3", "Action4" }

local BulkActions = {}

-- Other cards ask for a fresh list after they change Blender (Send to Blender).
local refreshRequests = Instance.new("BindableEvent")
function BulkActions.requestRefresh()
	refreshRequests:Fire()
end

local model: any = nil

local function getModel(services: any)
	if model then
		return model
	end
	local bulk = services.bulkService
	local m: any = {
		rows = Value({} :: { any }),
		status = Value("Connect to Blender to list the actions of this rig."),
		busy = Value(false),
		priority = Value(bulk:getSetting("priority")),
		loop = Value(bulk:getSetting("loop")),
		overwrite = Value(bulk:getSetting("overwrite")),
		outputFolder = Value(bulk:getSetting("outputFolder")),
		keepIds = Value(bulk:getSetting("keepIds")),
		creatorType = Value(bulk:getSetting("creatorType")),
		groupId = Value(tostring(bulk:getSetting("groupId") or "")),
		writeIdModule = Value(bulk:getSetting("writeIdModule")),
	}
	m.bulk = bulk

	function m.selected(filter: ((any) -> boolean)?): { any }
		local list = {}
		for _, r in ipairs(m.rows:get()) do
			if r.sel:get() and (filter == nil or filter(r)) then
				table.insert(list, r)
			end
		end
		return list
	end

	function m.refresh()
		local ok, data = bulk:listActions()
		if not ok then
			m.status:set(tostring(data))
			m.rows:set({})
			return
		end
		local previous = {}
		for _, r in ipairs(m.rows:get()) do
			previous[r.target] = r.sel:get()
		end
		local list = {}
		local nBlender = 0
		for _, r in ipairs(data.rows) do
			local default = r.blender
			if previous[r.target] ~= nil then
				default = previous[r.target]
			end
			r.sel = Value(default)
			table.insert(list, r)
			if r.blender then
				nBlender += 1
			end
		end
		m.rows:set(list)
		m.status:set(
			if data.blenderError
				then "Blender: " .. tostring(data.blenderError) .. " (showing saves only)"
				else string.format("%d action(s) in %s, %d row(s) total", nBlender, tostring(data.armature), #list)
		)
	end

	function m.run(label: string, fn: (progress: (number, number, string) -> ()) -> any)
		if m.busy:get() then
			return
		end
		m.busy:set(true)
		m.status:set(label .. "…")
		task.spawn(function()
			local ok, result = pcall(fn, function(done: number, total: number, text: string)
				m.status:set(string.format("%s (%d/%d)", text, done, total))
			end)
			m.busy:set(false)
			if not ok then
				m.status:set("Error: " .. tostring(result))
				warn("[BBrbx] " .. tostring(result))
			else
				m.status:set(result.message)
				m.refresh()
			end
		end)
	end

	function m.setAll(predicate: (any) -> boolean)
		for _, r in ipairs(m.rows:get()) do
			r.sel:set(predicate(r))
		end
	end

	-- Keep the list current without pressing anything. Rig state settles a
	-- moment after the selection changes, so wait a beat before asking Blender.
	local pending = false
	function m.autoRefresh()
		if pending then
			return
		end
		pending = true
		task.delay(0.3, function()
			pending = false
			if m.busy:get() then
				return
			end
			if not State.activeRigExists:get() then
				m.rows:set({})
				m.status:set("Select a rig to list its actions.")
				return
			end
			m.refresh()
		end)
	end
	Fusion.Observer(State.isServerConnected):onChange(m.autoRefresh)
	Fusion.Observer(State.activeSessionRig):onChange(m.autoRefresh)
	Fusion.Observer(State.activeRigExists):onChange(m.autoRefresh)
	Fusion.Observer(State.rigModelName):onChange(m.autoRefresh)
	Fusion.Observer(State.selectedArmature):onChange(m.autoRefresh)
	Fusion.Observer(State.savedAnimations):onChange(m.autoRefresh)
	refreshRequests.Event:Connect(m.autoRefresh)
	m.autoRefresh()

	m.enabledIdle = Computed(function()
		return State.activeRigExists:get() and not m.busy:get()
	end)

	model = m
	return m
end

-- Header refresh icon: actions and armatures in one go.
function BulkActions.refreshAll(services: any)
	task.spawn(function()
		if State.isServerConnected:get() then
			services.blenderSyncManager:updateAvailableArmatures()
		end
		getModel(services).refresh()
	end)
end

local StudioService = game:GetService("StudioService")

local function classIcon(className: string): any
	local ok, data = pcall(function()
		return StudioService:GetClassIcon(className)
	end)
	return if ok then data else nil
end

local function tickImage(checked: boolean): string
	local theme = if settings().Studio.Theme.Name == "Light" then "Light" else "Dark"
	local file = if checked then "checkBox_checked" else "checkBox_unchecked"
	return "rbxasset://studio_svg_textures/Lua/Explorer/" .. theme .. "/Standard/" .. file .. "@2x.png"
end

local function tickBox(checked: any, order: number)
	return New("ImageLabel")({
		Name = "Tick",
		LayoutOrder = order,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(16, 16),
		Image = Computed(function()
			return tickImage(checked:get())
		end),
	})
end

-- One clickable line: tick, optional class icon, name, dimmed tags on the right.
local function listLine(props: {
	Order: number,
	Checked: any,
	Text: any,
	Tags: any?,
	Icon: string?,
	Bold: boolean?,
	Visible: any?,
	OnToggle: () -> (),
})
	local hovering = Value(false)
	local icon = if props.Icon then classIcon(props.Icon) else nil
	return New("TextButton")({
		Name = "Line",
		LayoutOrder = props.Order,
		Visible = props.Visible,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = Computed(function()
			return if hovering:get() then 0 else 1
		end),
		BackgroundColor3 = Kit.color(Enum.StudioStyleGuideColor.Button),
		[OnEvent("MouseEnter")] = function()
			hovering:set(true)
		end,
		[OnEvent("MouseLeave")] = function()
			hovering:set(false)
		end,
		[OnEvent("Activated")] = props.OnToggle,
		[Children] = {
			Kit.corner(4),
			Kit.padding(0, 6),
			New("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 6),
			}),
			tickBox(props.Checked, 1),
			if icon
				then New("ImageLabel")({
					LayoutOrder = 2,
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(16, 16),
					Image = icon.Image,
					ImageRectOffset = icon.ImageRectOffset,
					ImageRectSize = icon.ImageRectSize,
				})
				else nil,
			New("TextLabel")({
				LayoutOrder = 3,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, if icon then -110 else -88, 1, 0),
				Text = props.Text,
				Font = if props.Bold then Enum.Font.BuilderSansBold else Enum.Font.BuilderSansMedium,
				TextSize = Kit.TEXT,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Kit.color(Enum.StudioStyleGuideColor.MainText),
			}),
			New("TextLabel")({
				LayoutOrder = 4,
				BackgroundTransparency = 1,
				Size = UDim2.new(0, 60, 1, 0),
				Text = props.Tags or "",
				Font = Enum.Font.BuilderSans,
				TextSize = Kit.SMALL_TEXT,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Kit.color(Enum.StudioStyleGuideColor.DimmedText),
			}),
		},
	})
end

-- The pick list: a darker panel with an "All" tick on top (all or nothing)
-- and one line per row that passes `filter`.
local function pickList(m: any, order: number, filter: (any) -> boolean, tagsFor: (any) -> string, icon: string?, empty: string)
	local allChecked = Computed(function()
		local any = false
		for _, r in ipairs(m.rows:get()) do
			if filter(r) then
				any = true
				if not r.sel:get() then
					return false
				end
			end
		end
		return any
	end)
	local count = Computed(function()
		local n = 0
		for _, r in ipairs(m.rows:get()) do
			if filter(r) then
				n += 1
			end
		end
		return n
	end)
	return New("Frame")({
		Name = "PickList",
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Kit.color(Enum.StudioStyleGuideColor.MainBackground),
		[Children] = {
			Kit.corner(6),
			Kit.stroke(Enum.StudioStyleGuideColor.Border),
			Kit.padding(4, 4, 4, 4),
			Kit.vlist(1),
			listLine({
				Order = 0,
				Checked = allChecked,
				Text = "All",
				Bold = true,
				Visible = Computed(function()
					return count:get() > 0
				end),
				OnToggle = function()
					local target = not allChecked:get()
					for _, r in ipairs(m.rows:get()) do
						if filter(r) then
							r.sel:set(target)
						end
					end
				end,
			}),
			Kit.Hint({
				Text = empty,
				LayoutOrder = 1,
				Visible = Computed(function()
					return count:get() == 0
				end),
			}),
			ForValues(m.rows, function(r: any)
				local label = r.target
				if r.target ~= r.name then
					label ..= " ← " .. r.name
				end
				return listLine({
					Order = 2,
					Checked = r.sel,
					Text = label,
					Tags = tagsFor(r),
					Icon = icon,
					Visible = filter(r),
					OnToggle = function()
						r.sel:set(not r.sel:get())
					end,
				})
			end, Fusion.cleanup),
		},
	})
end

-- Import/Export tab: Blender actions -> AnimSaves
function BulkActions.importBody(services: any, layoutOrder: number, visible: any?)
	local m = getModel(services)
	local bulk = m.bulk
	return New("Frame")({
		Name = "ActionImport",
		LayoutOrder = layoutOrder,
		Visible = visible,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		[Children] = {
			Kit.vlist(8),
			Kit.FieldLabel({ Text = "Actions in Blender", LayoutOrder = 0 }),
			pickList(m, 2, function(r)
				return r.blender == true
			end, function(r)
				return if r.saved then "saved" else ""
			end, nil, "No actions on this armature in Blender."),
			Kit.PrimaryButton({
				Text = "Import selected actions",
				LayoutOrder = 3,
				Enabled = m.enabledIdle,
				Activated = function()
					m.run("Importing", function(progress)
						return bulk:importActions(m.selected(function(r)
							return r.blender
						end), false, progress)
					end)
				end,
			}),
			Kit.Hint({ Text = m.status, LayoutOrder = 4 }),
			VerticalCollapsibleSection({
				Text = "Import options",
				Collapsed = true,
				LayoutOrder = 5,
				[Children] = {
					Kit.FieldLabel({ Text = "Default priority (an action can override it in Blender)", LayoutOrder = 1 }),
					Dropdown({
						Size = UDim2.new(1, 0, 0, 24),
						LayoutOrder = 2,
						Options = PRIORITIES,
						Value = m.priority,
						OnSelected = function(v: any): nil
							m.priority:set(v)
							bulk:setSetting("priority", v)
							return nil
						end,
					}),
					Checkbox({
						Value = m.loop,
						Text = "Loop by default",
						LayoutOrder = 3,
						OnChange = function(v: boolean): nil
							m.loop:set(v)
							bulk:setSetting("loop", v)
							return nil
						end,
					}),
					Checkbox({
						Value = m.overwrite,
						Text = "Replace saves with the same name (backed up)",
						LayoutOrder = 4,
						OnChange = function(v: boolean): nil
							m.overwrite:set(v)
							bulk:setSetting("overwrite", v)
							return nil
						end,
					}),
				},
			}),
		},
	})
end

-- Play/Upload tab: actions and saves -> Roblox
function BulkActions.uploadBody(services: any, layoutOrder: number)
	local m = getModel(services)
	local bulk = m.bulk
	return New("Frame")({
		Name = "ActionUpload",
		LayoutOrder = layoutOrder,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		[Children] = {
			Kit.vlist(8),
			Kit.FieldLabel({ Text = "Local saves (AnimSaves)", LayoutOrder = 0 }),
			pickList(m, 2, function(r)
				return r.saved == true
			end, function(r)
				if r.uploaded then
					return if r.changed then "changed" else "uploaded"
				end
				return ""
			end, "KeyframeSequence", "Nothing saved in this rig yet. Import actions or use Save to rig."),
			Kit.PrimaryButton({
				Text = "Upload selected",
				LayoutOrder = 3,
				Enabled = m.enabledIdle,
				Activated = function()
					m.run("Uploading", function(progress)
						return bulk:uploadSaved(m.selected(function(r)
							return r.saved
						end), progress)
					end)
				end,
			}),
			Kit.Hint({ Text = m.status, LayoutOrder = 4 }),
			VerticalCollapsibleSection({
				Text = "Upload options",
				Collapsed = true,
				LayoutOrder = 5,
				[Children] = {
					Kit.FieldLabel({ Text = "Upload folder (Animation objects + AnimationIds)", LayoutOrder = 1 }),
					TextInput({
						Text = m.outputFolder,
						PlaceholderText = "ReplicatedStorage/Animations",
						LayoutOrder = 2,
						[OnChange("Text")] = function(text: string)
							m.outputFolder:set(text)
							bulk:setSetting("outputFolder", text)
						end,
					}),
					Kit.FieldLabel({ Text = "Upload as", LayoutOrder = 3 }),
					Kit.Row({
						LayoutOrder = 4,
						Height = 24,
						[Children] = {
							New("Frame")({
								LayoutOrder = 1,
								Size = UDim2.new(0, 0, 1, 0),
								BackgroundTransparency = 1,
								[Children] = {
									Dropdown({
										Options = { "User", "Group" },
										Value = m.creatorType,
										OnSelected = function(v: any): nil
											m.creatorType:set(v)
											bulk:setSetting("creatorType", v)
											return nil
										end,
									}),
								},
							}),
							TextInput({
								Text = m.groupId,
								PlaceholderText = "Group ID",
								LayoutOrder = 2,
								Size = UDim2.new(0, 0, 1, 0),
								Enabled = Computed(function()
									return m.creatorType:get() == "Group"
								end),
								[OnChange("Text")] = function(text: string)
									m.groupId:set(text)
									bulk:setSetting("groupId", tonumber(text) or 0)
								end,
							}),
						},
					}),
					Checkbox({
						Value = m.keepIds,
						Text = "Keep the same asset ID when re-uploading",
						LayoutOrder = 5,
						OnChange = function(v: boolean): nil
							m.keepIds:set(v)
							bulk:setSetting("keepIds", v)
							return nil
						end,
					}),
					Checkbox({
						Value = m.writeIdModule,
						Text = "Write an AnimationIds ModuleScript",
						LayoutOrder = 6,
						OnChange = function(v: boolean): nil
							m.writeIdModule:set(v)
							bulk:setSetting("writeIdModule", v)
							return nil
						end,
					}),
				},
			}),
		},
	})
end

-- Old name kept for anything that still calls it.
BulkActions.createBody = BulkActions.importBody

return BulkActions
