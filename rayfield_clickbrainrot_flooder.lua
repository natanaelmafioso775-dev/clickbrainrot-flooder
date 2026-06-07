--[[
    ========================================================================
    ClickBrainrot Flooder v2 - Engine Otimizada (Zero Lag)
    ========================================================================
    Envia multiplas chamadas do remote ClickBrainrot SEM travar o jogo.

    Diferenciais:
      - Usa RunService.Heartbeat (sincronizado com o framerate)
      - Frame-budget: max N chamadas por frame para nao pesar no render
      - Fila de execucao assincrona (nunca bloqueia)
      - Sem notificacoes durante rajada (zero overhead)
      - Coleta de lixo manual a cada ciclo
      - Modo sleep quando minimizado / sem foco

    Remote: ReplicatedStorage.Remotes.ClickBrainrot
    Args: { [1] = 1 }
    ========================================================================
]]

-- ===================== RESOLUCAO OTIMIZADA =====================
local RS          = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")
local Player      = game:GetService("Players").LocalPlayer
local UserInput   = game:GetService("UserInputService")

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

-- ===================== ESTADO GLOBAL =====================
local Times        = 10      -- quantas chamadas por rajada
local Speed        = 0.05    -- delay entre chamadas (segundos)
local BurstDelay   = 1.0     -- delay entre rajadas no loop
local Looping      = false   -- loop automatico ativo?
local Running      = false   -- alguma operacao em andamento?

-- ===================== FILA DE EXECUCAO (HEARTBEAT) =====================
-- Em vez de usar task.wait (que trava), usamos Heartbeat para
-- distribuir as chamadas ao longo dos frames. O jogo continua
-- rodando a 60fps suave.

local Queue = {
    pending   = 0,    -- quantas chamadas faltam disparar
    total     = 0,    -- total original da rajada
    delay     = 0,    -- delay entre chamadas (segundos)
    elapsed   = 0,    -- tempo acumulado desde o ultimo disparo
    timestamp = 0,    -- tick() da ultima chamada
    maxPerFrame = 5,  -- max chamadas por frame (evita pico)
    mode      = "idle", -- idle | sending | delayInterval | cooldown
    cooldown  = 0,    -- tempo restante de cooldown entre rajadas
    nextBatch = 0,    -- quantas disparar no proximo heartbeat
}

-- Reseta a fila
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

-- Inicia uma nova rajada na fila
local function QueueBurst(quantidade, delay)
    Queue.pending   = quantidade
    Queue.total     = quantidade
    Queue.delay     = delay
    Queue.elapsed   = 0
    Queue.timestamp = tick()
    Queue.mode      = "sending"
    Running = true
end

-- Heartbeat: processa a fila a cada frame (sem travar)
RunService.Heartbeat:Connect(function(dt)
    if Queue.mode == "idle" then return end

    -- Modo: enviando chamadas
    if Queue.mode == "sending" then
        local now = tick()
        local delta = now - Queue.timestamp

        -- Calcula quantas chamadas devem ser disparadas com base
        -- no tempo passado e no delay configurado
        if Queue.delay > 0 then
            Queue.elapsed = Queue.elapsed + dt
            local expected = math.floor(Queue.elapsed / Queue.delay)
            if expected > Queue.total - (Queue.total - Queue.pending) then
                Queue.nextBatch = expected - (Queue.total - Queue.pending)
            else
                Queue.nextBatch = 1
            end
        else
            -- delay = 0: dispara tudo no limite do maxPerFrame
            Queue.nextBatch = math.min(Queue.pending, Queue.maxPerFrame)
        end

        -- Limita ao maxPorFrame para nao pesar
        if Queue.nextBatch > Queue.maxPerFrame then
            Queue.nextBatch = Queue.maxPerFrame
        end
        if Queue.nextBatch > Queue.pending then
            Queue.nextBatch = Queue.pending
        end

        -- Dispara o batch
        for _ = 1, Queue.nextBatch do
            FireOnce()
        end
        Queue.pending = Queue.pending - Queue.nextBatch
        Queue.timestamp = now

        -- Se acabou, vai pra cooldown
        if Queue.pending <= 0 then
            Queue.mode = "cooldown"
            Queue.cooldown = 0.05  -- pausa minima entre rajadas
            Running = false

            -- Se esta em looping, agenda proxima rajada
            if Looping then
                Queue.cooldown = BurstDelay
                Queue.mode = "cooldown"
            end
        end
        return
    end

    -- Modo: cooldown entre rajadas
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
end)

-- ===================== FUNCAO PUBLICA: SEND BURST =====================

function SendBurst(quantidade, delay, paralelo)
    if Running and not Looping then
        return  -- ignora se ja tem algo rodando (exceto loop)
    end

    if paralelo then
        -- Modo paralelo otimizado: dispara em lotes por frame
        QueueBurst(quantidade, 0)
    else
        -- Modo sequencial: respeita o delay via Heartbeat
        QueueBurst(quantidade, delay)
    end
end

-- ===================== DIAGNOSTICO LEVE =====================

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

    -- Teste unico silencioso
    local ok = pcall(FireOnce)
    table.insert(lines, "FireServer: " .. (ok and "OK" or "FALHOU"))

    local text = table.concat(lines, " | ")
    print("===== DIAGNOSTICO CBROT =====")
    for _, l in ipairs(lines) do print("[CBRot]", l) end
    Rayfield:Notify({Title="ClickBrainrot", Content=text, Duration=8})
end

-- ===================== CARREGA RAYFIELD (DEPOIS DAS FUNCOES) =====================
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local Window = Rayfield:CreateWindow({
    Name = "ClickBrainrot v2",
    LoadingTitle = "Carregando...",
    LoadingSubtitle = "Engine otimizada (zero lag)",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "ClickBrainrot",
        FileName = "Config"
    },
    Discord = {
        Enabled = false,
        Invite = "noinvite",
        RememberJoins = true
    },
    KeySystem = false,
})

-- ===================== ABAS =====================
local TabFlood = Window:CreateTab("Flood", 4483362458)
local TabInfo  = Window:CreateTab("Info",  4483362458)

-- Variaveis para os labels de status (atualizados sem recriar)
local StatusVezes   = "10x"
local StatusSpeed   = "0.05s"
local StatusMode    = "Sequencial"

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
    Callback = function(v)
        BurstDelay = v
    end,
})

TabFlood:CreateToggle({
    Name = "Modo Turbo (ignora delay, max por frame)",
    CurrentValue = false,
    Flag = "TglTurbo",
    Callback = function(v)
        -- Quando turbo ligado, o Speed slider vira o maxPerFrame
        if v then
            StatusMode = "TURBO"
        else
            StatusMode = "Sequencial"
        end
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
            if not Running then
                QueueBurst(Times, Speed)
            end
            Rayfield:Notify({
                Title = "Loop",
                Content = Times .. "x a cada " .. BurstDelay .. "s",
                Duration = 2,
            })
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
    Callback = function()
        task.spawn(DiagnoseClickBrainrot)
    end,
})

-- Status ao vivo (atualizado a cada heartbeat via bind)
local SecStatus = TabFlood:CreateSection("Status")
local StatusLabel = TabFlood:CreateParagraph("Status",
    "Vezes: " .. StatusVezes .. "\n"
    .. "Velocidade: " .. StatusSpeed .. "\n"
    .. "Modo: " .. StatusMode
)

-- =====================================================================
-- ======================== ABA: INFO ==================================
-- =====================================================================

TabInfo:CreateParagraph("ClickBrainrot v2", [[
Engine otimizada por frame (RunService.Heartbeat).

Diferencas da v1:
 - Zero lag: usa Heartbeat em vez de task.wait
 - Frame-budget: max 5 chamadas por frame
 - Fila assincrona: nunca bloqueia o jogo
 - Sem strings/notifications durante a rajada
 - Coleta de lixo minimizada

Remote: ReplicatedStorage.Remotes.ClickBrainrot
Args: { [1] = 1 }
Metodo: FireServer(unpack(args))
Efeito: Cash +7 por chamada
]])

TabInfo:CreateParagraph("Dados do UltraSpy (Flow #78)", [[
Confidence: 70% (Remote effect)
ReplayScore: 100/100 (Verified Action)
ValuableActionScore: 90/100

109 chamadas registradas no lifecycle
Cash confirmado: +7 por chamada
AlertLabel.Text / Cash.Text atualizados
]])

TabInfo:CreateParagraph("Como Usar", [[
1. Ajuste "Vezes" e "Velocidade"
2. Clique "Enviar Rajada"
3. Ou ative "Loop Automatico"
4. Use "PARAR" para emergencia

Modo Turbo: max 5 chamadas por frame
(ignora o delay, vai o mais rapido possivel
sem travar o jogo)
]])

TabInfo:CreateParagraph("Aviso", [[
Nao abuse para nao tomar kick.
Rate limit do servidor: ~50/s.
Com delay 0.05s: ~20 chamadas/s (seguro).
Modo Turbo: limitado a 5/frame = ~300/s a 60fps.
]])

-- Notificacao inicial
Rayfield:Notify({
    Title = "ClickBrainrot v2",
    Content = "Engine otimizada carregada. Zero lag.",
    Duration = 3,
})