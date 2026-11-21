-- BBrbx card section.
-- Same props as the original StudioComponents section (Text, Collapsed,
-- Enabled, Padding, OnCollapsedChanged, LayoutOrder, Children) plus an optional
-- Subtitle shown on the right of the header. Renders as a rounded card with a
-- 30px header and a 10px padded body, so every tab gets the same rhythm.

local Plugin = script:FindFirstAncestorWhichIsA("Plugin")
local Fusion = require(Plugin:FindFirstChild("Fusion", true))

local StudioComponents = script.Parent
local StudioComponentsUtil = StudioComponents:FindFirstChild("Util")

local themeProvider = require(StudioComponentsUtil.themeProvider)
local getState = require(StudioComponentsUtil.getState)
local unwrap = require(StudioComponentsUtil.unwrap)
local types = require(StudioComponentsUtil.types)

local Children = Fusion.Children
local Computed = Fusion.Computed
local OnEvent = Fusion.OnEvent
local Value = Fusion.Value
local New = Fusion.New

local HEADER_HEIGHT = 30
local BODY_PAD = 10

type Props = {
	Enabled: (boolean | types.StateObject<boolean>)?,
	Collapsed: (boolean | types.Value<boolean>)?,
	Padding: (UDim | types.StateObject<UDim>)?,
	OnCollapsedChanged: ((boolean) -> ())?,
	[any]: any,
}

-- Section titles used to carry emoji; cards use plain titles.
local function cleanTitle(text: string): string
	local stripped = text:gsub("^[^%w%(]+", "")
	return stripped
end

return function(props: Props): Frame
	local shouldBeCollapsed = getState(props.Collapsed, false, "Value")
	local isEnabled = getState(props.Enabled, true)
	local isHovering = Value(false)

	local isCollapsed = Computed(function()
		return if unwrap(isEnabled) then unwrap(shouldBeCollapsed) else true
	end)

	local function notify()
		local callback = props.OnCollapsedChanged and unwrap(props.OnCollapsedChanged)
		if callback then
			callback(not unwrap(isCollapsed))
		end
	end
	if not unwrap(isCollapsed) then
		notify()
	end

	local title = Computed(function()
		return cleanTitle(tostring(unwrap(props.Text) or ""))
	end)

	return New("Frame")({
		Name = "Card",
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.Titlebar),
		[Children] = {
			New("UICorner")({ CornerRadius = UDim.new(0, 6) }),
			New("UIStroke")({
				Color = themeProvider:GetColor(Enum.StudioStyleGuideColor.Border),
				Thickness = 1,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
			New("UIListLayout")({
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 0),
			}),
			New("TextButton")({
				Name = "Header",
				LayoutOrder = 0,
				Text = "",
				AutoButtonColor = false,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
				[OnEvent("MouseEnter")] = function()
					isHovering:set(true)
				end,
				[OnEvent("MouseLeave")] = function()
					isHovering:set(false)
				end,
				[OnEvent("Activated")] = function()
					if not unwrap(isEnabled) then
						return
					end
					shouldBeCollapsed:set(not shouldBeCollapsed:get())
					notify()
				end,
				[Children] = {
					New("UIPadding")({
						PaddingLeft = UDim.new(0, BODY_PAD),
						PaddingRight = UDim.new(0, BODY_PAD),
					}),
					New("TextLabel")({
						Name = "Chevron",
						BackgroundTransparency = 1,
						Size = UDim2.new(0, 12, 1, 0),
						Text = Computed(function()
							return if unwrap(isCollapsed) then "▸" else "▾"
						end),
						Font = Enum.Font.BuilderSansBold,
						TextSize = 14,
						TextColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.DimmedText),
					}),
					New("TextLabel")({
						Name = "Title",
						BackgroundTransparency = 1,
						Position = UDim2.fromOffset(18, 0),
						Size = UDim2.new(1, -18, 1, 0),
						Text = title,
						Font = Enum.Font.BuilderSansBold,
						TextSize = 14,
						TextXAlignment = Enum.TextXAlignment.Left,
						TextTruncate = Enum.TextTruncate.AtEnd,
						TextColor3 = Computed(function()
							local style = if unwrap(isEnabled)
								then (if isHovering:get() then Enum.StudioStyleGuideColor.BrightText else Enum.StudioStyleGuideColor.MainText)
								else Enum.StudioStyleGuideColor.DimmedText
							return themeProvider:GetColor(style):get()
						end),
					}),
					New("TextLabel")({
						Name = "Subtitle",
						BackgroundTransparency = 1,
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.fromScale(1, 0),
						Size = UDim2.new(0.5, 0, 1, 0),
						Visible = props.Subtitle ~= nil,
						Text = props.Subtitle or "",
						Font = Enum.Font.BuilderSans,
						TextSize = 12,
						TextXAlignment = Enum.TextXAlignment.Right,
						TextTruncate = Enum.TextTruncate.AtEnd,
						TextColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.DimmedText),
					}),
				},
			}),
			New("Frame")({
				Name = "Body",
				LayoutOrder = 1,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Visible = Computed(function()
					return not unwrap(isCollapsed)
				end),
				[Children] = {
					New("UIPadding")({
						PaddingLeft = UDim.new(0, BODY_PAD),
						PaddingRight = UDim.new(0, BODY_PAD),
						PaddingBottom = UDim.new(0, BODY_PAD),
						PaddingTop = UDim.new(0, 2),
					}),
					New("UIListLayout")({
						SortOrder = Enum.SortOrder.LayoutOrder,
						Padding = Computed(function()
							return unwrap(props.Padding) or UDim.new(0, 8)
						end),
					}),
					Computed(function()
						return if unwrap(isCollapsed) then {} else props[Children]
					end),
				},
			}),
		},
	})
end
