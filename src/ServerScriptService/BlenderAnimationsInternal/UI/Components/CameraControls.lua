--!native
--!strict
--!optimize 2

local State = require(script.Parent.Parent.Parent.state)
local Fusion = require(script.Parent.Parent.Parent.Packages.Fusion)

local New = Fusion.New
local Children = Fusion.Children
local Value = Fusion.Value
local Computed = Fusion.Computed

local StudioComponents = script.Parent.Parent.Parent.Components:FindFirstChild("StudioComponents")
local Button = require(StudioComponents.Button)
local Dropdown = require(StudioComponents.Dropdown)
local Label = require(StudioComponents.Label)
local Slider = require(StudioComponents.Slider)
local VerticalCollapsibleSection = require(StudioComponents.VerticalCollapsibleSection)
local Kit = require(script.Parent.Parent.Kit)


local CameraControls = {}

function CameraControls.createCameraControlsUI(services: any)
	return VerticalCollapsibleSection({
		Text = "Camera",
		Subtitle = "view through a bone",
		Collapsed = false,
		LayoutOrder = 2,
		[Children] = {
			Kit.FieldLabel({ Text = "Attach to", LayoutOrder = 1 }),
			New("Frame")({
				Size = UDim2.new(1, 0, 0, 25),
				LayoutOrder = 2,
				[Children] = {
					Dropdown({
						Options = services and services.cameraManager and services.cameraManager:getPartsList() or Value({}),
						Value = State.selectedPartName,
						OnSelected = function(newItem: any): nil
							State.selectedPartName:set(newItem)
							local cameraManager = services and services.cameraManager
							if cameraManager then
								local rigModel = State.activeSessionRig:get() or State.activeRigModel
								State.selectedPart:set(cameraManager:resolve(rigModel, newItem))
								-- Switching the target while attached moves the camera right away
								if State.isCameraAttached:get() then
									cameraManager:attachCameraByName(newItem)
								end
							end
							return nil
						end,
					}),
				},
			}) :: any,
			New("Frame")({
				LayoutOrder = 3,
				Size = UDim2.new(1, 0, 0, 30),
				[Children] = {
					Button({
						Text = Computed(function()
							return State.isCameraAttached:get() and "Detach camera" or "Attach camera"
						end),
						Activated = function(): nil
							if services and services.cameraManager then
								if State.isCameraAttached:get() then
									services.cameraManager:detachCamera()
								else
									-- Resolve against the CURRENT rig at click time (BB fork camera fix)
									services.cameraManager:attachCameraByName(State.selectedPartName:get())
								end
							end
							return nil
						end,
						Enabled = Computed(function()
							return State.activeRigExists:get()
						end),
					}),
				},
			}) :: any,
			Kit.FieldLabel({
				LayoutOrder = 4,
				Text = Computed(function()
					return "Field of view  ·  " .. tostring(State.fovValue:get())
				end),
			}),
			Slider({
				LayoutOrder = 5,
				Size = UDim2.new(1, 0, 0, 20),
				Min = 10,
				Max = 120,
				Step = 1,
				Value = Computed(function()
					return State.fovValue:get()
				end),
				OnChange = function(value)
					State.fovValue:set(value)
					local camera = game.Workspace.CurrentCamera
					if camera then
						camera.FieldOfView = value
					end
				end,
				Enabled = Computed(function()
					return State.isCameraAttached:get()
				end),
			}) :: any,
		},
	})
end

return CameraControls
