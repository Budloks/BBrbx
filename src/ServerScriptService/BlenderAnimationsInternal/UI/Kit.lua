--!strict

-- BBrbx UI kit: one spacing scale and a handful of building blocks so every
-- tab looks the same (cards, primary/secondary buttons, field labels, rows,
-- status pill, hint text).

local Fusion = require(script.Parent.Parent.Packages.Fusion)

local New = Fusion.New
local Children = Fusion.Children
local OnEvent = Fusion.OnEvent
local Value = Fusion.Value
local Computed = Fusion.Computed

local StudioComponents = script.Parent.Parent.Components:FindFirstChild("StudioComponents")
local themeProvider = require(StudioComponents.Util.themeProvider)
local unwrap = require(StudioComponents.Util.unwrap)

local Kit = {}

Kit.SPACE = {
	xs = 4,
	sm = 6,
	md = 8,
	lg = 10,
	xl = 12,
}
Kit.RADIUS = 6
Kit.CONTROL_HEIGHT = 28
Kit.PRIMARY_HEIGHT = 30
Kit.TEXT = 14
Kit.SMALL_TEXT = 12

local function color(style: any, modifier: any?)
	return themeProvider:GetColor(style, modifier)
end
Kit.color = color

function Kit.corner(radius: number?)
	return New("UICorner")({ CornerRadius = UDim.new(0, radius or Kit.RADIUS) })
end

function Kit.stroke(style: any?)
	return New("UIStroke")({
		Color = color(style or Enum.StudioStyleGuideColor.Border),
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function Kit.padding(t: number, r: number?, b: number?, l: number?)
	return New("UIPadding")({
		PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r or t),
		PaddingBottom = UDim.new(0, b or t),
		PaddingLeft = UDim.new(0, l or r or t),
	})
end

function Kit.vlist(gap: number?)
	return New("UIListLayout")({
		SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or Kit.SPACE.md),
	})
end

-- Horizontal row whose children share the width equally.
function Kit.Row(props: { LayoutOrder: number?, Height: number?, Gap: number?, Visible: any?, [any]: any })
	return New("Frame")({
		Name = "Row",
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, props.Height or Kit.CONTROL_HEIGHT),
		[Children] = {
			New("UIListLayout")({
				SortOrder = Enum.SortOrder.LayoutOrder,
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalFlex = Enum.UIFlexAlignment.Fill,
				VerticalFlex = Enum.UIFlexAlignment.Fill,
				Padding = UDim.new(0, props.Gap or Kit.SPACE.md),
			}),
			props[Children],
		},
	})
end

-- Small dimmed label that sits above a field.
function Kit.FieldLabel(props: { Text: any, LayoutOrder: number?, Visible: any? })
	return New("TextLabel")({
		Name = "FieldLabel",
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 14),
		Text = props.Text,
		Font = Enum.Font.BuilderSansMedium,
		TextSize = Kit.SMALL_TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = color(Enum.StudioStyleGuideColor.DimmedText),
	})
end

-- Wrapped secondary text (help, status lines).
function Kit.Hint(props: { Text: any, LayoutOrder: number?, Visible: any?, Color: any?, RichText: boolean? })
	return New("TextLabel")({
		Name = "Hint",
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = props.Text,
		RichText = props.RichText,
		TextWrapped = true,
		Font = Enum.Font.BuilderSans,
		TextSize = Kit.SMALL_TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = props.Color or color(Enum.StudioStyleGuideColor.DimmedText),
	})
end

local function makeButton(props: any, primary: boolean)
	local enabled = props.Enabled
	local hovering = Value(false)
	local isEnabled = Computed(function()
		if enabled == nil then
			return true
		end
		return unwrap(enabled) and true or false
	end)

	local bgModifier = Computed(function()
		return if not isEnabled:get()
			then Enum.StudioStyleGuideModifier.Disabled
			elseif hovering:get() then Enum.StudioStyleGuideModifier.Hover
			else Enum.StudioStyleGuideModifier.Default
	end)
	local fgModifier = Computed(function()
		return if isEnabled:get() then Enum.StudioStyleGuideModifier.Default else Enum.StudioStyleGuideModifier.Disabled
	end)
	local bg = color(
		if primary then Enum.StudioStyleGuideColor.DialogMainButton else Enum.StudioStyleGuideColor.Button,
		bgModifier
	)
	local fg = color(
		if primary then Enum.StudioStyleGuideColor.DialogMainButtonText else Enum.StudioStyleGuideColor.ButtonText,
		fgModifier
	)

	return New("TextButton")({
		Name = props.Name or (if primary then "PrimaryButton" else "Button"),
		LayoutOrder = props.LayoutOrder,
		Visible = props.Visible,
		AutoButtonColor = false,
		Size = props.Size or UDim2.new(1, 0, 0, if primary then Kit.PRIMARY_HEIGHT else Kit.CONTROL_HEIGHT),
		BackgroundColor3 = bg,
		Text = props.Text,
		TextColor3 = fg,
		Font = if primary then Enum.Font.BuilderSansBold else Enum.Font.BuilderSansMedium,
		TextSize = Kit.TEXT,
		TextTruncate = Enum.TextTruncate.AtEnd,
		[OnEvent("MouseEnter")] = function()
			hovering:set(true)
			if props.OnHover then
				props.OnHover(true)
			end
		end,
		[OnEvent("MouseLeave")] = function()
			hovering:set(false)
			if props.OnHover then
				props.OnHover(false)
			end
		end,
		[OnEvent("Activated")] = function()
			-- A click often hides or replaces the button (Connect -> connected
			-- view), and then MouseLeave never fires: drop the hint now.
			if props.OnHover then
				props.OnHover(false)
			end
			if isEnabled:get() and props.Activated then
				props.Activated()
			end
		end,
		[Children] = {
			Kit.corner(5),
			if primary then nil else Kit.stroke(Enum.StudioStyleGuideColor.ButtonBorder),
			Kit.padding(0, 8),
		},
	})
end

function Kit.PrimaryButton(props: any)
	return makeButton(props, true)
end

function Kit.Button(props: any)
	return makeButton(props, false)
end

-- Pill with a coloured dot: green when ok, red/grey otherwise.
function Kit.StatusPill(props: { Text: any, Ok: any, LayoutOrder: number?, Size: UDim2?, Position: UDim2?, AnchorPoint: Vector2? })
	local okColor = Color3.fromRGB(64, 182, 107)
	local badColor = Color3.fromRGB(214, 89, 74)
	return New("Frame")({
		Name = "StatusPill",
		LayoutOrder = props.LayoutOrder,
		Size = props.Size or UDim2.new(0, 0, 0, 20),
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color(Enum.StudioStyleGuideColor.Titlebar),
		[Children] = {
			New("UICorner")({ CornerRadius = UDim.new(1, 0) }),
			Kit.stroke(),
			Kit.padding(0, 8, 0, 8),
			New("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			New("Frame")({
				LayoutOrder = 1,
				Size = UDim2.fromOffset(7, 7),
				BackgroundColor3 = Computed(function()
					return if unwrap(props.Ok) then okColor else badColor
				end),
				[Children] = New("UICorner")({ CornerRadius = UDim.new(1, 0) }),
			}),
			New("TextLabel")({
				LayoutOrder = 2,
				BackgroundTransparency = 1,
				Size = UDim2.new(0, 0, 1, 0),
				AutomaticSize = Enum.AutomaticSize.X,
				Text = props.Text,
				Font = Enum.Font.BuilderSansMedium,
				TextSize = Kit.SMALL_TEXT,
				TextColor3 = color(Enum.StudioStyleGuideColor.MainText),
			}),
		},
	})
end

return Kit
