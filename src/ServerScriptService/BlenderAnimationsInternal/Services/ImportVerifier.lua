--!strict

-- BB fork: automatic self-check after every import from Blender.
--
-- Blender sends control samples (`bb_check`): for a few frames, where each
-- joint should be (relative to the rig root) and the pose Transform it exported.
-- This replays those Transforms on the Studio rig with the rig's own C0/C1 and
-- Bone.CFrame (forward kinematics, no playback needed) and compares. When it
-- matches nothing is shown; otherwise it explains what is wrong and how to fix it.

local ImportVerifier = {}

local POS_TOL = 0.02 -- studs
local ANGLE_TOL = math.rad(2)

local function cf(components: { number }?): CFrame
	if type(components) ~= "table" or #components < 12 then
		return CFrame.identity
	end
	return CFrame.new(table.unpack(components))
end

local function angleBetween(a: CFrame, b: CFrame): number
	local _, angle = (a:Inverse() * b):ToAxisAngle()
	return math.abs(angle)
end

-- Joint frames of every channel, relative to the root part, for a pose table
local function forwardKinematics(rig: any, poses: { [string]: any }): { [string]: CFrame }
	local joints: { [string]: CFrame } = {}
	local partWorld: { [Instance]: CFrame } = {}

	local function walk(rigPart: any, world: CFrame)
		partWorld[rigPart.part] = world
		for _, child in ipairs(rigPart.children or {}) do
			local inst = child.part
			if typeof(inst) ~= "Instance" or joints[inst.Name] then
				continue
			end
			local T = cf(poses[inst.Name] and (type(poses[inst.Name][1]) == "table" and poses[inst.Name][1] or poses[inst.Name]))
			local joint: CFrame?
			local childWorld: CFrame?
			if inst:IsA("Bone") then
				local parentWorld = (inst.Parent and partWorld[inst.Parent]) or world
				joint = parentWorld * (inst :: Bone).CFrame * T
				childWorld = joint
			else
				local j = child.joint
				if j and (j:IsA("Motor6D") or j:IsA("Weld")) then
					local jt0, jt1 = (j :: any).C0, (j :: any).C1
					if not child.jointParentIsPart0 then
						jt0, jt1 = jt1, jt0
					end
					joint = world * jt0 * T
					childWorld = (joint :: CFrame) * jt1:Inverse()
				elseif j and j:IsA("AnimationConstraint") then
					local ac = j :: AnimationConstraint
					if ac.Attachment0 and ac.Attachment1 then
						local o0, o1 = ac.Attachment0.CFrame, ac.Attachment1.CFrame
						if not child.jointParentIsPart0 then
							o0, o1 = o1, o0
						end
						joint = world * o0 * T
						childWorld = (joint :: CFrame) * o1:Inverse()
					end
				elseif j and j:IsA("WeldConstraint") then
					local wc = j :: WeldConstraint
					if wc.Part0 and wc.Part1 then
						childWorld = world * wc.Part0.CFrame:ToObjectSpace(wc.Part1.CFrame)
						joint = childWorld
					end
				end
			end
			if joint and childWorld then
				joints[inst.Name] = joint
				walk(child, childWorld)
			end
		end
	end

	if rig and rig.root then
		walk(rig.root, CFrame.identity)
	end
	return joints
end

-- A joint inside a sub-model that has its own Humanoid/AnimationController is
-- skipped by the rig's Animator (the VM10 boomerang problem).
local function skippedBy(rig: any, name: string): Instance?
	local rigPart = rig.bones and rig.bones[name]
	if not rigPart then
		return nil
	end
	local probe: Instance? = rigPart.joint or rigPart.part
	local model = rig.model
	while probe and probe ~= model do
		if probe:IsA("Model") and probe ~= model then
			if probe:FindFirstChildWhichIsA("AnimationController") or probe:FindFirstChildWhichIsA("Humanoid") then
				return probe
			end
		end
		probe = probe.Parent
	end
	return nil
end

export type Issue = { channel: string, text: string }

function ImportVerifier.verify(rig: any, check: any): { Issue }
	local issues: { Issue } = {}
	if not rig or type(check) ~= "table" or type(check.rest) ~= "table" then
		return issues
	end

	local seen: { [string]: boolean } = {}
	local function add(channel: string, text: string)
		if seen[channel] then
			return
		end
		seen[channel] = true
		table.insert(issues, { channel = channel, text = text })
	end

	-- Structural problems first (they explain everything below them)
	for name in pairs(check.rest) do
		if not (rig.bones and rig.bones[name]) then
			add(name, "is not in the Studio rig — press Push Rig (or Bind Imported Mesh for skinned bones)")
		else
			local owner = skippedBy(rig, name)
			if owner then
				add(name, "is skipped by the Animator: '" .. owner.Name .. "' has its own AnimationController/Humanoid (Rig Doctor can remove it)")
			end
		end
	end

	-- Rest comparison
	local restFK = forwardKinematics(rig, {})
	local restBad: { [string]: boolean } = {}
	for name, comps in pairs(check.rest) do
		local studio = restFK[name]
		if studio and not seen[name] then
			local blender = cf(comps)
			local dPos = (studio.Position - blender.Position).Magnitude
			local dAng = angleBetween(studio, blender)
			if dPos > POS_TOL or dAng > ANGLE_TOL then
				restBad[name] = true
			end
		end
	end

	-- Report only the topmost channel of a mismatching chain
	local function parentName(name: string): string?
		local rp = rig.bones[name]
		return rp and rp.parent and rp.parent.part and rp.parent.part.Name or nil
	end
	for name in pairs(restBad) do
		local p = parentName(name)
		if not (p and restBad[p]) then
			local studio, blender = restFK[name], cf(check.rest[name])
			add(
				name,
				string.format(
					"rest differs from Blender by %.3f studs / %.1f° — Push Rig (joints) or re-export + Bind Imported Mesh (skinned)",
					(studio.Position - blender.Position).Magnitude,
					math.deg(angleBetween(studio, blender))
				)
			)
		end
	end

	-- Animated frames
	for _, frame in ipairs(check.frames or {}) do
		local fk = forwardKinematics(rig, frame.poses or {})
		local bad: { [string]: number } = {}
		for name, comps in pairs(frame.joints or {}) do
			local studio = fk[name]
			if studio and not seen[name] and not restBad[name] then
				local blender = cf(comps)
				local dPos = (studio.Position - blender.Position).Magnitude
				local dAng = angleBetween(studio, blender)
				if dPos > POS_TOL or dAng > ANGLE_TOL then
					bad[name] = dAng
				end
			end
		end
		for name, dAng in pairs(bad) do
			local p = parentName(name)
			if not (p and bad[p]) then
				local hint = if math.abs(dAng - math.pi) < math.rad(10)
					then "turned ~180° (bone axes differ; re-export, or press Push Rig to re-stamp)"
					else string.format("off by %.1f° at frame %s", math.deg(dAng), tostring(frame.frame))
				add(name, "pose does not match Blender: " .. hint)
			end
		end
	end

	table.sort(issues, function(a, b)
		return a.channel < b.channel
	end)
	return issues
end

function ImportVerifier.summarize(issues: { Issue }, limit: number?): string
	if #issues == 0 then
		return ""
	end
	local parts = {}
	for i, issue in ipairs(issues) do
		if i > (limit or 4) then
			table.insert(parts, string.format("+%d more", #issues - (limit or 4)))
			break
		end
		table.insert(parts, issue.channel .. " " .. issue.text)
	end
	return table.concat(parts, "; ")
end

return ImportVerifier
