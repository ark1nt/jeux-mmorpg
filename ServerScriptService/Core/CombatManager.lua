-- ServerScriptService/Core/CombatManager
-- 📜 Script (Serveur uniquement)

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local EnemyAnimator     = require(ServerScriptService.Systems.EnemyAnimator)
local GameConfig        = require(ReplicatedStorage.Shared.GameConfig)
local PlayerDataManager = require(ServerScriptService.Core.PlayerDataManager)
local XPManager         = require(ServerScriptService.Core.XPManager)
local LootManager       = require(ServerScriptService.Systems.LootManager)
local QuestManager      = require(ServerScriptService.Systems.QuestManager)

local ok, Logger = pcall(function()
	return require(ServerScriptService.Utils.Logger)
end)

if not ok then
	warn("Logger failed: " .. tostring(Logger))
	Logger = {
		info   = function(s, m) print(s, m) end,
		warn   = function(s, m) warn(s, m) end,
		error  = function(s, m) error(m) end,
		player = function(s, p, m) print(s, p.Name, m) end,
	}
end

local RemoteEvents  = ReplicatedStorage.RemoteEvents
local RequestAttack = RemoteEvents.Combat.RequestAttack
local DealDamage    = RemoteEvents.Combat.DealDamage
local PlayerDied    = RemoteEvents.Combat.PlayerDied
local EnemyDied     = RemoteEvents.Combat.EnemyDied

------------------------------------------------------------------------
-- CONFIGURATION COMBAT
------------------------------------------------------------------------
local COMBAT_CONFIG = {
	BASE_ATTACK_COOLDOWN = 0.8,
	AGGRO_RANGE          = 30,
	ATTACK_RANGE         = 5,
	RESPAWN_TIME         = 5,
	CRIT_CHANCE          = 0.1,
	CRIT_MULTIPLIER      = 1.75,
}

local attackCooldowns = {}
local dyingPlayers    = {} -- 
local invinciblePlayers = {} -- 

------------------------------------------------------------------------
-- UTILITAIRES
------------------------------------------------------------------------
local function getDistance(posA, posB)
	return (posA - posB).Magnitude
end

local function calculateDamage(attackerStats, defenderStats)
	local baseDamage = attackerStats.attack - (defenderStats.defense * 0.5)
	baseDamage = math.max(1, baseDamage)

	local isCrit = math.random() < COMBAT_CONFIG.CRIT_CHANCE
	if isCrit then
		baseDamage = math.floor(baseDamage * COMBAT_CONFIG.CRIT_MULTIPLIER)
	end

	local variance = 0.9 + math.random() * 0.2
	baseDamage = math.floor(baseDamage * variance)

	return baseDamage, isCrit
end


local function isPlayerAlive(player)
	local data = PlayerDataManager.getData(player)
	if not data or not data.stats then return false end
	if data.stats.hp == nil then return true end
	return data.stats.hp > 0
end

------------------------------------------------------------------------
-- MORT DU JOUEUR
------------------------------------------------------------------------
local function handlePlayerDeath(player)
	if dyingPlayers[player.UserId] then return end
	dyingPlayers[player.UserId] = true

	local data = PlayerDataManager.getData(player)
	if not data then
		dyingPlayers[player.UserId] = nil
		return
	end

	Logger.player("CombatManager", player, "est mort.")
	PlayerDied:FireClient(player)

	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = 0
		end
	end

	task.wait(COMBAT_CONFIG.RESPAWN_TIME)

	if player.Parent then
		data.stats.hp   = math.floor(data.stats.maxHp * 0.5)
		data.stats.mana = math.floor(data.stats.maxMana * 0.5)

		invinciblePlayers[player.UserId] = true
		task.delay(5, function()
			invinciblePlayers[player.UserId] = nil
		end)

		
		local PDL = ReplicatedStorage:FindFirstChild("RemoteEvents")
		if PDL then
			local evt = PDL:FindFirstChild("PlayerDataLoaded")
			if evt then
				evt:FireClient(player, {
					stats = data.stats,
					gold  = data.gold,
					level = data.level,
				})
			end
		end

		Logger.player("CombatManager", player, "a respawné avec " .. data.stats.hp .. " HP.")
	end

	dyingPlayers[player.UserId] = nil
end

------------------------------------------------------------------------
-- ATTAQUE JOUEUR → ENNEMI
------------------------------------------------------------------------
local function playerAttackEnemy(player, enemyModel)
	local data = PlayerDataManager.getData(player)
	if not data then return false, "Données introuvables" end

	if not isPlayerAlive(player) then
		return false, "Joueur mort"
	end

	local now = tick()
	local lastAttack = attackCooldowns[player.UserId] or 0
	if now - lastAttack < COMBAT_CONFIG.BASE_ATTACK_COOLDOWN then
		return false, "Cooldown"
	end

	local character = player.Character
	if not character or not enemyModel then
		return false, "Cible introuvable"
	end

	local enemyRoot = enemyModel:FindFirstChild("RootPart")
	if not enemyRoot then return false, "RootPart introuvable" end

	local distance = getDistance(character.PrimaryPart.Position, enemyRoot.Position)
	if distance > COMBAT_CONFIG.ATTACK_RANGE then
		return false, "Trop loin"
	end

	local enemyStats = {
		attack  = enemyModel:GetAttribute("attack")  or 10,
		defense = enemyModel:GetAttribute("defense") or 5,
		maxHp   = enemyModel:GetAttribute("maxHp")   or 100,
	}

	local damage, isCrit = calculateDamage(data.stats, enemyStats)
	local enemyHp = (enemyModel:GetAttribute("hp") or enemyStats.maxHp) - damage
	enemyModel:SetAttribute("hp", math.max(0, enemyHp))
	attackCooldowns[player.UserId] = now

	DealDamage:FireAllClients({
		attacker    = player.Name,
		target      = enemyModel.Name,
		damage      = damage,
		isCrit      = isCrit,
		targetHp    = math.max(0, enemyHp),
		targetMaxHp = enemyStats.maxHp,
	})

	Logger.player("CombatManager", player, string.format(
		"attaque %s : %d dégâts%s",
		enemyModel.Name, damage,
		isCrit and " (CRITIQUE !)" or ""
		))

	if enemyHp <= 0 then
		local xpReward = enemyModel:GetAttribute("xpReward") or 50
		local orbCount = math.clamp(math.floor(xpReward / 25), 1, 5)
		LootManager.spawnOrbs("XPOrb", orbCount, enemyRoot.Position, player)
		XPManager.giveKillXP(player, { xpReward = xpReward })
		LootManager.giveEnemyLoot(player, enemyModel.Name, enemyRoot.Position)
		EnemyDied:FireAllClients({
			enemyName = enemyModel.Name,
			killer    = player.Name,
		})
		QuestManager.onEnemyKilled(player, enemyModel.Name)
		Logger.player("CombatManager", player, string.format("a tué %s", enemyModel.Name))
	end

	return true, nil
end

------------------------------------------------------------------------
-- ATTAQUE ENNEMI → JOUEUR
------------------------------------------------------------------------
local function enemyAttackPlayer(enemyModel, player)
	local data = PlayerDataManager.getData(player)
	if not data then return end
	if not data.stats then return end
	if not isPlayerAlive(player) then return end
	if dyingPlayers[player.UserId] then return end
	if invinciblePlayers[player.UserId] then return end

	local enemyStats = {
		attack  = enemyModel:GetAttribute("attack")  or 10,
		defense = enemyModel:GetAttribute("defense") or 5,
	}

	local damage, isCrit = calculateDamage(enemyStats, data.stats)
	data.stats.hp = math.max(0, data.stats.hp - damage)

	DealDamage:FireClient(player, {
		attacker    = enemyModel.Name,
		target      = player.Name,
		damage      = damage,
		isCrit      = isCrit,
		targetHp    = data.stats.hp,
		targetMaxHp = data.stats.maxHp,
	})

	Logger.info("CombatManager", string.format(
		"%s attaque %s : %d dégâts%s",
		enemyModel.Name, player.Name, damage,
		isCrit and " (CRITIQUE !)" or ""
		))

	if data.stats.hp <= 0 then
		task.spawn(function()
			handlePlayerDeath(player)
		end)
	end
end
------------------------------------------------------------------------
-- BOUCLE IA ENNEMIS
------------------------------------------------------------------------
local function startEnemyAI(enemyModel)
	task.spawn(function()
		local rootPart = enemyModel:FindFirstChild("RootPart")
		if not rootPart then
			warn("[CombatManager] RootPart introuvable sur " .. enemyModel.Name)
			return
		end
		while enemyModel and enemyModel.Parent do
			local enemyPos = rootPart.Position
			local target   = nil
			local minDist  = COMBAT_CONFIG.AGGRO_RANGE

			for _, player in pairs(Players:GetPlayers()) do
				local character = player.Character
				if character and character.PrimaryPart and isPlayerAlive(player) then
					local dist = getDistance(enemyPos, character.PrimaryPart.Position)
					if dist < minDist then
						minDist = dist
						target  = player
					end
				end
			end

			if target then
				local character = target.Character
				local targetPos = character.PrimaryPart.Position
				local dist      = getDistance(enemyPos, targetPos)
				enemyModel:SetAttribute("inCombat", true)

				if dist <= COMBAT_CONFIG.ATTACK_RANGE then
					EnemyAnimator.attack(enemyModel)
					enemyAttackPlayer(enemyModel, target)
				else
					EnemyAnimator.walk(enemyModel)
					local moveSpeed = enemyModel:GetAttribute("moveSpeed") or 10
					local direction = (targetPos - enemyPos).Unit
					direction = Vector3.new(direction.X, 0, direction.Z)
					local newPos = enemyPos + direction * moveSpeed * 0.1

					local rayOrigin     = Vector3.new(newPos.X, enemyPos.Y + 5, newPos.Z)
					local rayDirection  = Vector3.new(0, -10, 0)
					local raycastParams = RaycastParams.new()
					raycastParams.FilterDescendantsInstances = {enemyModel}
					raycastParams.FilterType = Enum.RaycastFilterType.Exclude

					local result  = workspace:Raycast(rayOrigin, rayDirection, raycastParams)
					local groundY = result and result.Position.Y or enemyPos.Y

					local lookAt = CFrame.lookAt(
						Vector3.new(newPos.X, groundY + 2, newPos.Z),
						Vector3.new(targetPos.X, groundY + 2, targetPos.Z)
					)
					rootPart.CFrame = lookAt
				end
			else
				EnemyAnimator.idle(enemyModel)
				enemyModel:SetAttribute("inCombat", false)
			end

			task.wait(0.1)
		end
	end)
end

------------------------------------------------------------------------
-- REMOTEFUNCTION
------------------------------------------------------------------------
RequestAttack.OnServerInvoke = function(player, enemyModel)
	if not enemyModel or not enemyModel:IsDescendantOf(workspace) then
		return { success = false, reason = "Cible invalide" }
	end

	local success, reason = playerAttackEnemy(player, enemyModel)
	return { success = success, reason = reason }
end

------------------------------------------------------------------------
-- INITIALISATION
------------------------------------------------------------------------
workspace.Enemies.ChildAdded:Connect(function(enemyModel)
	startEnemyAI(enemyModel)
end)

for _, enemyModel in pairs(workspace.Enemies:GetChildren()) do
	startEnemyAI(enemyModel)
end

local CombatManager = {}
return CombatManager
