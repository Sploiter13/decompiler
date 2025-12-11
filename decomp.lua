--!native
--!optimize 2

local Decompiler = {}

local SERVER_URL = "http://127.0.0.1:5000/decompile"

local function get_script_bytecode(script)
	local OFFSETS
	
	if script.ClassName == "LocalScript" then
		OFFSETS = { ScriptByteCode = 0x1A8, ByteCodePointer = 0x10, ByteCodeSize = 0x20 }
	elseif script.ClassName == "ModuleScript" then
		OFFSETS = { ScriptByteCode = 0x150, ByteCodePointer = 0x10, ByteCodeSize = 0x20 }
	else
		return nil, nil
	end
	
	local script_address = tonumber(script.Data, 16)
	if not script_address then return nil, nil end
	
	local embedded = memory.readu64(script_address + OFFSETS.ScriptByteCode)
	if not embedded or embedded == 0 then return nil, nil end
	
	local bytecode_ptr = memory.readu64(embedded + OFFSETS.ByteCodePointer)
	if not bytecode_ptr or bytecode_ptr == 0 then return nil, nil end
	
	local bytecode_size = memory.readu64(embedded + OFFSETS.ByteCodeSize)
	if not bytecode_size or bytecode_size == 0 or bytecode_size > 10000000 then
		return nil, nil
	end
	
	local bytes = table.create(bytecode_size)
	for i = 0, bytecode_size - 1 do
		bytes[i + 1] = string.char(memory.readu8(bytecode_ptr + i))
	end
	
	return table.concat(bytes), bytecode_size
end

local function get_by_path(path)
	local parts = string.split(path, ".")
	local current = game
	for _, part in ipairs(parts) do
		current = current:FindFirstChild(part)
		if not current then
			return nil
		end
	end
	return current
end

function Decompiler.new(config)
	local self = {}
	
	self.target = config.target
	self.output_file = config.output_file or "decompiled.lua"
	self.silent = config.silent or false
	
	local function log(msg)
		if not self.silent then
			print(msg)
		end
	end
	
	function self.decompile()
		local script
		if type(self.target) == "string" then
			script = get_by_path(self.target)
			if not script then
				warn(`[DECOMPILER] Target not found: {self.target}`)
				return nil
			end
		else
			script = self.target
		end
		
		if not script or (script.ClassName ~= "LocalScript" and script.ClassName ~= "ModuleScript") then
			warn("[DECOMPILER] Invalid target (must be LocalScript or ModuleScript)")
			return nil
		end
		
		local path = ""
		local current = script
		while current and current ~= game do
			path = current.Name .. (path ~= "" and "." .. path or "")
			current = current.Parent
		end
		path = "game." .. path
		
		log("\n============================================================")
		log(`[DECOMPILER] Processing: {path}`)
		log(`[DECOMPILER] Type: {script.ClassName}`)
		log("============================================================\n")
		
		log("[1/3] Extracting bytecode...")
		local bytecode, size = get_script_bytecode(script)
		if not bytecode then
			warn("[DECOMPILER] Failed to extract bytecode")
			return nil
		end
		log(`[✓] Extracted {size} bytes`)
		
		log("\n[2/3] Sending to decompiler server via HttpPost (crypt.base64)...")
		local b64 = crypt.base64.encode(bytecode)
		
		local ok, response = pcall(function()
			return game:HttpPost(SERVER_URL, b64, "text/plain", "text/plain", "")
		end)
		
		if not ok then
			warn(`[DECOMPILER] HttpPost failed: {response}`)
			return nil
		end
		
		if type(response) ~= "string" or #response == 0 then
			warn("[DECOMPILER] Empty response from server")
			return nil
		end
		
		log(`[✓] Received decompiled source ({#response} chars)`)
		
		log("\n[3/3] Saving decompiled source...")
		local success, err = pcall(function()
			writefile(self.output_file, response)
		end)
		
		if not success then
			warn(`[DECOMPILER] Failed to save file: {err}`)
		else
			log(`[✓] Saved to: {self.output_file}`)
		end
		
		log("\n============================================================")
		log("[SUCCESS] Decompilation complete!")
		log("============================================================\n")
		
		return response
	end
	
	return self
end

return Decompiler
