-- BBrbx checkbox: Studio's own Explorer checkbox art plus a BuilderSans label,
-- the same look as the pick lists. The whole row is clickable.
-- Props kept from the StudioComponents original: Value, OnChange, Enabled,
-- Text, TextColor3, Alignment; anything else (Size, LayoutOrder, Visible,
-- events) is applied to the row frame.

local Plugin = script:FindFirstAncestorWhichIsA("Plugin")
local Fusion = require(Plugin:FindFirstChild("Fusion", true))

local StudioComponents = script.Parent
local StudioComponentsUtil = StudioComponents:FindFirstChild("Util")

local themeProvider = require(StudioComponentsUtil.themeProvider)
local getState = require(StudioComponentsUtil.getState)
local unwrap = require(StudioComponentsUtil.unwrap)
local types = require(StudioComponentsUtil.types)

local New = Fusion.New
local Value = Fusion.Value
local OnEvent = Fusion.OnEvent
local Computed = Fusion.Computed
local Children = Fusion.Children
local Hydrate = Fusion.Hydrate

local BOX = 16
local COMPONENT_ONLY_PROPERTIES = {
	"OnChange",
	"Alignment",
	"Enabled",
	"Value",
	"Text",
	"TextColor3",
}

type CheckboxProperties = {
	OnChange: ((newValue: boolean) -> nil)?,
	Alignment: (Enum.HorizontalAlignment | types.StateObject<Enum.HorizontalAlignment>)?,
	Enabled: (boolean | types.StateObject<boolean>)?,
	Text: (string | types.StateObject<string>)?,
	Value: (boolean | types.Value<boolean>)?,
	TextColor3: (Color3 | types.StateObject<Color3>)?,
	[any]: any,
}

local function checkImage(checked: boolean): string
	local theme = if unwrap(themeProvider.IsDark) == false then "Light" else "Dark"
	local file = if checked then "checkBox_checked" else "checkBox_unchecked"
	return "rbxasset://studio_svg_textures/Lua/Explorer/" .. theme .. "/Standard/" .. file .. "@2x.png"
end

return function(props: CheckboxProperties): Frame
	local currentValue = getState(props.Value, true)
	local isEnabled = getState(props.Enabled, true)
	local isHovering = Value(false)
	local hasText = props.Text ~= nil and props.Text ~= ""

	local boxOnRight = Computed(function()
		return unwrap(props.Alignment) == Enum.HorizontalAlignment.Right
	end)

	local function toggle()
		if not unwrap(isEnabled) then
			return
		end
		local newValue = not unwrap(currentValue, false)
		currentValue:set(newValue)
		if props.OnChange then
			props.OnChange(newValue)
		end
	end

	local row = New("TextButton")({
		Name = "Checkbox",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = if hasText then UDim2.new(1, 0, 0, 20) else UDim2.fromOffset(BOX, BOX),
		[OnEvent("MouseEnter")] = function()
			isHovering:set(true)
		end,
		[OnEvent("MouseLeave")] = function()
			isHovering:set(false)
		end,
		[OnEvent("Activated")] = toggle,
		[Children] = {
			New("ImageLabel")({
				Name = "Box",
				BackgroundTransparency = 1,
				AnchorPoint = Computed(function()
					return Vector2.new(if boxOnRight:get() then 1 else 0, 0.5)
				end),
				Position = Computed(function()
					return UDim2.fromScale(if boxOnRight:get() then 1 else 0, 0.5)
				end),
				Size = UDim2.fromOffset(BOX, BOX),
				Image = Computed(function()
					return checkImage(unwrap(currentValue) ~= false)
				end),
				ImageTransparency = Computed(function()
					if not unwrap(isEnabled) then
						return 0.55
					end
					return if isHovering:get() then 0 else 0.08
				end),
			}),
			if hasText
				then New("TextLabel")({
					Name = "Label",
					BackgroundTransparency = 1,
					AnchorPoint = Computed(function()
						return Vector2.new(if boxOnRight:get() then 0 else 1, 0)
					end),
					Position = Computed(function()
						return UDim2.fromScale(if boxOnRight:get() then 0 else 1, 0)
					end),
					Size = UDim2.new(1, -(BOX + 8), 1, 0),
					Text = props.Text,
					Font = Enum.Font.BuilderSansMedium,
					TextSize = 14,
					TextTruncate = Enum.TextTruncate.AtEnd,
					TextXAlignment = Computed(function()
						return if boxOnRight:get() then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left
					end),
					TextColor3 = props.TextColor3 or Computed(function()
						local style = if not unwrap(isEnabled)
							then Enum.StudioStyleGuideColor.DimmedText
							elseif isHovering:get() then Enum.StudioStyleGuideColor.BrightText
							else Enum.StudioStyleGuideColor.MainText
						return themeProvider:GetColor(style):get()
					end),
				})
				else nil,
		},
	})

	local hydrateProps = table.clone(props)
	for _, propertyIndex in pairs(COMPONENT_ONLY_PROPERTIES) do
		hydrateProps[propertyIndex] = nil
	end

	return Hydrate(row)(hydrateProps)
end
