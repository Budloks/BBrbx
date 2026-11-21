--!strict

-- BB fork: scale one branch of a rig (a weapon under its Handle) in Studio,
-- matching "Scale with children" in Blender.
--
-- Everything joined to the branch root (Motor6Ds, Welds, WeldConstraints),
-- except the joint that hangs it on its parent, grows by `factor` about a
-- pivot: part sizes and positions, file meshes, joint offsets, attachments and
-- bones. The root joint keeps its C0, so the weapon stays where the hand holds
-- it. Model.Scale / ScaleTo is not used: the Animator would then scale the
-- animations a second time.
--
-- Saved animations of the rig scale the same way (translations of the branch
-- channels), after a copy goes to ServerStorage.BBrbx_AnimBackups.

local ServerStorage = game:GetService("ServerStorage")

local BranchScaler = {}

export type ScaleResult = {
	parts: number,
	animations: number,
	maxError: number,
}

local function scalePos(cf: CFrame, k: number): CFrame
	return CFrame.new(cf.Position * k) * cf.Rotation
end

local function jointWorld(joint: JointInstance, rootPart: BasePart): CFrame?
	local p0, p1 = joint.Part0, joint.Part1
	if p1 == rootPart and p0 then
		return p0.CFrame * joint.C0
	elseif p0 == rootPart and p1 then
		return p1.CFrame * joint.C1
	end
	return nil
end

-- Parts joined to root, not crossing the root joint, inside the rig.
local function collectBranch(rigModel: Instance, rootPart: BasePart, rootJoint: Instance?): { BasePart }
	local seen: { [BasePart]: boolean } = { [rootPart] = true }
	local list: { BasePart } = { rootPart }
	local i = 1
	while i <= #list do
		local part = list[i]
		i += 1
		for _, j in ipairs(part:GetJoints()) do
			if j == rootJoint then
				continue
			end
			local a: any, b: any = nil, nil
			if j:IsA("JointInstance") or j:IsA("WeldConstraint") then
				a, b = (j :: any).Part0, (j :: any).Part1
			end
			for _, other in ipairs({ a, b }) do
				if other and other ~= part and not seen[other] and other:IsDescendantOf(rigModel) then
					seen[other] = true
					table.insert(list, other)
				end
			end
		end
	end
	-- loose parts nested inside branch parts ride along
	for n = 1, #list do
		for _, d in ipairs(list[n]:GetDescendants()) do
			if d:IsA("BasePart") and not seen[d] then
				seen[d] = true
				table.insert(list, d)
			end
		end
	end
	return list
end

local function scaleChildren(part: BasePart, k: number, channels: { [string]: boolean })
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("BasePart") then
			continue -- handled as a part
		end
		if d:IsA("Attachment") then -- includes Bone
			(d :: Attachment).CFrame = scalePos((d :: Attachment).CFrame, k)
			if d:IsA("Bone") then
				channels[d.Name] = true
			end
		elseif d:IsA("SpecialMesh") then
			local mesh = d :: SpecialMesh
			if mesh.MeshType == Enum.MeshType.FileMesh then
				mesh.Scale *= k
			end
			mesh.Offset *= k
		elseif d:IsA("DataModelMesh") then
			(d :: any).Offset *= k
		elseif d:IsA("Texture") then
			local tex = d :: Texture
			tex.StudsPerTileU *= k
			tex.StudsPerTileV *= k
			tex.OffsetStudsU *= k
			tex.OffsetStudsV *= k
		elseif d:IsA("Beam") then
			local beam = d :: Beam
			beam.Width0 *= k
			beam.Width1 *= k
			beam.CurveSize0 *= k
			beam.CurveSize1 *= k
		end
	end
end

local function backupFolder(rigModel: Instance): Instance
	local root = ServerStorage:FindFirstChild("BBrbx_AnimBackups")
	if not root then
		root = Instance.new("Folder")
		root.Name = "BBrbx_AnimBackups"
		root.Parent = ServerStorage
	end
	local rigFolder = (root :: Instance):FindFirstChild(rigModel.Name)
	if not rigFolder then
		rigFolder = Instance.new("Folder")
		rigFolder.Name = rigModel.Name
		rigFolder.Parent = root
	end
	return rigFolder :: Instance
end

local function scaleAnimations(rigModel: Instance, channels: { [string]: boolean }, k: number): number
	local saves = rigModel:FindFirstChild("AnimSaves")
	if not saves then
		return 0
	end
	local stamp = os.date("%Y%m%d-%H%M%S")
	local count = 0
	for _, kfs in ipairs(saves:GetDescendants()) do
		if not kfs:IsA("KeyframeSequence") then
			continue
		end
		local poses = {}
		for _, pose in ipairs(kfs:GetDescendants()) do
			if pose:IsA("Pose") and channels[pose.Name] and (pose :: Pose).CFrame.Position.Magnitude > 1e-7 then
				table.insert(poses, pose)
			end
		end
		if #poses == 0 then
			continue
		end
		local copy = kfs:Clone()
		copy.Name = kfs.Name .. "@" .. stamp .. "-before-scale"
		copy:SetAttribute("BBBackupOf", kfs.Name)
		copy.Parent = backupFolder(rigModel)
		for _, pose in ipairs(poses) do
			(pose :: Pose).CFrame = scalePos((pose :: Pose).CFrame, k)
		end
		count += 1
	end
	return count
end

-- entry: { root = "Handle", factor = 1.5, pivot = {x, y, z}? } (pivot in the root joint's frame)
function BranchScaler.scale(rigModel: Instance, rig: any, entry: any): (boolean, string | ScaleResult)
	local k = tonumber(entry.factor)
	if not k or k <= 0 then
		return false, "bad scale factor"
	end
	local rigPart = rig and rig.bones and rig.bones[entry.root]
	local rootPart = rigPart and rigPart.part
	if not rootPart or not rootPart:IsA("BasePart") then
		return false, "'" .. tostring(entry.root) .. "' is not a part of the rig"
	end
	local rootJoint: JointInstance? = rigPart.joint
	local hinge = rootJoint and jointWorld(rootJoint, rootPart) or rootPart.CFrame
	local pivotLocal = entry.pivot
	local pivot = if type(pivotLocal) == "table"
		then (hinge :: CFrame) * Vector3.new(pivotLocal[1] or 0, pivotLocal[2] or 0, pivotLocal[3] or 0)
		else (hinge :: CFrame).Position

	local parts = collectBranch(rigModel, rootPart, rootJoint)
	local inBranch: { [BasePart]: boolean } = {}
	for _, p in ipairs(parts) do
		inBranch[p] = true
	end

	local target: { [BasePart]: CFrame } = {}
	for _, p in ipairs(parts) do
		local cf = p.CFrame
		target[p] = CFrame.new(pivot + (cf.Position - pivot) * k) * cf.Rotation
	end

	-- channels whose animation translations scale (the root's own do not)
	local channels: { [string]: boolean } = {}

	-- joints: inside the branch scale, the root joint only re-hangs the root
	local welds: { WeldConstraint } = {}
	local doneJoints: { [Instance]: boolean } = {}
	for _, p in ipairs(parts) do
		for _, j in ipairs(p:GetJoints()) do
			if doneJoints[j] then
				continue
			end
			doneJoints[j] = true
			if j:IsA("WeldConstraint") then
				local wc = j :: WeldConstraint
				if wc.Enabled then
					wc.Enabled = false
					table.insert(welds, wc)
				end
			elseif j:IsA("JointInstance") then
				local joint = j :: JointInstance
				if joint == rootJoint then
					if joint.Part1 == rootPart then
						joint.C1 = target[rootPart]:Inverse() * (hinge :: CFrame)
					else
						joint.C0 = target[rootPart]:Inverse() * (hinge :: CFrame)
					end
				elseif joint.Part0 and joint.Part1 and inBranch[joint.Part0] and inBranch[joint.Part1] then
					joint.C0 = scalePos(joint.C0, k)
					joint.C1 = scalePos(joint.C1, k)
					if joint:IsA("Motor6D") then
						channels[(joint.Part1 :: BasePart).Name] = true
					end
				end
			end
		end
	end

	for _, p in ipairs(parts) do
		p.Size *= k
		scaleChildren(p, k, channels)
	end
	for _, p in ipairs(parts) do
		p.CFrame = target[p]
	end
	for _, wc in ipairs(welds) do
		wc.Enabled = true
	end

	local maxError = 0
	for _, p in ipairs(parts) do
		maxError = math.max(maxError, (p.CFrame.Position - target[p].Position).Magnitude)
	end
	channels[entry.root] = nil

	local animations = scaleAnimations(rigModel, channels, k)
	return true, { parts = #parts, animations = animations, maxError = maxError }
end

return BranchScaler
