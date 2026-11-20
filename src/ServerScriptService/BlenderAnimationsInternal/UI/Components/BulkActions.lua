--!strict

-- BB fork: "Bulk Actions" section — import every Blender action of the active
-- rig into AnimSaves (named after the action) and upload them in one go.

local State = require(script.Parent.Parent.Parent.state)
local Fusion = require(script.Parent.Parent.Parent.Packages.Fusion)

local New = Fusion.New
local Children = Fusion.Children
local Value = Fusion.Value
local Computed = Fusion.Computed
local ForValues = Fusion.ForValues
local OnChange = Fusion.OnChange

local StudioComponents = script.Parent.Parent.Parent.Components:FindFirstChild("StudioComponents")
local Button = require(StudioComponents.Button)
local Checkbox = require(StudioComponents.Checkbox)
local Dropdown = require(StudioComponents.Dropdown)
local Label = require(StudioComponents.Label)
local TextInput = require(StudioComponents.TextInput)
local VerticalCollapsibleSection = require(StudioComponents.VerticalCollapsibleSection)
local themeProvider = require(StudioComponents.Util.themeProvider)

local PRIORITIES = { "Core", "Idle", "Movement", "Action", "Action2", "Action3", "Action4" }

local BulkActions = {}

local function row(children: { any }, order: number, height: number?)
	return New("Frame")({
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height or 26),
		LayoutOrder = order,
		[Children] = {
			New("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 4),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			children,
		},
	})
end

function BulkActions.create(services: any, layoutOrder: number)
	local bulk = services.bulkService
	local rows = Value({} :: { any })
	local status = Value("Refresh to list the Blender actions of the active rig.")
	local busy = Value(false)

	local priority = Value(bulk:getSetting("priority"))
	local loop = Value(bulk:getSetting("loop"))
	local overwrite = Value(bulk:getSetting("overwrite"))
	local outputFolder = Value(bulk:getSetting("outputFolder"))
	local keepIds = Value(bulk:getSetting("keepIds"))
	local creatorType = Value(bulk:getSetting("creatorType"))
	local groupId = Value(tostring(bulk:getSetting("groupId") or ""))
	local writeIdModule = Value(bulk:getSetting("writeIdModule"))

	local function selectedRows(): { any }
		local list = {}
		for _, r in ipairs(rows:get()) do
			if r.sel:get() then
				table.insert(list, r)
			end
		end
		return list
	end

	local function refresh()
		local ok, data = bulk:listActions()
		if not ok then
			status:set(tostring(data))
			rows:set({})
			return
		end
		local previous = {}
		for _, r in ipairs(rows:get()) do
			previous[r.target] = r.sel:get()
		end
		local list = {}
		for _, r in ipairs(data.rows) do
			local default = r.blender
			if previous[r.target] ~= nil then
				default = previous[r.target]
			end
			r.sel = Value(default)
			table.insert(list, r)
		end
		rows:set(list)
		local nBlender = 0
		for _, r in ipairs(list) do
			if r.blender then
				nBlender += 1
			end
		end
		status:set(
			if data.blenderError
				then "Blender: " .. tostring(data.blenderError) .. " (showing saves only)"
				else string.format("%d action(s) in %s, %d row(s) total", nBlender, tostring(data.armature), #list)
		)
	end

	local function run(label: string, fn: (progress: (number, number, string) -> ()) -> any)
		if busy:get() then
			return
		end
		busy:set(true)
		status:set(label .. "…")
		task.spawn(function()
			local ok, result = pcall(fn, function(done: number, total: number, text: string)
				status:set(string.format("%s (%d/%d)", text, done, total))
			end)
			busy:set(false)
			if not ok then
				status:set("Error: " .. tostring(result))
				warn("[RBXMonkey BB] " .. tostring(result))
			else
				status:set(result.message)
				refresh()
			end
		end)
	end

	local function setAll(predicate: (any) -> boolean)
		for _, r in ipairs(rows:get()) do
			r.sel:set(predicate(r))
		end
	end

	local enabledIdle = Computed(function()
		return State.activeRigExists:get() and not busy:get()
	end)

	return VerticalCollapsibleSection({
		Text = "📦 Bulk Actions (BB)",
		Collapsed = true,
		LayoutOrder = layoutOrder,
		[Children] = {
			row({
				Button({
					Text = "Refresh",
					Size = UDim2.new(0.25, -3, 1, 0),
					Enabled = enabledIdle,
					Activated = function(): nil
						task.spawn(refresh)
						return nil
					end,
				}),
				Button({
					Text = "All",
					Size = UDim2.new(0.25, -3, 1, 0),
					Activated = function(): nil
						setAll(function()
							return true
						end)
						return nil
					end,
				}),
				Button({
					Text = "None",
					Size = UDim2.new(0.25, -3, 1, 0),
					Activated = function(): nil
						setAll(function()
							return false
						end)
						return nil
					end,
				}),
				Button({
					Text = "Changed",
					Size = UDim2.new(0.25, -3, 1, 0),
					Activated = function(): nil
						-- not uploaded yet, or changed in Blender since the last upload
						setAll(function(r)
							return r.blender and (not r.uploaded or r.changed)
						end)
						return nil
					end,
				}),
			}, 1),
			New("Frame")({
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 2,
				[Children] = {
					New("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }),
					ForValues(rows, function(r: any)
						local tags = {}
						if r.blender then
							table.insert(tags, "Blender")
						end
						if r.saved then
							table.insert(tags, "Saved")
						end
						if r.uploaded then
							table.insert(tags, if r.changed then "Changed" else "Uploaded")
						end
						local label = r.target
						if r.target ~= r.name then
							label ..= " ← " .. r.name
						end
						return Checkbox({
							Value = r.sel,
							Text = label .. "  ·  " .. table.concat(tags, " · "),
							OnChange = function(v: boolean): nil
								r.sel:set(v)
								return nil
							end,
						})
					end, Fusion.cleanup),
				},
			}),
			Label({ Text = "Default priority (actions can override in Blender)", LayoutOrder = 3 }),
			New("Frame")({
				Size = UDim2.new(1, 0, 0, 25),
				BackgroundTransparency = 1,
				LayoutOrder = 4,
				[Children] = {
					Dropdown({
						Options = PRIORITIES,
						Value = priority,
						OnSelected = function(v: any): nil
							priority:set(v)
							bulk:setSetting("priority", v)
							return nil
						end,
					}),
				},
			}),
			Checkbox({
				Value = loop,
				Text = "Loop by default",
				LayoutOrder = 5,
				OnChange = function(v: boolean): nil
					loop:set(v)
					bulk:setSetting("loop", v)
					return nil
				end,
			}),
			Checkbox({
				Value = overwrite,
				Text = "Replace saves with the same name (old one is backed up)",
				LayoutOrder = 6,
				OnChange = function(v: boolean): nil
					overwrite:set(v)
					bulk:setSetting("overwrite", v)
					return nil
				end,
			}),
			Label({ Text = "Upload: Animation objects + AnimationIds module go to", LayoutOrder = 7 }),
			TextInput({
				Text = outputFolder,
				PlaceholderText = "ReplicatedStorage/Animations",
				LayoutOrder = 8,
				[OnChange("Text")] = function(text: string)
					outputFolder:set(text)
					bulk:setSetting("outputFolder", text)
				end,
			}),
			row({
				New("Frame")({
					Size = UDim2.new(0.5, -2, 1, 0),
					BackgroundTransparency = 1,
					[Children] = {
						Dropdown({
							Options = { "User", "Group" },
							Value = creatorType,
							OnSelected = function(v: any): nil
								creatorType:set(v)
								bulk:setSetting("creatorType", v)
								return nil
							end,
						}),
					},
				}),
				TextInput({
					Text = groupId,
					PlaceholderText = "Group ID",
					Size = UDim2.new(0.5, -2, 1, 0),
					Enabled = Computed(function()
						return creatorType:get() == "Group"
					end),
					[OnChange("Text")] = function(text: string)
						groupId:set(text)
						bulk:setSetting("groupId", tonumber(text) or 0)
					end,
				}),
			}, 9),
			Checkbox({
				Value = keepIds,
				Text = "Keep the same asset ID when re-uploading",
				LayoutOrder = 10,
				OnChange = function(v: boolean): nil
					keepIds:set(v)
					bulk:setSetting("keepIds", v)
					return nil
				end,
			}),
			Checkbox({
				Value = writeIdModule,
				Text = "Write an 'AnimationIds' ModuleScript",
				LayoutOrder = 11,
				OnChange = function(v: boolean): nil
					writeIdModule:set(v)
					bulk:setSetting("writeIdModule", v)
					return nil
				end,
			}),
			Button({
				Text = "Import Selected",
				Size = UDim2.new(1, 0, 0, 28),
				LayoutOrder = 12,
				Enabled = enabledIdle,
				Activated = function(): nil
					run("Importing", function(progress)
						local list = {}
						for _, r in ipairs(selectedRows()) do
							if r.blender then
								table.insert(list, r)
							end
						end
						return bulk:importActions(list, false, progress)
					end)
					return nil
				end,
			}),
			Button({
				Text = "Import + Upload",
				Size = UDim2.new(1, 0, 0, 28),
				LayoutOrder = 13,
				Enabled = enabledIdle,
				Activated = function(): nil
					run("Importing and uploading", function(progress)
						local list = {}
						for _, r in ipairs(selectedRows()) do
							if r.blender then
								table.insert(list, r)
							end
						end
						return bulk:importActions(list, true, progress)
					end)
					return nil
				end,
			}),
			Button({
				Text = "Upload Selected Saves",
				Size = UDim2.new(1, 0, 0, 28),
				LayoutOrder = 14,
				Enabled = enabledIdle,
				Activated = function(): nil
					run("Uploading", function(progress)
						return bulk:uploadSaved(selectedRows(), progress)
					end)
					return nil
				end,
			}),
			Label({
				Text = status,
				TextWrapped = true,
				LayoutOrder = 15,
				TextColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.DimmedText),
			}),
		},
	})
end

return BulkActions
