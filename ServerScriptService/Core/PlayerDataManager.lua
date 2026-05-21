-- ServerScriptService/Core/PlayerDataManager
-- 📜 ModuleScript (Serveur uniquement)

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

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

local ok2, GameConfig = pcall(function()
	return require(ReplicatedStorage.Shared.GameConfig)
end)

if not ok2 then
	warn("GameConfig failed: " .. tostring(GameConfig))
end

local RemoteEvents     = ReplicatedStorage:FindFirstChild("RemoteEvents")
local PlayerDataLoaded = RemoteEvents and RemoteEvents:FindFirstChild("PlayerDataLoaded")

local PlayerDataStore = DataStoreService:GetDataStore("PlayerData_v1")
local playerCache     = {}
local PlayerDataManager = {}

------------------------------------------------------------------------
-- DONNÉES PAR DÉFAUT
------------------------------------------------------------------------
local function getDefaultData()
	local xpBase      = (GameConfig and GameConfig.XP_BASE)                                      or 100
	local baseHp      = (GameConfig and GameConfig.BASE_STATS and GameConfig.BASE_STATS.hp)      or 100
	local baseMana    = (GameConfig and GameConfig.BASE_STATS and GameConfig.BASE_STATS.mana)    or 50
	local baseAttack  = (GameConfig and GameConfig.BASE_STATS and GameConfig.BASE_STATS.attack)  or 10
	local baseDefense = (GameConfig and GameConfig.BASE_STATS and GameConfig.BASE_STATS.defense) or 5
	local baseSpeed   = (GameConfig and GameConfig.BASE_STATS and GameConfig.BASE_STATS.speed)   or 16

	return {
		level    = 1,
		xp       = 0,
		xpToNext = xpBase,

		stats = {
			hp      = baseHp,
			maxHp   = baseHp,
			mana    = baseMana,
			maxMana = baseMana,
			attack  = baseAttack,
			defense = baseDefense,
			speed   = baseSpeed,
		},

		gold      = 0,
		inventory = {},

		equipped = {
			weapon = nil,
			armor  = nil,
		},

		quests = {
			active    = {},
			completed = {},
		},

		skills = {
			class           = "Guerrier",
			pointsTotal     = 0,
			pointsSpent     = 0,
			pointsAvailable = 0,
			learned         = {},
		},

		createdAt     = os.time(),
		lastSeen      = os.time(),
		exploredZones = {},
	}
end

------------------------------------------------------------------------
-- CALCUL XP
------------------------------------------------------------------------
local function getXPRequired(level)
	local xpBase       = (GameConfig and GameConfig.XP_BASE)       or 100
	local xpMultiplier = (GameConfig and GameConfig.XP_MULTIPLIER) or 1.5
	return math.floor(xpBase * (xpMultiplier ^ (level - 1)))
end

------------------------------------------------------------------------
-- CHARGEMENT
------------------------------------------------------------------------
local function loadData(player)
	local key = "player_" .. player.UserId
	local success, data = pcall(function()
		return PlayerDataStore:GetAsync(key)
	end)

	if success then
		if data then
			local default = getDefaultData()
			for k, v in pairs(default) do
				if data[k] == nil then
					data[k] = v
				end
			end
			data.lastSeen = os.time()

			-- ✅ Force HP/Mana au max au chargement
			data.stats.hp   = data.stats.maxHp
			data.stats.mana = data.stats.maxMana

			Logger.player("PlayerDataManager", player, "Données chargées")
			return data
		else
			Logger.player("PlayerDataManager", player, "Nouveau joueur !")
			return getDefaultData()
		end
	else
		Logger.warn("PlayerDataManager", "Erreur chargement " .. player.Name .. " : " .. tostring(data))
		return getDefaultData()
	end
end

------------------------------------------------------------------------
-- SAUVEGARDE
------------------------------------------------------------------------
local function saveData(player)
	local data = playerCache[player.UserId]
	if not data then return end

	local key = "player_" .. player.UserId
	data.lastSeen = os.time()

	local success, err = pcall(function()
		PlayerDataStore:SetAsync(key, data)
	end)

	if success then
		Logger.player("PlayerDataManager", player, "Sauvegarde OK")
	else
		Logger.warn("PlayerDataManager", "Erreur sauvegarde " .. player.Name .. " : " .. tostring(err))
	end
end

------------------------------------------------------------------------
-- GETTERS / SETTERS
------------------------------------------------------------------------
function PlayerDataManager.getData(player)
	return playerCache[player.UserId]
end

function PlayerDataManager.setData(player, key, value)
	if playerCache[player.UserId] then
		playerCache[player.UserId][key] = value
	end
end

------------------------------------------------------------------------
-- SKILLS
------------------------------------------------------------------------
function PlayerDataManager.getSkillPoints(player)
	local data = playerCache[player.UserId]
	if not data then return 0 end
	return data.skills.pointsAvailable
end

function PlayerDataManager.getSkillRank(player, skillId)
	local data = playerCache[player.UserId]
	if not data then return 0 end
	return data.skills.learned[skillId] or 0
end

function PlayerDataManager.learnSkill(player, skillId, cost)
	local data = playerCache[player.UserId]
	if not data then return false end

	local currentRank = data.skills.learned[skillId] or 0
	data.skills.pointsAvailable  = data.skills.pointsAvailable - cost
	data.skills.pointsSpent      = data.skills.pointsSpent + cost
	data.skills.learned[skillId] = currentRank + 1

	return true
end

function PlayerDataManager.addSkillPoints(player, amount)
	local data = playerCache[player.UserId]
	if not data then return end

	data.skills.pointsTotal     = data.skills.pointsTotal + amount
	data.skills.pointsAvailable = data.skills.pointsAvailable + amount

	Logger.player("PlayerDataManager", player, string.format(
		"+%d point(s) de compétence (%d disponibles)",
		amount, data.skills.pointsAvailable
		))
end

------------------------------------------------------------------------
-- EVENTS JOUEUR
------------------------------------------------------------------------
Players.PlayerAdded:Connect(function(player)
	local data = loadData(player)  -- ✅ CORRIGÉ — était Data(player)
	playerCache[player.UserId] = data

	task.wait(1)
	if PlayerDataLoaded then
		PlayerDataLoaded:FireClient(player, {
			stats = data.stats,
			gold  = data.gold,
			level = data.level,
		})
	else
		warn("[PlayerDataManager] PlayerDataLoaded introuvable !")
	end

	task.spawn(function()
		while player.Parent do
			task.wait(60)
			if player.Parent then
				saveData(player)
			end
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	saveData(player)
	playerCache[player.UserId] = nil
end)

game:BindToClose(function()
	Logger.info("PlayerDataManager", "Arrêt serveur — sauvegarde de tous les joueurs...")
	for _, player in pairs(Players:GetPlayers()) do
		saveData(player)
	end
end)

print("TEST - PlayerDataManager return: " .. tostring(PlayerDataManager))
return PlayerDataManager
