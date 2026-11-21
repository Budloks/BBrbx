--!native
--!strict
--!optimize 2

local Fusion = require(script.Parent.Parent.Parent.Packages.Fusion)

local New = Fusion.New
local Children = Fusion.Children
local Computed = Fusion.Computed

local StudioComponents = script.Parent.Parent.Parent.Components:FindFirstChild("StudioComponents")
local StudioComponentsUtil = StudioComponents:FindFirstChild("Util")
local themeProvider = require(StudioComponentsUtil.themeProvider)
local VerticalCollapsibleSection = require(StudioComponents.VerticalCollapsibleSection)
local CameraControls = require(script.Parent.Parent.Components.CameraControls)
local KeyframeNaming = require(script.Parent.Parent.Components.KeyframeNaming)
local BoneToggles = require(script.Parent.Parent.Components.BoneToggles)
local AnimationModifierStack = require(script.Parent.Parent.Components.AnimationModifierStack)

local ToolsTab = {}

local function createToolDivider(layoutOrder: number)
	return New("Frame")({
		LayoutOrder = layoutOrder,
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = themeProvider:GetColor(Enum.StudioStyleGuideColor.Border),
		BorderSizePixel = 0,
	})
end

local function createAnimationModifiers(services: any, layoutOrder: number)
	return VerticalCollapsibleSection({
		Text = "Animation modifiers",
		Subtitle = "non-destructive",
		Collapsed = false,
		LayoutOrder = layoutOrder,
		[Children] = {
			New("Frame")({
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				[Children] = AnimationModifierStack.create(services),
			}),
		},
	})
end

function ToolsTab.create(services: any)
	-- BBrbx: named cards; the main script decides which tab each one lives in.
	return {
		camera = CameraControls.createCameraControlsUI(services),
		markers = KeyframeNaming.createKeyframeNamingUI(services, 4),
		modifiers = createAnimationModifiers(services, 6),
		boneToggles = BoneToggles.create(services, 8) :: any,
	}
end

return ToolsTab
