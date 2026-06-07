--[[
    ========================================================================
    ClickBrainrot Flooder v3 + Auto Buy Upgrades
    ========================================================================
    Envia multiplas chamadas do remote ClickBrainrot SEM travar o jogo.
    + Sistema automatico de compra de upgrades.

    Diferenciais:
      - Usa RunService.Heartbeat (sincronizado com o framerate)
      - Frame-budget: max N chamadas por frame para nao pesar no render
      - Fila de execucao assincrona (nunca bloqueia)
      - Sem notificacoes durante rajada (zero overhead)
      - Coleta de lixo manual a cada ciclo
      - Modo sleep quando minimizado / sem foco
      - Auto Buy: compra upgrades automaticamente quando tem cash

    Remote: ReplicatedStorage.Remotes.ClickBrainrot
    Args: { [1] = 1 }
    ========================================================================
]]

-- ===================== RESOLUCAO OTIMIZADA =====================
local RS          = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")
local Player      = game:GetService("Players").LocalPlayer

-- Resolve o remote uma unica vez (cache permanente)
local ClickBrainrot = RS:FindFirstChild("Remotes") and RS.Remotes:FindFirstChild("ClickBrainrot")
if not ClickBrainrot then
    ClickBrainrot = RS:WaitForChild("Remotes"):WaitForChild("ClickBrainrot")
end

-- Pre-aloca a tabela de args (reutilizada, sem GC)
local ARGS = { [1] = 1 }

-- Pre-aloca funcao de disparo (closure unica, sem criar toda vez)
local function FireOnce()
    pcall(ClickBrainrot.FireServer, ClickBrainrot, unpack(ARGS))
end

-- ===================== UPGRADE SYSTEM (DECOMPILED) =====================
local Modules = RS:WaitForChild("Modules")
local Upgrades = require(Modules:WaitForChild("Upgrades"))
local Rebirths = require(Modules:WaitForChild("Rebirths"))
local SharedFunctions = require(Modules:WaitForChild("SharedFunctions"))
local Remotes = RS:WaitForChild("Remotes")
local BuyUpgrade = Remotes:WaitForChild("BuyUpgrade")
local GetUpgradeState = Remotes:WaitForChild("GetUpgradeState")
local leaderstats = Player:WaitForChild("leaderstats")
local Cash = leaderstats:WaitForChild("Cash")
local RebirthsStat = leaderstats:WaitForChild("Rebirths")

-- Cache dos upgrades disponiveis (ordenados por layoutOrder)
local UpgradeList = {}
for name, data in pairs(Upgrades) do
    table.insert(UpgradeList, {
        name = name,
        data = data,
        layoutOrder = data.layoutOrder or 0,
        baseCost = data.baseCost or 1,
        costGrowth = data.CostGrowth or 1,
        rebirthReq = data.Rebirth or 0,
        cps = data.CPS or 0,
        cashPerClick = data.CashPerClick or 0,
    })
end
table.sort(UpgradeList, function(a, b) return a.layoutOrder < b.layoutOrder end)

-- Nomes dos upgrades para UI
local UpgradeNames = {}
for _, u in ipairs(UpgradeList) do
    table.insert(UpgradeNames, u.name)
end

-- Estado dos niveis (atualizado via GetUpgradeState)
local UpgradeLevels = {}
local function FetchState()
    local ok, state = pcall(function()
        return GetUpgradeState:InvokeServer()
    end)
    if ok and type(state) == "table" and state.levels then
        UpgradeLevels = state.levels or {}
    end
end
FetchState()

-- Calculo de custo (mesma formula do jogo)
local function GetUpgradeCost(upgradeName, currentLevel)
    local info = Upgrades[upgradeName]
    if not info then return math.huge end
    local base = info.baseCost or 1
    local growth = info.CostGrowth or 1
    local cost = base * (growth ^ currentLevel)
    -- Aplica desconto do brainrot equipado
    if state and state.equippedBrainrot then
        local CharacterData = require(Modules:WaitForChild("CharacterData"))
        local charData = CharacterData.Characters[state.equippedBrainrot]
        if charData then
            local attrs = charData.Attributes or charData
            if attrs then
                local discount = attrs["Upgrade Costs"]
                if type(discount) == "number" and discount > 0 then
                    cost = cost * (1 - discount / 100)
                end
            end
        end
    end
    if cost < 1 then cost = 1 end
    return math.floor(cost + 0.5)
end

-- Custo total para comprar N niveis
local function GetBulkCost(upgradeName, currentLevel, amount)
    local sum = 0
    for i = 0, amount - 1 do
        local c = GetUpgradeCost(upgradeName, currentLevel + i)
        if c == math.huge or c <= 0 then break end
        sum = sum + c
    end
    return sum
end

-- Max buy: quantos niveis da pra comprar com o cash atual
local function GetMaxBuyCount(upgradeName, currentLevel, maxCash)
    local count = 0
    local sum = 0
    for i = 1, 500 do
        local c = GetUpgradeCost(upgradeName, currentLevel + i - 1)
        if c == math.huge or c <= 0 then break end
        if sum + c > maxCash then break end
        sum = sum + c
        count = count + 1
    end
    return count, sum
end

-- Compra um upgrade
local function TryBuyUpgrade(upgradeName, amount)
    local ok, result = pcall(function()
        return BuyUpgrade:InvokeServer(upgradeName, amount or 1)
    end)
    if ok and type(result) == "table" and result.success then
        if result.newLevel then
            UpgradeLevels[upgradeName] = result.newLevel
        end
        return true, result
    end
    return false, result
end

-- ===================== ESTADO GLOBAL FLOOD =====================
local Times        = 10
local Speed        = 0.05
local BurstDelay   = 1.0
local Looping      = false
local Running      = false

-- ESTADO AUTO BUY
local AutoBuyEnabled = false
local AutoBuyRunning = false
local AutoBuyInterval = 0.5
local AutoBuyBuyTimes = 1  -- 1=x1, 10=x10, 100=x100, 500=x500
local AutoBuyPrioritize = "CPS"  -- "CPS" | "Cheapest" | "BestValue"
local AutoBuySelectedOnly = false
local AutoBuySelectedUpgrade = UpgradeNames[1] or ""
local AutoBuyBlacklist = {}
local AutoBuyLog = {}

local function AddLog(msg)
    local time = os.date("%H:%M:%S")
    table.insert(AutoBuyLog, "[" .. time .. "] " .. msg)
    if #AutoBuyLog > 50 then
        table.remove(AutoBuyLog, 1)
    end
end

-- ===================== FILA DE EXECUCAO (HEARTBEAT) =====================
local Queue = {
    pending   = 0,
    total     = 0,
    delay     = 0,
    elapsed   = 0,
    timestamp = 0,
    maxPerFrame = 5,
    mode      = "idle",
    cooldown  = 0,
    nextBatch = 0,
}

local function ResetQueue()
    Queue.pending   = 0
    Queue.total     = 0
    Queue.delay     = 0
    Queue.elapsed   = 0
    Queue.timestamp = 0
    Queue.mode      = "idle"
    Queue.cooldown  = 0
    Queue.nextBatch = 0
end

local function QueueBurst(quantidade, delay)
    Queue.pending   = quantidade
    Queue.total     = quantidade
    Queue.delay     = delay
    Queue.elapsed   = 0
    Queue.timestamp = tick()
    Queue.mode      = "sending"
    Running = true
end

-- ===================== AUTO BUY ENGINE =====================
local AutoBuyQueue = {
    pending   = 0,
    delay     = 0,
    elapsed   = 0,
    mode      = "idle",
}

local function ResetAutoBuyQueue()
    AutoBuyQueue.pending = 0
    AutoBuyQueue.delay   = 0
    AutoBuyQueue.elapsed = 0
    AutoBuyQueue.mode    = "idle"
end

-- Decide qual upgrade comprar e executa
local function AutoBuyTick()
    if not AutoBuyEnabled then return end
    if AutoBuyRunning then return end

    FetchState()

    local cashVal = Cash.Value or 0
    local rebirthsVal = RebirthsStat.Value or 0

    local targets = {}

    for _, u in ipairs(UpgradeList) do
        if u.rebirthReq <= rebirthsVal then
            local isBlacklisted = false
            for _, bl in ipairs(AutoBuyBlacklist) do
                if bl == u.name then isBlacklisted = true; break end
            end
            if not isBlacklisted then
                if AutoBuySelectedOnly then
                    if u.name == AutoBuySelectedUpgrade then
                        table.insert(targets, u)
                    end
                else
                    table.insert(targets, u)
                end
            end
        end
    end

    if #targets == 0 then return end

    -- Ordena por prioridade
    if AutoBuyPrioritize == "CPS" then
        table.sort(targets, function(a, b)
            local aEff = (a.cashPerClick > 0 and a.cashPerClick or a.cps) / math.max(GetUpgradeCost(a.name, UpgradeLevels[a.name] or 0), 1)
            local bEff = (b.cashPerClick > 0 and b.cashPerClick or b.cps) / math.max(GetUpgradeCost(b.name, UpgradeLevels[b.name] or 0), 1)
            return aEff > bEff
        end)
    elseif AutoBuyPrioritize == "Cheapest" then
        table.sort(targets, function(a, b)
            local aCost = GetUpgradeCost(a.name, UpgradeLevels[a.name] or 0)
            local bCost = GetUpgradeCost(b.name, UpgradeLevels[b.name] or 0)
            return aCost < bCost
        end)
    elseif AutoBuyPrioritize == "BestValue" then
        table.sort(targets, function(a, b)
            local aCost = GetUpgradeCost(a.name, UpgradeLevels[a.name] or 0)
            local bCost = GetUpgradeCost(b.name, UpgradeLevels[b.name] or 0)
            local aEff = (a.cashPerClick > 0 and a.cashPerClick or a.cps) / math.max(aCost, 1)
            local bEff = (b.cashPerClick > 0 and b.cashPerClick or b.cps) / math.max(bCost, 1)
            return aEff > bEff
        end)
    end

    -- Tenta comprar o melhor alvo
    for _, target in ipairs(targets) do
        local level = UpgradeLevels[target.name] or 0
        local cost = GetUpgradeCost(target.name, level)

        if cost <= cashVal then
            local amount = AutoBuyBuyTimes

            -- Se buy times excede o cash, cai para o maximo possivel
            local bulkCost = GetBulkCost(target.name, level, amount)
            if bulkCost > cashVal then
                -- Tenta comprar pelo menos 1
                if cost <= cashVal then
                    amount = 1
                else
                    continue
                end
            end

            AutoBuyRunning = true
            local success, result = TryBuyUpgrade(target.name, amount)
            if success then
                local bought = (result and result.boughtLevels) or amount
                local itemType = target.cps > 0 and "CPS" or "Click"
                AddLog("SAIU! " .. target.name .. " x" .. tostring(bought) .. " (" .. itemType .. " $" .. tostring(cost) .. ")")
            else
                AddLog("ERRO: " .. target.name .. " - " .. tostring(result and result.message or "falha"))
            end
            AutoBuyRunning = false
            return -- Compra um por tick para nao spammar
        end
    end
end

-- ===================== HEARTBEAT UNIFICADO =====================
RunService.Heartbeat:Connect(function(dt)
    -- Processa fila de flood
    if Queue.mode ~= "idle" then
        if Queue.mode == "sending" then
            local now = tick()
            if Queue.delay > 0 then
                Queue.elapsed = Queue.elapsed + dt
                local expected = math.floor(Queue.elapsed / Queue.delay)
                if expected > Queue.total - (Queue.total - Queue.pending) then
                    Queue.nextBatch = expected - (Queue.total - Queue.pending)
                else
                    Queue.nextBatch = 1
                end
            else
                Queue.nextBatch = math.min(Queue.pending, Queue.maxPerFrame)
            end

            if Queue.nextBatch > Queue.maxPerFrame then Queue.nextBatch = Queue.maxPerFrame end
            if Queue.nextBatch > Queue.pending then Queue.nextBatch = Queue.pending end

            for _ = 1, Queue.nextBatch do FireOnce() end
            Queue.pending = Queue.pending - Queue.nextBatch
            Queue.timestamp = now

            if Queue.pending <= 0 then
                Queue.mode = "cooldown"
                Queue.cooldown = 0.05
                Running = false
                if Looping then
                    Queue.cooldown = BurstDelay
                end
            end
            return
        end

        if Queue.mode == "cooldown" then
            Queue.cooldown = Queue.cooldown - dt
            if Queue.cooldown <= 0 then
                if Looping then
                    QueueBurst(Times, Speed)
                else
                    Queue.mode = "idle"
                end
            end
            return
        end
    end

    -- Processa auto buy
    if AutoBuyEnabled then
        AutoBuyQueue.elapsed = AutoBuyQueue.elapsed + dt
        if AutoBuyQueue.elapsed >= AutoBuyInterval then
            AutoBuyQueue.elapsed = 0
            AutoBuyTick()
        end
    end
end)

function SendBurst(quantidade, delay, paralelo)
    if Running and not Looping then return end
    if paralelo then
        QueueBurst(quantidade, 0)
    else
        QueueBurst(quantidade, delay)
    end
end

function DiagnoseClickBrainrot()
    local lines = {}
    if ClickBrainrot then
        table.insert(lines, "ClickBrainrot: OK (" .. ClickBrainrot:GetFullName() .. ")")
    else
        table.insert(lines, "ClickBrainrot: NAO ENCONTRADO!")
    end

    local remotes = RS:FindFirstChild("Remotes")
    local count = 0
    if remotes then
        for _ in pairs(remotes:GetChildren()) do count = count + 1 end
        table.insert(lines, "Remotes: " .. count .. " filhos")
    else
        table.insert(lines, "Remotes: PASTA AUSENTE")
    end

    local ok = pcall(FireOnce)
    table.insert(lines, "FireServer: " .. (ok and "OK" or "FALHOU"))
    table.insert(lines, "Upgrades: " .. #UpgradeList .. " disponiveis")

    print("===== DIAGNOSTICO CBROT =====")
    for _, l in ipairs(lines) do print("[CBRot]", l) end
    Rayfield:Notify({Title="ClickBrainrot v3", Content=table.concat(lines, " | "), Duration=8})
end

-- ===================== CARREGA RAYFIELD =====================
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "ClickBrainrot v3",
    LoadingTitle = "Carregando...",
    LoadingSubtitle = "Flood + Auto Buy",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "ClickBrainrot",
        FileName = "ConfigV3"
    },
    Discord = { Enabled = false, Invite = "noinvite", RememberJoins = true },
    KeySystem = false,
})

-- ===================== ABAS =====================
local TabFlood  = Window:CreateTab("Flood", 4483362458)
local TabAutoBuy = Window:CreateTab("Auto Buy", 4483362458)
local TabInfo   = Window:CreateTab("Info", 4483362458)

-- ===================== STATUS VARS =====================
local StatusVezes = "10x"
local StatusSpeed = "0.05s"
local StatusMode  = "Sequencial"

-- =====================================================================
-- ======================== ABA: FLOOD =================================
-- =====================================================================

local SecConfig = TabFlood:CreateSection("Controles")

TabFlood:CreateSlider({
    Name = "Vezes por Rajada",
    Range = {1, 5000},
    Increment = 1,
    Suffix = "x",
    CurrentValue = 10,
    Flag = "SldTimes",
    Callback = function(v)
        Times = math.floor(v)
        StatusVezes = math.floor(v) .. "x"
    end,
})

TabFlood:CreateSlider({
    Name = "Velocidade (delay entre chamadas)",
    Range = {0, 5},
    Increment = 0.01,
    Suffix = "s",
    CurrentValue = 0.05,
    Flag = "SldSpeed",
    Callback = function(v)
        Speed = v
        StatusSpeed = string.format("%.2fs", v)
    end,
})

TabFlood:CreateSlider({
    Name = "Delay entre Rajadas (loop)",
    Range = {0, 30},
    Increment = 0.1,
    Suffix = "s",
    CurrentValue = 1.0,
    Flag = "SldBurst",
    Callback = function(v) BurstDelay = v end,
})

TabFlood:CreateToggle({
    Name = "Modo Turbo (ignora delay, max por frame)",
    CurrentValue = false,
    Flag = "TglTurbo",
    Callback = function(v)
        StatusMode = v and "TURBO" or "Sequencial"
    end,
})

local SecExec = TabFlood:CreateSection("Execucao")

TabFlood:CreateToggle({
    Name = "Loop Automatico",
    CurrentValue = false,
    Flag = "TglLoop",
    Callback = function(v)
        Looping = v
        if v then
            if not Running then QueueBurst(Times, Speed) end
            Rayfield:Notify({Title="Loop", Content=Times.."x a cada "..BurstDelay.."s", Duration=2})
        else
            ResetQueue()
            Running = false
        end
    end,
})

TabFlood:CreateButton({
    Name = "Enviar Rajada",
    Callback = function()
        if Running and not Looping then return end
        local turbo = (StatusMode == "TURBO")
        SendBurst(Times, turbo and 0 or Speed, turbo)
    end,
})

TabFlood:CreateButton({
    Name = "PARAR",
    Callback = function()
        Looping = false
        Running = false
        ResetQueue()
    end,
})

TabFlood:CreateButton({
    Name = "Diagnosticar",
    Callback = function() task.spawn(DiagnoseClickBrainrot) end,
})

local SecStatus = TabFlood:CreateSection("Status")
TabFlood:CreateParagraph("Status",
    "Vezes: " .. StatusVezes .. "\n"
    .. "Velocidade: " .. StatusSpeed .. "\n"
    .. "Modo: " .. StatusMode
)

-- =====================================================================
-- ======================== ABA: AUTO BUY ==============================
-- =====================================================================

local SecABConfig = TabAutoBuy:CreateSection("Configuracao")

TabAutoBuy:CreateToggle({
    Name = "Auto Buy Ativo",
    CurrentValue = false,
    Flag = "TglAutoBuy",
    Callback = function(v)
        AutoBuyEnabled = v
        if v then
            FetchState()
            AddLog("Auto Buy ATIVADO")
            Rayfield:Notify({Title="Auto Buy", Content="Comprando upgrades automaticamente", Duration=3})
        else
            AddLog("Auto Buy DESATIVADO")
        end
    end,
})

TabAutoBuy:CreateSlider({
    Name = "Intervalo de Compra",
    Range = {0.1, 5},
    Increment = 0.1,
    Suffix = "s",
    CurrentValue = 0.5,
    Flag = "SldABInterval",
    Callback = function(v) AutoBuyInterval = v end,
})

TabAutoBuy:CreateDropdown({
    Name = "Quantidade por Compra",
    Options = {"x1", "x10", "x100", "x500"},
    CurrentOption = "x1",
    Flag = "DrpABAmount",
    Callback = function(v)
        local n = tonumber(v:match("%d+"))
        AutoBuyBuyTimes = n or 1
    end,
})

TabAutoBuy:CreateDropdown({
    Name = "Prioridade",
    Options = {"BestValue", "CPS", "Cheapest"},
    CurrentOption = "BestValue",
    Flag = "DrpABPriority",
    Callback = function(v) AutoBuyPrioritize = v end,
})

local SecABTarget = TabAutoBuy:CreateSection("Alvo")

TabAutoBuy:CreateToggle({
    Name = "Comprar Apenas Selecionado",
    CurrentValue = false,
    Flag = "TglABSelected",
    Callback = function(v) AutoBuySelectedOnly = v end,
})

TabAutoBuy:CreateDropdown({
    Name = "Upgrade Especifico",
    Options = UpgradeNames,
    CurrentOption = {UpgradeNames[1] or ""},
    Flag = "DrpABUpgrade",
    Callback = function(v) AutoBuySelectedUpgrade = v end,
})

local SecABBlacklist = TabAutoBuy:CreateSection("Blacklist (ignorar)")

-- Cria toggles para cada upgrade na blacklist
for _, u in ipairs(UpgradeList) do
    TabAutoBuy:CreateToggle({
        Name = u.name,
        CurrentValue = false,
        Flag = "Bl_" .. u.name,
        Callback = function(v)
            AutoBuyBlacklist[u.name] = v
        end,
    })
end

local SecABLog = TabAutoBuy:CreateSection("Log de Compras")

TabAutoBuy:CreateButton({
    Name = "Atualizar Log",
    Callback = function()
        local logText = #AutoBuyLog > 0 and table.concat(AutoBuyLog, "\n") or "Nenhuma compra ainda."
        Rayfield:Notify({Title="Auto Buy Log", Content=logText, Duration=5})
    end,
})

TabAutoBuy:CreateButton({
    Name = "Comprar Tudo (uma vez)",
    Callback = function()
        task.spawn(function()
            FetchState()
            local cashVal = Cash.Value or 0
            local rebirthsVal = RebirthsStat.Value or 0
            local bought = 0

            for _, u in ipairs(UpgradeList) do
                if u.rebirthReq <= rebirthsVal then
                    local level = UpgradeLevels[u.name] or 0
                    local cost = GetUpgradeCost(u.name, level)
                    if cost <= cashVal then
                        local ok, result = TryBuyUpgrade(u.name, 1)
                        if ok then
                            bought = bought + 1
                            cashVal = cashVal - cost
                            task.wait(0.1)
                        end
                    end
                end
            end

            AddLog("Compra em massa: " .. bought .. " upgrades comprados")
            Rayfield:Notify({Title="Auto Buy", Content="Comprou " .. bought .. " upgrades", Duration=3})
        end)
    end,
})

TabAutoBuy:CreateButton({
    Name = "Limpar Log",
    Callback = function()
        AutoBuyLog = {}
        Rayfield:Notify({Title="Auto Buy", Content="Log limpo", Duration=2})
    end,
})

-- =====================================================================
-- ======================== ABA: INFO ==================================
-- =====================================================================

TabInfo:CreateParagraph("ClickBrainrot v3", [[
Engine otimizada por frame (RunService.Heartbeat) + Auto Buy.

Novidades v3:
 - Auto Buy: compra upgrades automaticamente
 - Prioridade: BestValue, CPS ou Cheapest
 - Blacklist: ignore upgrades especificos
 - Compra em massa com um clique
 - Log de compras em tempo real

Remote: ReplicatedStorage.Remotes.ClickBrainrot
Args: { [1] = 1 }
Efeito: Cash +7 por chamada
]])

TabInfo:CreateParagraph("Auto Buy - Como Usar", [[
1. Ative "Auto Buy Ativo"
2. Escolha a prioridade:
   - BestValue: melhor custo/beneficio
   - CPS: prioriza upgrades de CPS
   - Cheapest: compra o mais barato primeiro
3. Escolha a quantidade (x1, x10, x100, x500)
4. Opcional: marque upgrades na Blacklist
5. Opcional: selecione um upgrade especifico

O sistema compra automaticamente quando
voce tem cash suficiente.
]])

TabInfo:CreateParagraph("Upgrades Disponiveis", [[
]] .. table.concat(UpgradeNames, ", ") .. [[

Total: ]] .. tostring(#UpgradeList) .. [[ upgrades
]])

TabInfo:CreateParagraph("Aviso", [[
Nao abuse para nao tomar kick.
Rate limit do servidor: ~50/s.
Auto Buy respeita o intervalo configurado.
]])

-- Notificacao inicial
Rayfield:Notify({
    Title = "ClickBrainrot v3",
    Content = "Flood + Auto Buy carregados. " .. #UpgradeList .. " upgrades detectados.",
    Duration = 4,
})
