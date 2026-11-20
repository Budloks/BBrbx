--!native
--!strict
--!optimize 2

-- Camera attach for previewing animations through a rig part or bone.
--
-- BB fork: the attachment is tracked by NAME plus the rig it belongs to, never by
-- a captured Instance alone. When the active rig changes, the camera re-attaches
-- to the same-named part/bone of the new rig (or detaches if the new rig has no
-- such part), so it can never keep following a rig you switched away from.

local State = require(script.Parent.Parent.state)
local RunService = game:GetService("RunService")
local Fusion = require(script.Parent.Parent.Packages.Fusion)

local Value = Fusion.Value

local CameraManager = {}
CameraManager.__index = CameraManager

-- Names that make a good default camera target, best first.
local PREFERRED_NAMES = { "camerabone", "camera", "head" }

function CameraManager.new()
	local self = setmetatable({}, CameraManager)

	-- Reactive list of attachable part/bone names of the active rig
	self.rigPartsList = Value({})

	self.attachedName = nil :: string?
	self.attachedRigModel = nil :: Instance?
	self.attachedTarget = nil :: Instance?
	self._targetConnections = {} :: { RBXScriptConnection }
	self._savedCamera = nil :: { cameraType: Enum.CameraType, fov: number }?

	return self
end

local function isCameraTarget(inst: Instance?): boolean
	return inst ~= nil and (inst:IsA("BasePart") or inst:IsA("Bone"))
end

local function targetWorldCFrame(target: Instance): CFrame
	if target:IsA("Bone") then
		return (target :: Bone).TransformedWorldCFrame
	end
	return (target :: BasePart).CFrame
end

-- Resolve a part/bone name inside a rig model. Prefers the instance the rig
-- object knows about (handles nested parts and Bones), then a recursive search.
function CameraManager:resolve(rigModel: Instance?, name: string?): Instance?
	if not rigModel or not name or name == "" then
		return nil
	end
	local rig = State.activeRig
	if rig and rig.model == rigModel and rig.bones then
		local rigPart = rig.bones[name]
		if rigPart and isCameraTarget(rigPart.part) then
			return rigPart.part
		end
	end
	if rigModel.Name == name and isCameraTarget(rigModel) then
		return rigModel
	end
	for _, desc in ipairs(rigModel:GetDescendants()) do
		if desc.Name == name and isCameraTarget(desc) then
			return desc
		end
	end
	return nil
end

function CameraManager:_disconnectTarget()
	for _, conn in ipairs(self._targetConnections) do
		conn:Disconnect()
	end
	table.clear(self._targetConnections)
	if State.cameraConnection then
		State.cameraConnection:Disconnect()
		State.cameraConnection = nil
	end
end

-- Attach to a specific instance. Kept for backwards compatibility with callers
-- that pass a part directly.
function CameraManager:attachCameraToPart(part: Instance?)
	if not isCameraTarget(part) then
		return
	end
	local target = part :: Instance
	local rigModel = State.activeSessionRig:get() or State.activeRigModel
	if rigModel and not target:IsDescendantOf(rigModel) then
		-- Never attach to something outside the active rig.
		return
	end

	self:_disconnectTarget()

	local camera = workspace.CurrentCamera
	if not State.isCameraAttached:get() or not self._savedCamera then
		self._savedCamera = { cameraType = camera.CameraType, fov = camera.FieldOfView }
	end

	self.attachedName = target.Name
	self.attachedRigModel = rigModel
	self.attachedTarget = target
	State.selectedPartName:set(target.Name)
	State.selectedPart:set(target)
	State.isCameraAttached:set(true)

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CameraSubject = if target:IsA("BasePart") then target else nil
	camera.FieldOfView = State.fovValue:get()
	camera.CFrame = targetWorldCFrame(target)

	-- Detach as soon as the target leaves the rig or is destroyed.
	table.insert(self._targetConnections, target.AncestryChanged:Connect(function()
		if not self.attachedRigModel or not target:IsDescendantOf(self.attachedRigModel) then
			self:detachCamera()
		end
	end))
	table.insert(self._targetConnections, target.Destroying:Connect(function()
		self:detachCamera()
	end))

	State.cameraConnection = RunService.RenderStepped:Connect(function()
		if not State.isCameraAttached:get() then
			return
		end
		local active = State.activeSessionRig:get() or State.activeRigModel
		if self.attachedTarget ~= target or (active and active ~= self.attachedRigModel) or not target.Parent then
			-- Stale binding (rig switched without notification): fix it instead of
			-- following the old rig.
			self:onActiveRigChanged(active)
			return
		end
		camera.CFrame = targetWorldCFrame(target)
	end)
end

-- Attach to a part/bone of the active rig by name (what the UI uses).
function CameraManager:attachCameraByName(name: string?)
	local rigModel = State.activeSessionRig:get() or State.activeRigModel
	local target = self:resolve(rigModel, name or State.selectedPartName:get())
	if target then
		self:attachCameraToPart(target)
	else
		warn("[RBXMonkey] Camera: no part or bone named '" .. tostring(name) .. "' in the active rig")
	end
end

function CameraManager:detachCamera()
	self:_disconnectTarget()

	local camera = workspace.CurrentCamera
	if State.isCameraAttached:get() then
		State.isCameraAttached:set(false)
		local saved = self._savedCamera
		camera.CameraSubject = nil
		if saved then
			-- Restore what the user had before attaching (BB fork: was hard-coded Fixed/70).
			camera.CameraType = if saved.cameraType == Enum.CameraType.Scriptable
				then Enum.CameraType.Fixed
				else saved.cameraType
			camera.FieldOfView = saved.fov
		else
			camera.CameraType = Enum.CameraType.Fixed
		end
	end
	self._savedCamera = nil
	self.attachedTarget = nil
	self.attachedRigModel = nil
end

-- Called whenever the active rig changes (selection, tab switch, tab close).
function CameraManager:onActiveRigChanged(newRigModel: Instance?)
	self:updatePartsList(newRigModel)
	if not State.isCameraAttached:get() then
		return
	end
	if newRigModel == self.attachedRigModel and self.attachedTarget and self.attachedTarget.Parent then
		return
	end
	local name = self.attachedName
	local target = self:resolve(newRigModel, name)
	if newRigModel and target then
		self:attachCameraToPart(target)
	else
		self:detachCamera()
	end
end

-- Rebuild the dropdown list for the given (or active) rig and keep the selected
-- name valid for that rig.
function CameraManager:updatePartsList(rigModel: Instance?)
	rigModel = rigModel or State.activeSessionRig:get() or State.activeRigModel
	if not rigModel then
		self.rigPartsList:set({})
		return
	end

	local seen = {}
	local newParts = {}
	local rig = State.activeRig
	if rig and rig.model == rigModel and rig.bones then
		for _, rigPart in pairs(rig.bones) do
			local part = rigPart.part
			if isCameraTarget(part) and not seen[part.Name] then
				seen[part.Name] = true
				table.insert(newParts, part.Name)
			end
		end
	else
		for _, desc in ipairs(rigModel:GetDescendants()) do
			if isCameraTarget(desc) and not seen[desc.Name] then
				seen[desc.Name] = true
				table.insert(newParts, desc.Name)
			end
		end
	end

	local function rank(name: string): number
		local lower = name:lower()
		for i, preferred in ipairs(PREFERRED_NAMES) do
			if lower == preferred then
				return i
			end
		end
		for i, preferred in ipairs(PREFERRED_NAMES) do
			if string.find(lower, preferred, 1, true) then
				return #PREFERRED_NAMES + i
			end
		end
		return 100
	end

	table.sort(newParts, function(a, b)
		local ra, rb = rank(a), rank(b)
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)

	self.rigPartsList:set(newParts)

	-- Keep the selected name valid for this rig; default to the best camera target
	-- (CameraBone > Camera > Head) so "Attach" works without picking anything.
	local current = State.selectedPartName:get()
	if not current or not seen[current] then
		State.selectedPartName:set(newParts[1])
	end
	State.selectedPart:set(self:resolve(rigModel, State.selectedPartName:get()))
end

function CameraManager:getPartsList()
	return self.rigPartsList
end

function CameraManager:cleanup()
	self:detachCamera()
end

return CameraManager
