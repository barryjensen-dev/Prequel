-- ♻️ Make Reloadable
if _G.AutoAimScriptLoader and _G.AutoAimScriptLoader.Unload then
	_G.AutoAimScriptLoader.Unload()
end
_G.AutoAimScriptLoader = {}

-- ✅ Prevent double-execution
if _G.AutoAimScriptLoader.Running then return end
_G.AutoAimScriptLoader.Running = true

-- SERVICES
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Teams = game:GetService("Teams")
local Camera = workspace.CurrentCamera
local LocalPlayer = Players.LocalPlayer

-- SETTINGS
local TOOL_NAMES = {"M9", "Remington 870", "AK-47", "M4A1"}
local LINE_THICKNESS = 1
local ROTATE_SPEED = 0.15
local FIRE_COOLDOWN = 0.3
local PREDICTION_FACTOR = 1

-- STATE
local ESP = {}
local connections = {}
local enabled = true
local hue = 0
local lastFireTime = 0
local PROJECTILE_SPEED = 125

-- CLEANUP HANDLER
function _G.AutoAimScriptLoader.Unload()
	-- Disconnect connections
	for _, conn in pairs(connections) do
		pcall(function() conn:Disconnect() end)
	end
	-- Remove ESP
	for _, lines in pairs(ESP) do
		for _, line in pairs(lines) do
			if line and line.Remove then pcall(function() line:Remove() end) end
		end
	end
	ESP = {}
	_G.AutoAimScriptLoader.Running = false
	print("[AutoAim] Script unloaded.")
end

-- DRAWING
local function newLine()
	local success, line = pcall(function()
		local l = Drawing.new("Line")
		l.Thickness = LINE_THICKNESS
		l.Visible = true
		return l
	end)
	return success and line or nil
end

local function getJoints(char)
	return {
		Head = char:FindFirstChild("Head"),
		Torso = char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("Torso") or char:FindFirstChild("UpperTorso"),
		LeftArm = char:FindFirstChild("Left Arm") or char:FindFirstChild("LeftUpperArm"),
		RightArm = char:FindFirstChild("Right Arm") or char:FindFirstChild("RightUpperArm"),
		LeftLeg = char:FindFirstChild("Left Leg") or char:FindFirstChild("LeftUpperLeg"),
		RightLeg = char:FindFirstChild("Right Leg") or char:FindFirstChild("RightUpperLeg"),
	}
end

local function createESP(player)
	if player == LocalPlayer or ESP[player] then return end
	ESP[player] = {
		Tracer = newLine(),
		HeadTorso = newLine(),
		LeftArm = newLine(),
		RightArm = newLine(),
		LeftLeg = newLine(),
		RightLeg = newLine(),
	}
end

local function removeESP(player)
	if ESP[player] then
		for _, line in pairs(ESP[player]) do
			if line then pcall(function() line:Remove() end) end
		end
		ESP[player] = nil
	end
end

local function getNearestEnemy()
	local closest, minDist = nil, math.huge
	for _, p in pairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
			if p.Team == LocalPlayer.Team or LocalPlayer:IsFriendsWith(p.UserId) then continue end
			local hrp = p.Character.HumanoidRootPart
			local _, onScreen = Camera:WorldToViewportPoint(hrp.Position)
			if not onScreen then continue end
			local dist = (Camera.CFrame.Position - hrp.Position).Magnitude
			if dist < minDist then
				minDist = dist
				closest = p
			end
		end
	end
	return closest
end

local function getPredictedPosition(target)
	local hrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	local velocity = hrp.Velocity
	local distance = (Camera.CFrame.Position - hrp.Position).Magnitude
	local timeToHit = distance / PROJECTILE_SPEED
	return hrp.Position + (velocity * timeToHit * PREDICTION_FACTOR)
end

-- 🧰 Silent Auto-Aim + Fire
local function autoAimAndFire(target)
	local char, backpack = LocalPlayer.Character, LocalPlayer:FindFirstChild("Backpack")
	if not char or not backpack then return end

	local tool
	for _, t in ipairs(backpack:GetChildren()) do
		if t:IsA("Tool") and table.find(TOOL_NAMES, t.Name) then tool = t break end
	end
	for _, t in ipairs(char:GetChildren()) do
		if t:IsA("Tool") and table.find(TOOL_NAMES, t.Name) then tool = t break end
	end
	if not tool then return end

	-- Equip if not already equipped
	if not char:FindFirstChild(tool.Name) then
		char.Humanoid:EquipTool(tool)
	end

	local now = tick()
	if now - lastFireTime >= FIRE_COOLDOWN then
		lastFireTime = now
		pcall(function()
			tool:Activate()
		end)
	end
end

local function faceTarget(target)
	local myHRP = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
	local predicted = getPredictedPosition(target)
	if myHRP and predicted then
		local dir = (predicted - myHRP.Position).Unit
		myHRP.CFrame = myHRP.CFrame:Lerp(CFrame.lookAt(myHRP.Position, myHRP.Position + dir), ROTATE_SPEED)
	end
end

-- 📏 Auto Projectile Speed Detection
local function setupProjectileSpeedDetector()
	local function trackBullet(bullet)
		local start = bullet.Position
		local t1 = tick()
		task.delay(0.1, function()
			if bullet and bullet.Parent then
				local speed = (bullet.Position - start).Magnitude / (tick() - t1)
				if speed > 5 then PROJECTILE_SPEED = speed end
			end
		end)
	end
	local folder = workspace:FindFirstChild("GunProjectiles")
	if folder then table.insert(connections, folder.ChildAdded:Connect(trackBullet)) end
	table.insert(connections, workspace.ChildAdded:Connect(function(c)
		if c:IsA("BasePart") and c.Name == "Bullet" then trackBullet(c) end
	end))
end

-- ⌨️ Toggle Keybind
table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not gameProcessed and input.KeyCode == Enum.KeyCode.RightControl then
		enabled = not enabled
		for _, lines in pairs(ESP) do
			for _, line in pairs(lines) do
				if line then line.Visible = enabled end
			end
		end
		print("[AutoAim] Enabled:", enabled)
	end
end))

-- ♾️ Main Loop
table.insert(connections, RunService.RenderStepped:Connect(function()
	if not enabled then return end
	hue = (hue + 0.005) % 1

	for p, lines in pairs(ESP) do
		local char = p.Character
		local j = char and getJoints(char)
		local hrp = j and j.Torso
		if char and j and j.Head and hrp then
			local headPos, headVisible = Camera:WorldToViewportPoint(j.Head.Position)
			local torsoPos, torsoVisible = Camera:WorldToViewportPoint(hrp.Position)

			local c = {
				lines.HeadTorso, Color3.fromHSV(hue, 1, 1),
				lines.LeftArm,   Color3.fromHSV((hue+0.1)%1, 1, 1),
				lines.RightArm,  Color3.fromHSV((hue+0.2)%1, 1, 1),
				lines.LeftLeg,   Color3.fromHSV((hue+0.3)%1, 1, 1),
				lines.RightLeg,  Color3.fromHSV((hue+0.4)%1, 1, 1),
				lines.Tracer,    Color3.fromHSV((hue+0.5)%1, 1, 1),
			}
			for i = 1, #c, 2 do c[i].Color = c[i+1] end

			lines.HeadTorso.Visible = headVisible and torsoVisible
			if lines.HeadTorso.Visible then
				lines.HeadTorso.From = Vector2.new(headPos.X, headPos.Y)
				lines.HeadTorso.To = Vector2.new(torsoPos.X, torsoPos.Y)
			end

			for limb, part in pairs({LeftArm=j.LeftArm, RightArm=j.RightArm, LeftLeg=j.LeftLeg, RightLeg=j.RightLeg}) do
				if part then
					local pos, visible = Camera:WorldToViewportPoint(part.Position)
					lines[limb].Visible = visible and torsoVisible
					if visible then
						lines[limb].From = Vector2.new(torsoPos.X, torsoPos.Y)
						lines[limb].To = Vector2.new(pos.X, pos.Y)
					end
				end
			end

			local pos, visible = Camera:WorldToViewportPoint(hrp.Position)
			lines.Tracer.Visible = visible
			if visible then
				lines.Tracer.From = Vector2.new(Camera.ViewportSize.X/2, Camera.ViewportSize.Y)
				lines.Tracer.To = Vector2.new(pos.X, pos.Y)
			end
		else
			for _, l in pairs(lines) do l.Visible = false end
		end
	end

	local target = getNearestEnemy()
	if target then
		faceTarget(target)
		autoAimAndFire(target)
	end
end))

-- 👥 Player Tracking
table.insert(connections, Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function() task.wait(1) createESP(p) end)
end))
table.insert(connections, Players.PlayerRemoving:Connect(removeESP))
for _, p in ipairs(Players:GetPlayers()) do if p ~= LocalPlayer then createESP(p) end end

setupProjectileSpeedDetector()
