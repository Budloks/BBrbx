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
		Collapsed = true,
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
	local components = {}

	local cameraControls = CameraControls.createCameraControlsUI(services)
	if cameraControls then
		table.insert(components, cameraControls)
	end

	local keyframeNaming = KeyframeNaming.createKeyframeNamingUI(services, 4)
	if keyframeNaming then
		table.insert(components, keyframeNaming)
	end

	table.insert(components, createAnimationModifiers(services, 6))


	-- Add the Bone Toggles section
	table.insert(components, BoneToggles.create(services, 8) :: any)

	return components
end

return ToolsTab
