-- Extract the vendored Packages folder (Fusion 0.2 + Promise) from an installed
-- RBXMonkey plugin file: lune run tools/bb/extract_packages.luau <Plugin.rbxm> <out.rbxm>
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local process = require("@lune/process")

local input, output = process.args[1], process.args[2]
local roots = roblox.deserializeModel(fs.readFile(input))
local found
for _, root in roots do
	local candidate = if root.Name == "Packages" then root else root:FindFirstChild("Packages", true)
	if candidate then
		found = candidate
		break
	end
end
assert(found, "No Packages folder in " .. input)
local children = {}
for _, c in found:GetChildren() do
	table.insert(children, c.Name .. ":" .. c.ClassName)
end
print("Packages:", table.concat(children, ", "))
local fusion = found:FindFirstChild("Fusion")
print("Fusion has ForValues:", fusion and fusion:FindFirstChild("ForValues", true) ~= nil)
fs.writeFile(output, roblox.serializeModel({ found }))
print("wrote", output)
