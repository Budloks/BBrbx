--!strict

-- BBrbx animation cards (placed into tabs by the main script):
-- From Blender (actions) → Save → Saved animations → From file/clipboard.

local State = require(script.Parent.Parent.Parent.state)
local Fusion = require(script.Parent.Parent.Parent.Packages.Fusion)

local New = Fusion.New
local Children = Fusion.Children
local OnChange = Fusion.OnChange
local OnEvent = Fusion.OnEvent
local Value = Fusion.Value
local Computed = Fusion.Computed

local StudioComponents = script.Parent.Parent.Parent.Components:FindFirstChild("StudioComponents")
local Checkbox = require(StudioComponents.Checkbox)
local Dropdown = require(StudioComponents.Dropdown)
local TextInput = require(StudioComponents.TextInput)
local VerticalCollapsibleSection = require(StudioComponents.VerticalCollapsibleSection)

local Kit = require(script.Parent.Parent.Kit)
local AnimationImportControls = require(script.Parent.Parent.Components.AnimationImportControls)
local BulkActions = require(script.Parent.Parent.Components.BulkActions)

local PlayerTab = {}

local function savedRow(services: any, anim: any, order: number)
	local hovering = Value(false)
	local isSelected = Computed(function()
		local selected = State.selectedSavedAnim:get()
		return selected ~= nil and (selected :: any).instance == anim.instance
	end)
	return New("TextButton")({
		Name = "SavedAnimation",
		LayoutOrder = order,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.new(1, 0, 0, 28),
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
			State.selectedSavedAnim:set(anim)
			services.animationManager:playSavedAnimation(anim)
		end,
		[Children] = {
			Kit.corner(4),
			Kit.padding(0, 8),
			New("Frame")({
				Name = "Diamond",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(0, 5, 0.5, 0),
				Size = UDim2.fromOffset(8, 8),
				Rotation = 45,
				BorderSizePixel = 0,
				BackgroundColor3 = Kit.color(Enum.StudioStyleGuideColor.MainText),
				[Children] = Kit.corner(1),
			}),
			New("TextLabel")({
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(18, 0),
				Size = UDim2.new(1, -18, 1, 0),
				Text = anim.name,
				Font = Enum.Font.BuilderSansMedium,
				TextSize = Kit.TEXT,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Kit.color(Enum.StudioStyleGuideColor.MainText),
			}),
		},
	})
end

-- Saved animations as a strip under the header player (Play/Upload tab):
-- click one to play it. Scrolls after a handful of rows.
function PlayerTab.savedStrip(services: any, layoutOrder: number, visible: any?)
	local ROW, GAP, MAX_ROWS = 24, 1, 6
	local count = Computed(function()
		return #(State.savedAnimations:get() :: any)
	end)
	return New("Frame")({
		Name = "SavedStrip",
		LayoutOrder = layoutOrder,
		Visible = visible,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		[Children] = {
			Kit.vlist(4),
			Kit.FieldLabel({
				Text = Computed(function()
					return "Saved animations · " .. tostring(count:get())
				end),
				LayoutOrder = 1,
			}),
			Kit.Hint({
				Text = "Nothing saved in this rig yet. Use Save to rig below.",
				LayoutOrder = 2,
				Visible = Computed(function()
					return count:get() == 0
				end),
			}),
			New("ScrollingFrame")({
				Name = "List",
				LayoutOrder = 3,
				Visible = Computed(function()
					return count:get() > 0
				end),
				Size = Computed(function()
					local rows = math.min(count:get(), MAX_ROWS)
					return UDim2.new(1, 0, 0, rows * (ROW + GAP) + 8)
				end),
				CanvasSize = UDim2.new(0, 0, 0, 0),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				ScrollBarThickness = 4,
				ScrollingDirection = Enum.ScrollingDirection.Y,
				BorderSizePixel = 0,
				BackgroundColor3 = Kit.color(Enum.StudioStyleGuideColor.MainBackground),
				[Children] = {
					Kit.corner(6),
					Kit.stroke(Enum.StudioStyleGuideColor.Border),
					Kit.padding(4, 6, 4, 4),
					Kit.vlist(GAP),
					Computed(function()
						local rows = {}
						for i, anim in ipairs(State.savedAnimations:get() :: any) do
							table.insert(rows, savedRow(services, anim, i))
						end
						return rows
					end, Fusion.cleanup),
				},
			}),
		},
	})
end

function PlayerTab.create(services: any)
	local hint = Value("")
	local function hover(text: string)
		return function(on: boolean)
			hint:set(if on then text else "")
		end
	end

	-- Name follows the animation that is playing (a saved one), empty otherwise.
	local nameText = Value(State.animationName or "")
	Fusion.Observer(State.selectedSavedAnim):onChange(function()
		local saved = State.selectedSavedAnim:get()
		local name = if saved then tostring((saved :: any).name) else ""
		nameText:set(name)
		State.animationName = name
	end)

	local saveCard = VerticalCollapsibleSection({
		Text = "Save / Upload",
		Collapsed = false,
		LayoutOrder = 2,
		[Children] = {
			Kit.FieldLabel({ Text = "Name", LayoutOrder = 1 }),
			TextInput({
				PlaceholderText = "Animation name",
				Text = nameText,
				LayoutOrder = 2,
				[OnChange("Text")] = function(newText)
					nameText:set(newText)
					State.animationName = newText
				end,
			}),
			Kit.FieldLabel({ Text = "Priority", LayoutOrder = 3 }),
			Dropdown({
				Size = UDim2.new(1, 0, 0, 24),
				LayoutOrder = 4,
				Value = State.selectedPriority,
				Options = State.animationPriorityOptions :: any,
				OnSelected = function(newItem: any): nil
					State.selectedPriority:set(newItem)
					return nil
				end,
			}),
			Checkbox({
				Value = State.uniqueNames,
				Text = "Keep names unique",
				LayoutOrder = 5,
				OnChange = function(uniqueState: boolean): nil
					State.uniqueNames:set(uniqueState)
					return nil
				end,
			}),
			Kit.Row({
				LayoutOrder = 6,
				[Children] = {
					Kit.Button({
						Text = "Save to rig",
						LayoutOrder = 1,
						Size = UDim2.new(0, 0, 1, 0),
						Enabled = State.activeRigExists,
						Activated = function()
							services.animationManager:saveAnimationRig()
						end,
						OnHover = hover("Saves a KeyframeSequence into the rig's AnimSaves."),
					}),
					Kit.Button({
						Text = "Upload",
						LayoutOrder = 2,
						Size = UDim2.new(0, 0, 1, 0),
						Enabled = State.activeRigExists,
						Activated = function()
							services.animationManager:uploadAnimation()
						end,
						OnHover = hover("Uploads the animation to your Roblox account."),
					}),
				},
			}),
			Kit.Hint({
				Text = hint,
				LayoutOrder = 7,
				Visible = Computed(function()
					return hint:get() ~= ""
				end),
			}),
			New("Frame")({
				Name = "Divider",
				LayoutOrder = 8,
				Size = UDim2.new(1, 0, 0, 1),
				BorderSizePixel = 0,
				BackgroundColor3 = Kit.color(Enum.StudioStyleGuideColor.Border),
			}),
			BulkActions.uploadBody(services, 9),
		},
	})

	-- BBrbx: named cards; the main script decides which tab each one lives in.
	return {
		fromBlender = AnimationImportControls.createBlenderCard(services, 1),
		save = saveCard,
		fromFile = AnimationImportControls.createLegacyCard(services, 4),
		sendAnimation = AnimationImportControls.createSendCard(services, 5),
	}
end

return PlayerTab
