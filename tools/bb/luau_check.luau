-- Compile every plugin source file to catch syntax errors (run with: lune run tools/bb/luau_check.luau)
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local root = "src/ServerScriptService/BlenderAnimationsInternal"
local failures, count = 0, 0

local function walk(dir: string)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			if not string.find(name, "testez", 1, true) then
				walk(path)
			end
		elseif string.match(name, "%.lua$") or string.match(name, "%.luau$") then
			count += 1
			local ok, err = pcall(luau.compile, fs.readFile(path))
			if not ok then
				failures += 1
				print(path .. ": " .. tostring(err))
			end
		end
	end
end

walk(root)
print(string.format("checked %d files, %d failed", count, failures))
if failures > 0 then
	process.exit(1)
end
