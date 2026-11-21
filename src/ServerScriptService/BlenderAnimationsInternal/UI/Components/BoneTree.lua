--!strict

-- BBrbx: folding for the bone lists (Bone toggles, Export bone toggles).
-- The lists are depth-first with a `depth` per row; a row is hidden when any
-- ancestor is folded. Branches start folded; folded names survive list
-- rebuilds (rig refresh).

local Fusion = require(script.Parent.Parent.Parent.Packages.Fusion)
local Kit = require(script.Parent.Parent.Kit)

local New = Fusion.New
local Value = Fusion.Value
local Computed = Fusion.Computed
local OnEvent = Fusion.OnEvent
local Children = Fusion.Children

local CHEVRON = "rbxassetid://5607705156"
local CHEVRON_SIZE = 14

local BoneTree = {}

export type Tree = {
	prepare: (rows: { any }) -> (),
	isHidden: (i: number) -> boolean,
	rowVisible: (i: number) -> any,
	chevron: (i: number, order: number) -> GuiObject,
	overChevron: (i: number, input: InputObject) -> boolean,
	toolbar: (order: number) -> Frame,
}

function BoneTree.new(getRows: () -> { any }): Tree
	local collapsed: { [string]: boolean } = {}
	-- Names seen before: new branches start folded, ones you opened stay open.
	local seen: { [string]: boolean } = {}
	local version = Value(0)
	local rows: { any } = {}
	local ancestors: { { number } } = {}
	local chevrons: { [number]: GuiObject } = {}

	local function bump()
		version:set(version:get() + 1)
	end

	local function hasChildren(i: number): boolean
		local nextRow = rows[i + 1]
		return nextRow ~= nil and nextRow.depth > rows[i].depth
	end

	local self = {}

	function self.prepare(list: { any })
		rows = list
		table.clear(ancestors)
		table.clear(chevrons)
		local stack: { number } = {}
		for i, row in ipairs(list) do
			while #stack > 0 and list[stack[#stack]].depth >= row.depth do
				table.remove(stack)
			end
			ancestors[i] = table.clone(stack)
			table.insert(stack, i)
		end
		for i, row in ipairs(list) do
			if not seen[row.name] then
				seen[row.name] = true
				local nextRow = list[i + 1]
				if nextRow and nextRow.depth > row.depth then
					collapsed[row.name] = true
				end
			end
		end
	end

	function self.isHidden(i: number): boolean
		for _, a in ipairs(ancestors[i] or {}) do
			if collapsed[rows[a].name] then
				return true
			end
		end
		return false
	end

	function self.rowVisible(i: number)
		return Computed(function()
			version:get()
			return not self.isHidden(i)
		end)
	end

	function self.chevron(i: number, order: number): GuiObject
		if not hasChildren(i) then
			return New("Frame")({
				Size = UDim2.fromOffset(CHEVRON_SIZE, 1),
				BackgroundTransparency = 1,
				LayoutOrder = order,
			})
		end
		local name = rows[i].name
		local button = New("ImageButton")({
			Name = "Fold",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(CHEVRON_SIZE, CHEVRON_SIZE),
			LayoutOrder = order,
			Image = CHEVRON,
			ImageRectSize = Vector2.new(10, 10),
			ImageRectOffset = Computed(function()
				version:get()
				return if collapsed[name] then Vector2.new(0, 0) else Vector2.new(10, 0)
			end),
			ImageColor3 = Kit.color(Enum.StudioStyleGuideColor.DimmedText),
			[OnEvent("Activated")] = function()
				collapsed[name] = if collapsed[name] then nil else true
				bump()
			end,
		})
		chevrons[i] = button
		return button
	end

	-- Rows start a drag on mouse down; clicks on the fold arrow must not.
	function self.overChevron(i: number, input: InputObject): boolean
		local button = chevrons[i]
		if not button then
			return false
		end
		local left = button.AbsolutePosition.X - 3
		return input.Position.X >= left and input.Position.X <= left + button.AbsoluteSize.X + 6
	end

	function self.toolbar(order: number): Frame
		local function setAll(fold: boolean)
			table.clear(collapsed)
			if fold then
				local list = getRows()
				for i, row in ipairs(list) do
					local nextRow = list[i + 1]
					if nextRow and nextRow.depth > row.depth then
						collapsed[row.name] = true
					end
				end
			end
			bump()
		end
		return Kit.Row({
			LayoutOrder = order,
			Height = 24,
			[Children] = {
				Kit.Button({
					Text = "Expand all",
					LayoutOrder = 1,
					Size = UDim2.new(0, 0, 1, 0),
					Activated = function()
						setAll(false)
					end,
				}),
				Kit.Button({
					Text = "Collapse all",
					LayoutOrder = 2,
					Size = UDim2.new(0, 0, 1, 0),
					Activated = function()
						setAll(true)
					end,
				}),
			},
		})
	end

	return self :: any
end

return BoneTree
