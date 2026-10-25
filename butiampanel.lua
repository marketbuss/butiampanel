--=====================================================================
--  butiampanel v1.0.0
--  Mod menu Roblox adaptatif — un seul script, n'importe quel jeu.
--
--  Ce qui s'adapte tout seul :
--    - lit PlaceId / GameId / nom du jeu et charge un profil
--    - scanne ReplicatedStorage et classe les remotes (farm / combat /
--      economie / social) puis les branche sur l'onglet Farm
--    - cale les valeurs par defaut (vitesse, saut, ESP, equipes)
--    - memorise les points de teleport et les remotes utilises par jeu
--      dans butiampanel/config.lua
--
--  Executeurs : Delta / Fluxus / Codex / Arceus / Wave / Synapse / desktop.
--  Sans Drawing : l'ESP retombe sur Highlight + BillboardGui.
--  Sans writefile : la config reste en memoire pour la session.
--
--  Touche du menu : RightShift (rebindable, onglet Config).
--=====================================================================

local Panel = {}
Panel.Version = "1.0.0"
Panel.Name = "butiampanel"
Panel.Flags = {}

--=====================================================================
--  0. SERVICES
--=====================================================================
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local UIS          = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting     = game:GetService("Lighting")
local TeleportSvc  = game:GetService("TeleportService")
local GuiService   = game:GetService("GuiService")
local VirtualUser  = game:GetService("VirtualUser")
local Teams        = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst   = game:GetService("ReplicatedFirst")
local MarketplaceService = game:GetService("MarketplaceService")

local LP = Players.LocalPlayer

--=====================================================================
--  1. SHIM EXECUTEUR
--=====================================================================
local function grabEnv()
    local ok, g = pcall(function()
        if type(getgenv) == "function" then return getgenv() end
        return nil
    end)
    if ok and type(g) == "table" then return g end
    return _G
end

local GENV = grabEnv()

local function ex(name)
    local fn = rawget(GENV, name)
    if type(fn) == "function" then return fn end
    local ok, v = pcall(function() return _G[name] end)
    if ok and type(v) == "function" then return v end
    return nil
end

local CAP = {
    writefile  = ex("writefile"),
    readfile   = ex("readfile"),
    isfile     = ex("isfile"),
    makefolder = ex("makefolder"),
    isfolder   = ex("isfolder"),
    delfile    = ex("delfile"),
    setclipboard = ex("setclipboard") or ex("toclipboard"),
    protectgui = ex("protectgui"),
    gethui     = ex("gethui"),
    setfpscap  = ex("setfpscap"),
}

local EXECUTOR = "unknown"
do
    local identify = ex("identifyexecutor") or ex("getexecutorname")
    if identify then
        local ok, name = pcall(identify)
        if ok and type(name) == "string" and name ~= "" then
            EXECUTOR = name
        end
    end
end

local DrawingLib = rawget(GENV, "Drawing")
if type(DrawingLib) ~= "table" then
    local ok, d = pcall(function() return Drawing end)
    if ok and type(d) == "table" then DrawingLib = d end
end

local HAS_DRAWING = type(DrawingLib) == "table" and type(DrawingLib.new) == "function"

-- re-execution : on degage l'instance precedente au lieu d'empiler deux panels
if type(GENV.butiampanel) == "table" and type(GENV.butiampanel.Unload) == "function" then
    pcall(GENV.butiampanel.Unload)
end

--=====================================================================
--  2. UTILS
--=====================================================================
local function clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function round(n, step)
    step = step or 1
    if step <= 0 then return n end
    return math.floor(n / step + 0.5) * step
end

local function jitter(base, pct)
    pct = pct or 0.15
    return base * (1 + (math.random() * 2 - 1) * pct)
end

local function character()
    local p = Players.LocalPlayer
    return p and p.Character
end

local function humanoid()
    local c = character()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function rootPart()
    local c = character()
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c.PrimaryPart
end

local function headPart()
    local c = character()
    return c and c:FindFirstChild("Head")
end

local function setProp(obj, key, value)
    pcall(function() obj[key] = value end)
end

local Notify  -- forward : assigne apres la GUI

--=====================================================================
--  3. SERIALISATION + STOCKAGE
--=====================================================================
local function serialize(value)
    local t = type(value)
    if t == "string" then
        return string.format("%q", value)
    elseif t == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "0"
        end
        return string.format("%.14g", value)
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "table" then
        local out = { "{" }
        for k, v in pairs(value) do
            local kt = type(k)
            if kt == "string" then
                out[#out + 1] = "[" .. string.format("%q", k) .. "]="
            elseif kt == "number" then
                out[#out + 1] = "[" .. string.format("%d", k) .. "]="
            else
                continue
            end
            out[#out + 1] = serialize(v)
            out[#out + 1] = ","
        end
        out[#out + 1] = "}"
        return table.concat(out)
    end
    return "nil"
end

local function deserialize(src)
    if type(src) ~= "string" or src == "" then return nil end
    local compile = loadstring or load
    if type(compile) ~= "function" then return nil end
    local chunk = compile("return " .. src)
    if not chunk then return nil end
    local ok, result = pcall(chunk)
    if ok and type(result) == "table" then return result end
    return nil
end

local FS = {
    dir = "butiampanel",
    file = "butiampanel/config.lua",
    ready = (CAP.writefile and CAP.readfile) ~= nil,
}

local function ensureDir()
    if not FS.ready then return false end
    if CAP.makefolder and CAP.isfolder then
        local ok, exists = pcall(CAP.isfolder, FS.dir)
        if not (ok and exists) then
            pcall(CAP.makefolder, FS.dir)
        end
    end
    return true
end

local function readConfig()
    if not FS.ready then return {} end
    local ok, exists = pcall(CAP.isfile, FS.file)
    if not (ok and exists) then return {} end
    local readOk, body = pcall(CAP.readfile, FS.file)
    if not readOk or type(body) ~= "string" then return {} end
    return deserialize(body) or {}
end

local function writeConfig(data)
    if not ensureDir() then return false end
    local ok = pcall(CAP.writefile, FS.file, "return " .. serialize(data))
    return ok
end

--=====================================================================
--  4. PROFILS DE JEU
--      seeds = connus, learned = appris en session et persistes.
--      Les IDs bougent quand un jeu se re-upload : le mot-cle couvre.
--=====================================================================
local SEEDS = {
    [920587237] = {
        name = "Adopt Me!",
        keywords = { "adopt me" },
        defaults = { walk = 20, jump = 55, espDistance = 900, teamCheck = false },
        notes = "Economie pets et trades. Remotes classes automatiquement.",
    },
    [2753915549] = {
        name = "Blox Fruits",
        keywords = { "blox fruits" },
        defaults = { walk = 30, jump = 60, espDistance = 1500, teamCheck = false },
        notes = "Combat + quetes. L'ESP reste utile en mer.",
    },
    [17625359962] = {
        name = "Grow a Garden",
        keywords = { "grow a garden" },
        defaults = { walk = 24, jump = 55, espDistance = 700, teamCheck = false },
        notes = "Boucle plant / harvest / sell : a brancher dans Farm.",
    },
}

local gameNameCache = nil
local gameNameChecked = false

local function resolveGameName()
    if gameNameChecked then return gameNameCache end
    gameNameChecked = true
    local ok, info = pcall(function()
        return MarketplaceService:GetProductInfo(game.PlaceId)
    end)
    if ok and type(info) == "table" and type(info.Name) == "string" and info.Name ~= "" then
        gameNameCache = info.Name
        return gameNameCache
    end
    local fallback = game.Name
    if type(fallback) == "string" and fallback ~= "" and fallback ~= "Place" then
        gameNameCache = fallback
    end
    return gameNameCache
end

local function seedFor(placeId, name)
    local direct = SEEDS[placeId]
    if direct then return direct end
    if type(name) == "string" and name ~= "" then
        local lower = string.lower(name)
        for _, seed in pairs(SEEDS) do
            for _, keyword in ipairs(seed.keywords or {}) do
                if string.find(lower, keyword, 1, true) then
                    return seed
                end
            end
        end
    end
    return nil
end

Panel.Profile = {
    id = game.PlaceId,
    name = "Universal",
    kind = "fallback",
    defaults = { walk = 16, jump = 50, espDistance = 1200, teamCheck = true },
    points = {},
    remotes = {},
    notes = "",
}

local Learned = {}   -- [placeId] = { points = {...}, remotes = {...}, name = "..." }

local function profileForPlace(name)
    local placeId = game.PlaceId
    local learned = Learned[placeId] or {}
    local seed = seedFor(placeId, name)

    local defaults
    if seed and seed.defaults then
        defaults = {
            walk = seed.defaults.walk or 16,
            jump = seed.defaults.jump or 50,
            espDistance = seed.defaults.espDistance or 1200,
            teamCheck = seed.defaults.teamCheck,
        }
    else
        defaults = {
            walk = 16,
            jump = 50,
            espDistance = 1200,
            teamCheck = (#Teams:GetTeams() > 0),
        }
    end
    if defaults.teamCheck == nil then
        defaults.teamCheck = (#Teams:GetTeams() > 0)
    end

    return {
        id = placeId,
        name = (seed and seed.name) or learned.name or name or "Universal",
        kind = seed and "registry" or (learned.name and "learned" or "fallback"),
        defaults = defaults,
        points = learned.points or {},
        remotes = learned.remotes or {},
        notes = (seed and seed.notes) or "",
        keywords = seed and seed.keywords or {},
    }
end

--=====================================================================
--  5. SCAN DE REMOTES + CLASSEMENT
--=====================================================================
local TAG_RULES = {
    farm    = { "collect", "claim", "harvest", "reward", "give", "daily", "spin",
                "plant", "sell", "egg", "hatch", "quest", "cash", "coin", "gem",
                "pet", "drop", "pickup", "water", "grow" },
    combat  = { "damage", "hit", "attack", "combat", "swing", "shoot", "fire",
                "sword", "punch", "skill", "mob", "boss" },
    economy = { "buy", "purchase", "shop", "trade", "gift", "inventory", "equip" },
    social  = { "chat", "party", "friend", "message", "whisper" },
}

-- ordre d'affichage des remotes dans le dropdown : le farm d'abord
local REMOTE_RANK = { farm = 1, economy = 2, combat = 3, social = 4, autre = 5 }
local REMOTE_OPTION_LIMIT = 300   -- au-dela, le menu devient une liste de 2000 boutons

local function tagFor(name)
    local lower = string.lower(name)
    local best, bestScore = "autre", 0
    for tag, words in pairs(TAG_RULES) do
        for _, word in ipairs(words) do
            local score = 0
            if lower == word then
                score = 3
            elseif string.find(lower, word, 1, true) then
                score = 2
            end
            if score > bestScore then
                best, bestScore = tag, score
            end
        end
    end
    return best
end

local function collectRemotes(budget)
    budget = budget or 15000
    local out, seen = {}, {}
    local queue = { ReplicatedStorage, ReplicatedFirst }
    local cursor = 1

    -- parcours en largeur borne : GetDescendants() materialise tout l'arbre d'un coup
    while cursor <= #queue and budget > 0 do
        local node = queue[cursor]
        cursor = cursor + 1
        local ok, children = pcall(function() return node:GetChildren() end)
        if ok and type(children) == "table" then
            for _, child in ipairs(children) do
                budget = budget - 1
                if budget <= 0 then break end
                if child:IsA("RemoteEvent") or child:IsA("RemoteFunction") then
                    if not seen[child] then
                        seen[child] = true
                        out[#out + 1] = {
                            inst = child,
                            path = child:GetFullName(),
                            class = child.ClassName,
                            tag = tagFor(child.Name),
                        }
                    end
                else
                    queue[#queue + 1] = child
                end
            end
        end
    end

    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

local RemoteIndex = {}   -- path -> Instance

local function indexRemotes(list)
    RemoteIndex = {}
    for _, entry in ipairs(list) do
        RemoteIndex[entry.path] = entry.inst
    end
end

--=====================================================================
--  6. THEME + HELPERS GUI
--=====================================================================
local P = {
    bg        = Color3.fromRGB(9, 10, 15),
    panel     = Color3.fromRGB(15, 17, 24),
    card      = Color3.fromRGB(22, 25, 34),
    cardAlt   = Color3.fromRGB(29, 33, 44),
    stroke    = Color3.fromRGB(44, 49, 64),
    text      = Color3.fromRGB(235, 239, 247),
    muted     = Color3.fromRGB(138, 147, 168),
    accent    = Color3.fromRGB(157, 255, 94),
    accentDim = Color3.fromRGB(78, 140, 46),
    danger    = Color3.fromRGB(255, 92, 92),
    info      = Color3.fromRGB(120, 190, 255),
}

local function new(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        inst[k] = v
    end
    if parent then inst.Parent = parent end
    return inst
end

local function corner(inst, r)
    return new("UICorner", { CornerRadius = UDim.new(0, r or 10) }, inst)
end

local function stroke(inst, color, thickness, transparency)
    return new("UIStroke", {
        Color = color or P.stroke,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, inst)
end

local function label(parent, text, size, color, font, textSize, xAlign)
    return new("TextLabel", {
        Size = size or UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = text or "",
        TextColor3 = color or P.text,
        Font = font or Enum.Font.GothamMedium,
        TextSize = textSize or 13,
        TextXAlignment = xAlign or Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, parent)
end

local function isPress(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

local function mousePos()
    local inset = GuiService:GetGuiInset()
    return UIS:GetMouseLocation() - inset
end

--=====================================================================
--  7. ROOT GUI
--=====================================================================
local function makeRoot()
    local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
    local candidates = {}
    if CAP.gethui then
        pcall(function()
            local hui = CAP.gethui()
            if hui then table.insert(candidates, hui) end
        end)
    end
    table.insert(candidates, playerGui)

    local gui = new("ScreenGui", {
        Name = "\0bp" .. tostring(math.random(100000, 999999)),
        ResetOnSpawn = false,
        IgnoreGuiInset = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 999,
    })

    if CAP.protectgui then
        pcall(CAP.protectgui, gui)
    end

    gui.Parent = candidates[1]
    if not gui.Parent then
        gui.Parent = playerGui
    end

    return gui
end

local Gui = makeRoot()

local Root = new("Frame", {
    Name = "window",
    Size = UDim2.fromOffset(640, 430),
    Position = UDim2.new(0.5, -320, 0.5, -215),
    BackgroundColor3 = P.bg,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, Gui)
corner(Root, 12)
stroke(Root, P.stroke, 1)

local TopBar = new("Frame", {
    Name = "topbar",
    Size = UDim2.new(1, 0, 0, 40),
    BackgroundColor3 = P.panel,
    BorderSizePixel = 0,
}, Root)

local Dot = new("Frame", {
    Size = UDim2.fromOffset(8, 8),
    Position = UDim2.fromOffset(16, 16),
    BackgroundColor3 = P.accent,
    BorderSizePixel = 0,
}, TopBar)
corner(Dot, 4)

label(TopBar, "butiampanel", UDim2.new(0, 180, 1, 0), P.text, Enum.Font.GothamBold, 14)
    .Position = UDim2.fromOffset(32, 0)

local ProfileChip = new("TextLabel", {
    Size = UDim2.new(0, 220, 0, 20),
    Position = UDim2.new(1, -340, 0.5, -10),
    BackgroundColor3 = P.card,
    BackgroundTransparency = 0.15,
    Text = "detection...",
    TextColor3 = P.muted,
    Font = Enum.Font.GothamMedium,
    TextSize = 11,
    TextTruncate = Enum.TextTruncate.AtEnd,
}, TopBar)
corner(ProfileChip, 6)
stroke(ProfileChip, P.stroke, 1)

local function topButton(text, xOffset, color, onClick)
    local btn = new("TextButton", {
        Size = UDim2.fromOffset(24, 24),
        Position = UDim2.new(1, xOffset, 0.5, -12),
        BackgroundColor3 = P.card,
        Text = text,
        TextColor3 = color or P.muted,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        AutoButtonColor = false,
        BorderSizePixel = 0,
    }, TopBar)
    corner(btn, 6)
    btn.MouseEnter:Connect(function() btn.BackgroundColor3 = P.cardAlt end)
    btn.MouseLeave:Connect(function() btn.BackgroundColor3 = P.card end)
    btn.Activated:Connect(onClick)
    return btn
end

local CloseBtn = topButton("x", -34, P.danger, function()
    Panel.Unload()
end)
local MinBtn = topButton("-", -64, P.muted, function() end)

local minimized = false
MinBtn.Activated:Connect(function()
    minimized = not minimized
    if minimized then
        Root.Size = UDim2.fromOffset(640, 40)
        Rail.Visible = false
        Content.Visible = false
        MinBtn.Text = "+"
    else
        Root.Size = UDim2.fromOffset(640, 430)
        Rail.Visible = true
        Content.Visible = true
        MinBtn.Text = "-"
    end
end)

-- rail
local Rail = new("Frame", {
    Size = UDim2.new(0, 140, 1, -50),
    Position = UDim2.fromOffset(0, 45),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
}, Root)

-- contenu
local Content = new("ScrollingFrame", {
    Size = UDim2.new(1, -152, 1, -50),
    Position = UDim2.fromOffset(145, 45),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = P.stroke,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    ElasticBehavior = Enum.ElasticBehavior.Never,
}, Root)

new("UIPadding", { PaddingRight = UDim.new(0, 8) }, Content)

-- drag de fenetre
local dragging, dragStart, dragOrigin = false, nil, nil
TopBar.InputBegan:Connect(function(input)
    if isPress(input) then
        dragging = true
        dragStart = mousePos()
        dragOrigin = Root.Position
    end
end)
UIS.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end
    local delta = mousePos() - dragStart
    Root.Position = UDim2.new(
        dragOrigin.X.Scale,
        dragOrigin.X.Offset + delta.X,
        dragOrigin.Y.Scale,
        dragOrigin.Y.Offset + delta.Y
    )
end)
UIS.InputEnded:Connect(function(input)
    if isPress(input) then dragging = false end
end)

--=====================================================================
--  8. NOTIFICATIONS
--=====================================================================
local NotifHolder = new("Frame", {
    Size = UDim2.fromOffset(260, 300),
    Position = UDim2.new(1, -272, 0, 48),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
}, Gui)
new("UIListLayout", {
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
}, NotifHolder)

local notifOrder = 0
Notify = function(title, body, color)
    notifOrder = notifOrder + 1
    local card = new("Frame", {
        Size = UDim2.new(1, 0, 0, 52),
        BackgroundColor3 = P.card,
        BackgroundTransparency = 0.05,
        BorderSizePixel = 0,
        LayoutOrder = notifOrder,
    }, NotifHolder)
    corner(card, 8)
    stroke(card, color or P.accent, 1, 0.2)

    local bar = new("Frame", {
        Size = UDim2.new(0, 3, 1, -12),
        Position = UDim2.fromOffset(6, 6),
        BackgroundColor3 = color or P.accent,
        BorderSizePixel = 0,
    }, card)
    corner(bar, 2)

    label(card, title, UDim2.new(1, -24, 0, 18), P.text, Enum.Font.GothamBold, 12)
        .Position = UDim2.fromOffset(16, 8)
    local sub = label(card, body or "", UDim2.new(1, -24, 0, 20), P.muted, Enum.Font.GothamMedium, 11)
    sub.Position = UDim2.fromOffset(16, 26)
    sub.TextWrapped = true

    task.delay(3.5, function()
        if not card.Parent then return end
        TweenService:Create(card, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
        task.wait(0.3)
        card:Destroy()
    end)
end

--=====================================================================
--  9. WIDGETS
--=====================================================================
local Controls = {}
local Pages = {}
local ActivePage = nil
local TabButtons = {}
local PageOrder = 0

local function register(key, ctrl)
    if key then Controls[key] = ctrl end
    return ctrl
end

local function addPage(name)
    local page = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Visible = false,
        BorderSizePixel = 0,
    }, Content)
    new("UIListLayout", {
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, page)
    new("UIPadding", {
        PaddingTop = UDim.new(0, 6),
        PaddingBottom = UDim.new(0, 10),
        PaddingLeft = UDim.new(0, 6),
        PaddingRight = UDim.new(0, 6),
    }, page)

    local btn = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundColor3 = P.card,
        BackgroundTransparency = 1,
        Text = name,
        TextColor3 = P.muted,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        AutoButtonColor = false,
        BorderSizePixel = 0,
        LayoutOrder = PageOrder,
    }, Rail)
    PageOrder = PageOrder + 1
    new("UIPadding", { PaddingLeft = UDim.new(0, 30), PaddingTop = UDim.new(0, 0) }, btn)

    local accentBar = new("Frame", {
        Size = UDim2.new(0, 3, 0, 14),
        Position = UDim2.new(0, 12, 0.5, -7),
        BackgroundColor3 = P.accent,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, btn)
    corner(accentBar, 2)

    local function select()
        for otherName, other in pairs(Pages) do
            other.page.Visible = (otherName == name)
        end
        ActivePage = name
        for otherName, otherBtn in pairs(TabButtons) do
            local active = otherName == name
            otherBtn.btn.TextColor3 = active and P.text or P.muted
            otherBtn.btn.BackgroundColor3 = active and P.card or P.card
            otherBtn.btn.BackgroundTransparency = active and 0 or 1
            otherBtn.bar.BackgroundTransparency = active and 0 or 1
        end
    end

    btn.Activated:Connect(select)
    btn.MouseEnter:Connect(function()
        if ActivePage ~= name then btn.BackgroundTransparency = 0.5 end
    end)
    btn.MouseLeave:Connect(function()
        if ActivePage ~= name then btn.BackgroundTransparency = 1 end
    end)

    Pages[name] = { page = page, select = select }
    TabButtons[name] = { btn = btn, bar = accentBar }
    return page
end

-- rail layout
new("UIListLayout", {
    Padding = UDim.new(0, 3),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, Rail)
new("UIPadding", {
    PaddingLeft = UDim.new(0, 10),
    PaddingRight = UDim.new(0, 10),
    PaddingTop = UDim.new(0, 2),
}, Rail)

local function section(page, text)
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, page)
    local lbl = label(holder, string.upper(text), UDim2.new(1, 0, 1, 0), P.muted, Enum.Font.GothamBold, 10)
    lbl.Position = UDim2.fromOffset(2, 0)
    local line = new("Frame", {
        Size = UDim2.new(1, -4, 0, 1),
        Position = UDim2.new(0, 2, 1, -6),
        BackgroundColor3 = P.stroke,
        BorderSizePixel = 0,
        BackgroundTransparency = 0.4,
    }, holder)
    return holder
end

local function Toggle(page, text, key, default, onChange)
    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, page)

    label(row, text, UDim2.new(1, -60, 1, 0), P.text, Enum.Font.GothamMedium, 12)

    local sw = new("Frame", {
        Size = UDim2.fromOffset(38, 20),
        Position = UDim2.new(1, -42, 0.5, -10),
        BackgroundColor3 = P.stroke,
        BorderSizePixel = 0,
    }, row)
    corner(sw, 10)

    local knob = new("Frame", {
        Size = UDim2.fromOffset(16, 16),
        Position = UDim2.new(0, 2, 0.5, -8),
        BackgroundColor3 = P.text,
        BorderSizePixel = 0,
    }, sw)
    corner(knob, 8)
    stroke(knob, Color3.fromRGB(0, 0, 0), 1, 0.75)

    local state = default and true or false

    local function render()
        sw.BackgroundColor3 = state and P.accentDim or P.stroke
        knob.BackgroundColor3 = state and P.accent or P.text
        TweenService:Create(knob, TweenInfo.new(0.12), {
            Position = state and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8),
        }):Play()
    end

    local hit = new("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, row)
    hit.Activated:Connect(function()
        state = not state
        render()
        if onChange then onChange(state) end
    end)

    local ctrl = {
        set = function(v)
            state = v and true or false
            render()
            if onChange then onChange(state) end
        end,
        get = function() return state end,
    }
    render()
    register(key, ctrl)
    return ctrl
end

local function Slider(page, text, key, min, max, step, default, suffix, onChange)
    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 44),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, page)

    label(row, text, UDim2.new(1, -80, 0, 20), P.text, Enum.Font.GothamMedium, 12)
    local valueLabel = label(row, "", UDim2.new(0, 80, 0, 20), P.accent, Enum.Font.GothamMedium, 11,
        Enum.TextXAlignment.Right)
    valueLabel.Position = UDim2.new(1, -80, 0, 0)

    local track = new("Frame", {
        Size = UDim2.new(1, 0, 0, 4),
        Position = UDim2.new(0, 0, 0, 26),
        BackgroundColor3 = P.stroke,
        BorderSizePixel = 0,
    }, row)
    corner(track, 2)

    local fill = new("Frame", {
        Size = UDim2.new(0.5, 0, 1, 0),
        BackgroundColor3 = P.accent,
        BorderSizePixel = 0,
    }, track)
    corner(fill, 2)

    local knob = new("Frame", {
        Size = UDim2.fromOffset(12, 12),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        BackgroundColor3 = P.text,
        BorderSizePixel = 0,
    }, track)
    corner(knob, 6)
    stroke(knob, P.bg, 2)

    local hit = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 24),
        Position = UDim2.new(0, 0, 0, 16),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, row)

    local state = default or min
    local draggingSlider = false

    local function push(value, fire)
        value = clamp(round(value, step), min, max)
        state = value
        local alpha = (max == min) and 0 or (value - min) / (max - min)
        fill.Size = UDim2.new(alpha, 0, 1, 0)
        knob.Position = UDim2.new(alpha, 0, 0.5, 0)
        valueLabel.Text = tostring(value) .. (suffix or "")
        if fire and onChange then onChange(value) end
    end

    local function fromMouse()
        local absX = track.AbsolutePosition.X
        local width = track.AbsoluteSize.X
        if width <= 0 then return end
        local alpha = clamp((mousePos().X - absX) / width, 0, 1)
        push(min + alpha * (max - min), true)
    end

    hit.InputBegan:Connect(function(input)
        if isPress(input) then
            draggingSlider = true
            fromMouse()
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not draggingSlider then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            fromMouse()
        end
    end)
    UIS.InputEnded:Connect(function(input)
        if isPress(input) then draggingSlider = false end
    end)

    local ctrl = {
        set = function(v) push(tonumber(v) or min, true) end,
        get = function() return state end,
    }
    push(state, false)
    register(key, ctrl)
    return ctrl
end

local function Button(page, text, color, onClick)
    local btn = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundColor3 = P.card,
        Text = text,
        TextColor3 = color or P.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        AutoButtonColor = false,
        BorderSizePixel = 0,
    }, page)
    corner(btn, 7)
    stroke(btn, P.stroke, 1)
    btn.MouseEnter:Connect(function() btn.BackgroundColor3 = P.cardAlt end)
    btn.MouseLeave:Connect(function() btn.BackgroundColor3 = P.card end)
    btn.Activated:Connect(function()
        if onClick then
            local ok, err = pcall(onClick)
            if not ok then Notify("Erreur", tostring(err), P.danger) end
        end
    end)
    return btn
end

local function Dropdown(page, text, key, options, default, onChange)
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, page)

    label(holder, text, UDim2.new(1, -156, 1, 0), P.text, Enum.Font.GothamMedium, 12)

    local btn = new("TextButton", {
        Size = UDim2.new(0, 148, 0, 24),
        Position = UDim2.new(1, -148, 0.5, -12),
        BackgroundColor3 = P.card,
        Text = "",
        AutoButtonColor = false,
        BorderSizePixel = 0,
    }, holder)
    corner(btn, 6)
    stroke(btn, P.stroke, 1)

    local chosen = label(btn, "", UDim2.new(1, -22, 1, 0), P.text, Enum.Font.GothamMedium, 11)
    chosen.Position = UDim2.fromOffset(8, 0)
    local caret = label(btn, "v", UDim2.fromOffset(14, 14), P.muted, Enum.Font.GothamBold, 10)
    caret.Position = UDim2.new(1, -18, 0.5, -7)

    local state = default or (options[1] or "")
    local listFrame = nil
    local outsideConn = nil

    local function renderValue()
        chosen.Text = state
    end

    local function closeList()
        if outsideConn then
            outsideConn:Disconnect()
            outsideConn = nil
        end
        if listFrame then
            listFrame:Destroy()
            listFrame = nil
        end
    end

    local function pick(option)
        state = option
        renderValue()
        closeList()
        if onChange then onChange(option) end
    end

    local function openList()
        if #options == 0 then
            Notify("Liste vide", "Rien a selectionner pour l'instant.", P.info)
            return
        end

        local height = math.min(#options * 24 + 8, 200)
        local anchor = btn.AbsolutePosition
        local abs = UDim2.fromOffset(anchor.X, anchor.Y + 26)

        listFrame = new("Frame", {
            Size = UDim2.fromOffset(148, height),
            Position = abs,
            BackgroundColor3 = P.panel,
            BorderSizePixel = 0,
            ZIndex = 50,
        }, Gui)
        corner(listFrame, 7)
        stroke(listFrame, P.stroke, 1)

        local scroll = new("ScrollingFrame", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 2,
            ScrollBarImageColor3 = P.stroke,
            CanvasSize = UDim2.new(0, 0, 0, #options * 24 + 8),
        }, listFrame)
        new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4) }, scroll)

        for index, option in ipairs(options) do
            local item = new("TextButton", {
                Size = UDim2.new(1, -8, 0, 24),
                Position = UDim2.fromOffset(4, (index - 1) * 24),
                BackgroundColor3 = P.card,
                BackgroundTransparency = (option == state) and 0 or 1,
                Text = option,
                TextColor3 = (option == state) and P.accent or P.text,
                Font = Enum.Font.GothamMedium,
                TextSize = 11,
                TextXAlignment = Enum.TextXAlignment.Left,
                AutoButtonColor = false,
                BorderSizePixel = 0,
                ZIndex = 51,
            }, scroll)
            new("UIPadding", { PaddingLeft = UDim.new(0, 6) }, item)
            item.MouseEnter:Connect(function()
                if option ~= state then item.BackgroundTransparency = 0.4 end
            end)
            item.MouseLeave:Connect(function()
                if option ~= state then item.BackgroundTransparency = 1 end
            end)
            item.Activated:Connect(function() pick(option) end)
        end

        outsideConn = UIS.InputBegan:Connect(function(input)
            if not isPress(input) then return end
            local mouse = mousePos()
            local position = listFrame and listFrame.AbsolutePosition or Vector2.new()
            local size = listFrame and listFrame.AbsoluteSize or Vector2.new()
            local inList = mouse.X >= position.X and mouse.X <= position.X + size.X
                and mouse.Y >= position.Y and mouse.Y <= position.Y + size.Y
            local btnPos = btn.AbsolutePosition
            local btnSize = btn.AbsoluteSize
            local inButton = mouse.X >= btnPos.X and mouse.X <= btnPos.X + btnSize.X
                and mouse.Y >= btnPos.Y and mouse.Y <= btnPos.Y + btnSize.Y
            if not inList and not inButton then
                closeList()
            end
        end)
    end

    btn.Activated:Connect(function()
        if listFrame then closeList() else openList() end
    end)

    local ctrl
    ctrl = {
        set = function(v)
            state = tostring(v)
            renderValue()
            if onChange then onChange(state) end
        end,
        get = function() return state end,
        setOptions = function(list, keep)
            options = list
            if not keep or not table.find(options, state) then
                state = options[1] or ""
                renderValue()
                if onChange then onChange(state) end
            end
            if listFrame then closeList() end
        end,
        getOptions = function() return options end,
    }

    renderValue()
    register(key, ctrl)
    return ctrl
end

local function TextBox(page, text, key, default, placeholder, onFocusLost)
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, page)

    label(holder, text, UDim2.new(1, -156, 1, 0), P.text, Enum.Font.GothamMedium, 12)

    local box = new("TextBox", {
        Size = UDim2.new(0, 148, 0, 24),
        Position = UDim2.new(1, -148, 0.5, -12),
        BackgroundColor3 = P.card,
        Text = default or "",
        PlaceholderText = placeholder or "",
        PlaceholderColor3 = P.muted,
        TextColor3 = P.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        BorderSizePixel = 0,
    }, holder)
    corner(box, 6)
    stroke(box, P.stroke, 1)
    new("UIPadding", { PaddingLeft = UDim.new(0, 6) }, box)

    box.FocusLost:Connect(function()
        if onFocusLost then onFocusLost(box.Text) end
    end)

    local ctrl = {
        set = function(v)
            box.Text = tostring(v)
            if onFocusLost then onFocusLost(box.Text) end
        end,
        get = function() return box.Text end,
    }
    register(key, ctrl)
    return ctrl
end

local function Keybind(page, text, key, defaultKey, onChange)
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 32),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, page)

    label(holder, text, UDim2.new(1, -156, 1, 0), P.text, Enum.Font.GothamMedium, 12)

    local btn = new("TextButton", {
        Size = UDim2.new(0, 148, 0, 24),
        Position = UDim2.new(1, -148, 0.5, -12),
        BackgroundColor3 = P.card,
        Text = (defaultKey and defaultKey.Name) or "None",
        TextColor3 = P.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        AutoButtonColor = false,
        BorderSizePixel = 0,
    }, holder)
    corner(btn, 6)
    stroke(btn, P.stroke, 1)

    local state = defaultKey or Enum.KeyCode.Unknown
    local listening = false

    local function render()
        btn.Text = listening and "appuie..." or state.Name
        btn.TextColor3 = listening and P.accent or P.text
    end

    btn.Activated:Connect(function()
        listening = true
        render()
    end)

    UIS.InputBegan:Connect(function(input)
        if not listening then return end
        if input.UserInputType == Enum.UserInputType.Keyboard then
            state = input.KeyCode
            listening = false
            render()
            if onChange then onChange(state) end
        elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
            state = Enum.KeyCode.Unknown
            listening = false
            render()
            if onChange then onChange(state) end
        end
    end)

    local ctrl = {
        set = function(v)
            if type(v) == "string" then
                local ok, code = pcall(function() return Enum.KeyCode[v] end)
                state = (ok and code) or Enum.KeyCode.Unknown
            else
                state = v or Enum.KeyCode.Unknown
            end
            render()
            if onChange then onChange(state) end
        end,
        get = function() return state.Name end,
    }
    render()
    register(key, ctrl)
    return ctrl
end

local function Note(page, text)
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
    }, page)
    local lbl = label(holder, text, UDim2.new(1, 0, 1, 0), P.muted, Enum.Font.GothamMedium, 11)
    lbl.TextWrapped = true
    lbl.TextYAlignment = Enum.TextYAlignment.Top
end

--=====================================================================
--  10. ONGLETS
--=====================================================================
addPage("Joueur")
addPage("Combat")
addPage("Visuel")
addPage("Teleport")
addPage("Farm")
addPage("Jeu")
addPage("Config")

--=====================================================================
--  11. ETAT DES MODULES + CONFIG RUNTIME
--=====================================================================
local C = {
    walk = { enabled = false, value = 16 },
    jump = { enabled = false, value = 50 },
    fly = { enabled = false, speed = 55 },
    noclip = false,
    infJump = false,
    hitbox = { enabled = false, size = 8 },
    esp = {
        enabled = false,
        box = true, name = true, health = true, distance = true,
        tracer = false, chams = false, teamCheck = true, maxDistance = 1200,
    },
    aim = {
        enabled = false, fov = 120, smooth = 0.28,
        teamCheck = true, wallCheck = true, part = "Head",
        key = Enum.KeyCode.E, held = false,
    },
    world = { fullbright = false, fov = 70, noFog = false, clock = 14 },
    farm = { enabled = false, cadence = 0.4, remote = "", args = "" },
    autoclick = { enabled = false, rate = 0.5 },
    antiAfk = true,
    menuKey = Enum.KeyCode.RightShift,
}

local function fireRemote(remote, args, count)
    if not remote or not remote.Parent then return false, "remote absent" end
    args = args or {}
    local unpacked = table.unpack(args, 1, count or #args)
    if remote:IsA("RemoteFunction") then
        local ok, err = pcall(function()
            return remote:InvokeServer(unpacked)
        end)
        return ok, ok and "invoked" or tostring(err)
    elseif remote:IsA("RemoteEvent") then
        local ok, err = pcall(function()
            remote:FireServer(unpacked)
        end)
        return ok, ok and "fired" or tostring(err)
    end
    return false, "pas un remote"
end

local function parseArgs(text)
    local args, count = {}, 0
    if type(text) ~= "string" or text == "" then return args, count end

    for chunk in string.gmatch(text .. ",", "([^,]*),") do
        local token = string.match(chunk, "^%s*(.-)%s*$")
        if token ~= "" then
            local lower = string.lower(token)
            local value, isNil
            if lower == "true" then
                value = true
            elseif lower == "false" then
                value = false
            elseif lower == "nil" then
                isNil = true
            else
                local quoted = string.match(token, '^"(.*)"$') or string.match(token, "^'(.*)'$")
                if quoted then
                    value = quoted
                else
                    value = tonumber(token) or token
                end
            end
            count = count + 1
            if isNil then
                args[count] = nil
            else
                args[count] = value
            end
        end
    end
    return args, count
end

--=====================================================================
--  12. MOUVEMENT
--=====================================================================
local function applyWalk()
    local hum = humanoid()
    if not hum then return end
    if C.walk.enabled then
        if hum.WalkSpeed ~= C.walk.value then
            hum.WalkSpeed = C.walk.value
        end
    end
end

local function applyJump()
    local hum = humanoid()
    if not hum then return end
    if not C.jump.enabled then return end
    if hum.UseJumpPower then
        if hum.JumpPower ~= C.jump.value then
            hum.JumpPower = C.jump.value
        end
    else
        local height = (C.jump.value * C.jump.value) / 392.4
        if math.abs(hum.JumpHeight - height) > 0.25 then
            hum.JumpHeight = height
        end
    end
end

local function setNoclip(on)
    local char = character()
    if not char then return end
    for _, inst in ipairs(char:GetDescendants()) do
        if inst:IsA("BasePart") then
            inst.CanCollide = not on
        end
    end
end

local flyState = { conn = nil, attachment = nil, velocity = nil }

local function stopFly()
    if flyState.conn then
        flyState.conn:Disconnect()
        flyState.conn = nil
    end
    if flyState.velocity then
        flyState.velocity:Destroy()
        flyState.velocity = nil
    end
    if flyState.attachment then
        flyState.attachment:Destroy()
        flyState.attachment = nil
    end
    local hum = humanoid()
    if hum then
        hum.PlatformStand = false
    end
end

local function startFly()
    stopFly()
    local char = character()
    local hrp = rootPart()
    local hum = humanoid()
    if not (char and hrp and hum) then
        Notify("Fly", "Personnage pas pret.", P.danger)
        return false
    end

    hum.PlatformStand = true

    local attachment = Instance.new("Attachment")
    attachment.Name = "bp_fly_node"
    attachment.Parent = hrp

    local velocity = Instance.new("LinearVelocity")
    velocity.Name = "bp_fly"
    velocity.Attachment0 = attachment
    velocity.MaxForce = math.huge
    velocity.RelativeTo = Enum.ActuatorRelativeTo.World
    velocity.VectorVelocity = Vector3.zero
    velocity.Parent = hrp

    flyState.attachment = attachment
    flyState.velocity = velocity

    flyState.conn = RunService.RenderStepped:Connect(function()
        if not C.fly.enabled then return end
        local camera = workspace.CurrentCamera
        local currentRoot = rootPart()
        if not (camera and currentRoot) then return end
        if not flyState.velocity or not flyState.attachment then
            stopFly()
            if C.fly.enabled then startFly() end
            return
        end
        if flyState.velocity.Parent ~= currentRoot or flyState.attachment.Parent ~= currentRoot then
            stopFly()
            if C.fly.enabled then startFly() end
            return
        end
        local direction = Vector3.zero
        if UIS:IsKeyDown(Enum.KeyCode.W) then direction += camera.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then direction -= camera.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then direction -= camera.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then direction += camera.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.Space) then direction += Vector3.yAxis end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then direction -= Vector3.yAxis end
        if direction.Magnitude > 0 then
            flyState.velocity.VectorVelocity = direction.Unit * C.fly.speed
        else
            flyState.velocity.VectorVelocity = Vector3.zero
        end
    end)
    return true
end

--=====================================================================
--  13. ESP
--=====================================================================
local EspCache = {}

local function clearEspRecord(rec)
    if not rec then return end
    if rec.drawing then
        for _, obj in pairs(rec.drawing) do
            pcall(function() obj:Remove() end)
        end
    end
    if rec.highlight then
        pcall(function() rec.highlight:Destroy() end)
    end
    if rec.billboard then
        pcall(function() rec.billboard:Destroy() end)
    end
end

local function clearAllEsp()
    for _, rec in pairs(EspCache) do
        clearEspRecord(rec)
    end
    EspCache = {}
end

local function buildEspRecord(plr)
    local rec = { drawing = nil, highlight = nil, billboard = nil, head = nil }

    if HAS_DRAWING then
        local d = {}
        local function make(kind)
            local ok, obj = pcall(DrawingLib.new, kind)
            if ok and obj then return obj end
            return nil
        end
        d.box = make("Square")
        d.name = make("Text")
        d.distance = make("Text")
        d.healthBg = make("Square")
        d.health = make("Square")
        d.tracer = make("Line")

        if d.box then
            setProp(d.box, "Thickness", 1)
            setProp(d.box, "Filled", false)
            setProp(d.box, "Color", Color3.fromRGB(157, 255, 94))
        end
        if d.name then
            setProp(d.name, "Size", 13)
            setProp(d.name, "Center", true)
            setProp(d.name, "Outline", true)
            setProp(d.name, "Color", Color3.fromRGB(235, 239, 247))
        end
        if d.distance then
            setProp(d.distance, "Size", 12)
            setProp(d.distance, "Center", true)
            setProp(d.distance, "Outline", true)
            setProp(d.distance, "Color", Color3.fromRGB(157, 255, 94))
        end
        if d.healthBg then
            setProp(d.healthBg, "Filled", true)
            setProp(d.healthBg, "Color", Color3.fromRGB(20, 20, 24))
        end
        if d.health then
            setProp(d.health, "Filled", true)
            setProp(d.health, "Color", Color3.fromRGB(80, 230, 130))
        end
        if d.tracer then
            setProp(d.tracer, "Thickness", 1)
            setProp(d.tracer, "Color", Color3.fromRGB(157, 255, 94))
        end
        rec.drawing = d
    else
        local highlight = Instance.new("Highlight")
        highlight.Name = "bp_hl"
        highlight.FillColor = Color3.fromRGB(157, 255, 94)
        highlight.FillTransparency = 0.75
        highlight.OutlineColor = Color3.fromRGB(157, 255, 94)
        highlight.OutlineTransparency = 0.2
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        rec.highlight = highlight
        rec.billboard = nil
    end

    return rec
end

local function actualHead(plr)
    local char = plr.Character
    return char and char:FindFirstChild("Head")
end

local function projectBox(model, camera)
    local ok, cf, size = pcall(function()
        local frame, dimensions = model:GetBoundingBox()
        return frame, dimensions
    end)
    if not ok or not cf then return nil end

    local minX, minY, maxX, maxY
    local count = 0
    for ix = -1, 1, 2 do
        for iy = -1, 1, 2 do
            for iz = -1, 1, 2 do
                local world = cf * Vector3.new(
                    size.X * 0.5 * ix,
                    size.Y * 0.5 * iy,
                    size.Z * 0.5 * iz
                )
                local screen, onScreen = camera:WorldToViewportPoint(world)
                if onScreen and screen.Z > 0 then
                    count = count + 1
                    local x, y = screen.X, screen.Y
                    minX = minX and math.min(minX, x) or x
                    maxX = maxX and math.max(maxX, x) or x
                    minY = minY and math.min(minY, y) or y
                    maxY = maxY and math.max(maxY, y) or y
                end
            end
        end
    end
    if count < 3 then return nil end
    return Vector2.new(minX, minY), Vector2.new(maxX, maxY)
end

local function updateEsp()
    if not C.esp.enabled then
        if next(EspCache) ~= nil then
            clearAllEsp()
        end
        return
    end

    local camera = workspace.CurrentCamera
    if not camera then return end
    local localPlayer = Players.LocalPlayer
    local localCharacter = localPlayer and localPlayer.Character
    local viewport = camera.ViewportSize
    local seen = {}

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= localPlayer then
            local char = plr.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local skip = false

            if not (char and hum and hrp) then skip = true end
            if not skip and hum.Health <= 0 then skip = true end
            if not skip and C.esp.teamCheck and plr.Team and localPlayer.Team then
                if plr.Team == localPlayer.Team then skip = true end
            end

            local distance = 0
            if not skip then
                distance = (hrp.Position - camera.CFrame.Position).Magnitude
                if distance > C.esp.maxDistance then skip = true end
            end

            if skip then
                local rec = EspCache[plr]
                if rec then
                    clearEspRecord(rec)
                    EspCache[plr] = nil
                end
            else
                seen[plr] = true
                local rec = EspCache[plr] or buildEspRecord(plr)
                EspCache[plr] = rec

                if rec.highlight then
                    if C.esp.chams then
                        if rec.highlight.Parent ~= char then
                            rec.highlight.Parent = char
                        end
                    else
                        rec.highlight.Parent = nil
                    end
                end

                if rec.billboard == nil and not HAS_DRAWING then
                    local head = actualHead(plr)
                    if head then
                        local billboard = Instance.new("BillboardGui")
                        billboard.Name = "bp_tag"
                        billboard.Size = UDim2.fromOffset(120, 18)
                        billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.4, 0)
                        billboard.AlwaysOnTop = true
                        local tag = Instance.new("TextLabel")
                        tag.Size = UDim2.fromScale(1, 1)
                        tag.BackgroundTransparency = 1
                        tag.Text = plr.Name
                        tag.TextColor3 = P.text
                        tag.TextStrokeTransparency = 0.4
                        tag.Font = Enum.Font.GothamBold
                        tag.TextSize = 12
                        tag.Parent = billboard
                        billboard.Parent = head
                        rec.billboard = billboard
                        rec.head = head
                    end
                elseif rec.billboard and rec.head and rec.head.Parent == nil then
                    pcall(function() rec.billboard:Destroy() end)
                    rec.billboard = nil
                    rec.head = nil
                end

                if rec.drawing then
                    local boxMin, boxMax = projectBox(char, camera)
                    if boxMin and boxMax then
                        local width = boxMax.X - boxMin.X
                        local height = boxMax.Y - boxMin.Y
                        local d = rec.drawing

                        if d.box then
                            setProp(d.box, "Visible", C.esp.box)
                            setProp(d.box, "Position", boxMin)
                            setProp(d.box, "Size", Vector2.new(width, height))
                        end
                        if d.name then
                            setProp(d.name, "Visible", C.esp.name)
                            setProp(d.name, "Text", plr.DisplayName or plr.Name)
                            setProp(d.name, "Position", Vector2.new(boxMin.X + width * 0.5, boxMin.Y - 15))
                        end
                        if d.distance then
                            setProp(d.distance, "Visible", C.esp.distance)
                            setProp(d.distance, "Text", string.format("%d m", math.floor(distance)))
                            setProp(d.distance, "Position", Vector2.new(boxMin.X + width * 0.5, boxMax.Y + 3))
                        end
                        if d.healthBg and d.health then
                            local ratio = clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                            local barX = boxMin.X - 5
                            setProp(d.healthBg, "Visible", C.esp.health)
                            setProp(d.healthBg, "Position", Vector2.new(barX, boxMin.Y))
                            setProp(d.healthBg, "Size", Vector2.new(3, height))
                            setProp(d.health, "Visible", C.esp.health)
                            setProp(d.health, "Position", Vector2.new(barX, boxMax.Y - height * ratio))
                            setProp(d.health, "Size", Vector2.new(3, height * ratio))
                        end
                        if d.tracer then
                            setProp(d.tracer, "Visible", C.esp.tracer)
                            setProp(d.tracer, "From", Vector2.new(viewport.X * 0.5, viewport.Y))
                            setProp(d.tracer, "To", Vector2.new(boxMin.X + width * 0.5, boxMax.Y))
                        end
                    else
                        for _, obj in pairs(rec.drawing) do
                            setProp(obj, "Visible", false)
                        end
                    end
                end
            end
        end
    end

    for plr, rec in pairs(EspCache) do
        if not seen[plr] then
            clearEspRecord(rec)
            EspCache[plr] = nil
        end
    end
end

--=====================================================================
--  14. AIMBOT + HITBOX
--=====================================================================
local aimRender = nil

local function aimTarget(camera)
    local localPlayer = Players.LocalPlayer
    local best, bestDistance = nil, math.huge
    local center = camera.ViewportSize * 0.5

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= localPlayer then
            local char = plr.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local part = char and (char:FindFirstChild(C.aim.part) or char:FindFirstChild("Head"))
            if char and hum and hum.Health > 0 and part then
                local allowed = true
                if C.aim.teamCheck and plr.Team and localPlayer.Team then
                    allowed = plr.Team ~= localPlayer.Team
                end
                if allowed then
                    local screen, onScreen = camera:WorldToViewportPoint(part.Position)
                    if onScreen and screen.Z > 0 then
                        local delta = Vector2.new(screen.X, screen.Y) - center
                        local distance = delta.Magnitude
                        if distance <= C.aim.fov and distance < bestDistance then
                            best = { player = plr, part = part, position = part.Position }
                            bestDistance = distance
                        end
                    end
                end
            end
        end
    end

    return best
end

local function visibleFromCamera(camera, target)
    if not C.aim.wallCheck then return true end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { character(), camera }
    params.IgnoreWater = true
    local origin = camera.CFrame.Position
    local result = workspace:Raycast(origin, target.Position - origin, params)
    if not result then return true end
    return result.Instance:IsDescendantOf(target.player.Character)
end

local function startAim()
    if aimRender then aimRender:Disconnect() end
    aimRender = RunService.RenderStepped:Connect(function(dt)
        if not C.aim.enabled or not C.aim.held then return end
        local camera = workspace.CurrentCamera
        if not camera then return end
        local target = aimTarget(camera)
        if not target then return end
        if not visibleFromCamera(camera, target) then return end
        local desired = CFrame.lookAt(camera.CFrame.Position, target.position)
        local alpha = 1 - math.exp(-dt / math.max(C.aim.smooth, 0.02))
        camera.CFrame = camera.CFrame:Lerp(desired, alpha)
    end)
end

local function stopAim()
    if aimRender then
        aimRender:Disconnect()
        aimRender = nil
    end
end

local function applyHitbox()
    local hrp = rootPart()
    if not hrp then return end
    if C.hitbox.enabled then
        local size = C.hitbox.size
        hrp.Size = Vector3.new(size, size, size)
        hrp.Transparency = 1
    else
        hrp.Size = Vector3.new(2, 2, 1)
        hrp.Transparency = 0
    end
end

--=====================================================================
--  15. MONDE (lumiere, FOV, brouillard)
--=====================================================================
local worldSnapshot = nil

local function snapshotWorld()
    if worldSnapshot then return end
    worldSnapshot = {
        brightness = Lighting.Brightness,
        ambient = Lighting.Ambient,
        outdoor = Lighting.OutdoorAmbient,
        fogEnd = Lighting.FogEnd,
        fogStart = Lighting.FogStart,
        clock = Lighting.ClockTime,
        fov = workspace.CurrentCamera and workspace.CurrentCamera.FieldOfView or 70,
    }
end

local function applyWorld()
    snapshotWorld()
    local camera = workspace.CurrentCamera

    if C.world.fullbright then
        Lighting.Brightness = 3
        Lighting.Ambient = Color3.fromRGB(180, 180, 180)
        Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
    else
        Lighting.Brightness = worldSnapshot.brightness
        Lighting.Ambient = worldSnapshot.ambient
        Lighting.OutdoorAmbient = worldSnapshot.outdoor
    end

    if C.world.noFog then
        Lighting.FogEnd = 100000
        Lighting.FogStart = 100000
    else
        Lighting.FogEnd = worldSnapshot.fogEnd
        Lighting.FogStart = worldSnapshot.fogStart
    end

    Lighting.ClockTime = C.world.clock

    if camera then
        camera.FieldOfView = C.world.fov
    end
end

local function restoreWorld()
    if not worldSnapshot then return end
    Lighting.Brightness = worldSnapshot.brightness
    Lighting.Ambient = worldSnapshot.ambient
    Lighting.OutdoorAmbient = worldSnapshot.outdoor
    Lighting.FogEnd = worldSnapshot.fogEnd
    Lighting.FogStart = worldSnapshot.fogStart
    Lighting.ClockTime = worldSnapshot.clock
    local camera = workspace.CurrentCamera
    if camera then camera.FieldOfView = worldSnapshot.fov end
    worldSnapshot = nil
end

--=====================================================================
--  16. FARM + TELEPORT
--=====================================================================
local function teleportTo(position)
    local char = character()
    if not char or not position then return false end
    local hrp = rootPart()
    if not hrp then return false end
    local target = CFrame.new(position + Vector3.new(0, 3, 0))
    pcall(function()
        char:PivotTo(target)
    end)
    hrp.CFrame = target
    return true
end

local function teleportToPlayer(plr)
    local char = plr.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then
        Notify("Teleport", plr.Name .. " n'a pas de personnage.", P.danger)
        return
    end
    teleportTo(hrp.Position)
end

local function teleportToMouse()
    local camera = workspace.CurrentCamera
    if not camera then return end
    local mouse = Players.LocalPlayer:GetMouse()
    local position = mouse.Hit and mouse.Hit.Position
    if position then
        teleportTo(position)
    end
end

local function savePoint(name)
    local hrp = rootPart()
    if not hrp then return end
    local point = {
        name = name,
        position = { hrp.Position.X, hrp.Position.Y, hrp.Position.Z },
    }
    local list = Panel.Profile.points
    for index, existing in ipairs(list) do
        if existing.name == name then
            list[index] = point
            return point
        end
    end
    list[#list + 1] = point
    return point
end

local function pointPosition(point)
    local p = point.position
    return Vector3.new(p[1], p[2], p[3])
end

--=====================================================================
--  17. UI — ONGLET JOUEUR
--=====================================================================
local pagePlayer = Pages["Joueur"].page

section(pagePlayer, "Deplacement")
Slider(pagePlayer, "Vitesse", "walk.value", 8, 300, 1, 16, " ws", function(v)
    C.walk.value = v
    applyWalk()
end)
Toggle(pagePlayer, "Forcer la vitesse", "walk.enabled", false, function(on)
    C.walk.enabled = on
    applyWalk()
end)
Slider(pagePlayer, "Saut", "jump.value", 30, 500, 1, 50, " jp", function(v)
    C.jump.value = v
    applyJump()
end)
Toggle(pagePlayer, "Forcer le saut", "jump.enabled", false, function(on)
    C.jump.enabled = on
    applyJump()
end)

section(pagePlayer, "Vol")
Toggle(pagePlayer, "Fly", "fly.enabled", false, function(on)
    C.fly.enabled = on
    if on then
        if not startFly() then
            C.fly.enabled = false
            local ctrl = Controls["fly.enabled"]
            if ctrl then ctrl.set(false) end
        end
    else
        stopFly()
    end
end)
Slider(pagePlayer, "Vitesse de vol", "fly.speed", 10, 300, 5, 55, " st", function(v)
    C.fly.speed = v
end)
Note(pagePlayer, "WASD suit la camera, Espace monte, Ctrl descend.")

section(pagePlayer, "Collisions")
Toggle(pagePlayer, "Noclip", "noclip", false, function(on)
    C.noclip = on
    setNoclip(on)
end)
Toggle(pagePlayer, "Saut infini", "infJump", false, function(on)
    C.infJump = on
end)
Toggle(pagePlayer, "Anti-AFK", "antiAfk", true, function(on)
    C.antiAfk = on
end)

--=====================================================================
--  18. UI — COMBAT
--=====================================================================
local pageCombat = Pages["Combat"].page

section(pageCombat, "Aimbot camera")
Toggle(pageCombat, "Activer", "aim.enabled", false, function(on)
    C.aim.enabled = on
    if on then startAim() else stopAim() end
end)
Keybind(pageCombat, "Touche de visée", "aim.key", Enum.KeyCode.E, function(code)
    C.aim.key = code
end)
Slider(pageCombat, "Champ (px)", "aim.fov", 30, 500, 10, 120, " px", function(v)
    C.aim.fov = v
end)
Slider(pageCombat, "Lissage", "aim.smooth", 0.02, 1, 0.01, 0.28, "", function(v)
    C.aim.smooth = v
end)
Dropdown(pageCombat, "Point visé", "aim.part", { "Head", "HumanoidRootPart", "UpperTorso" }, "Head", function(v)
    C.aim.part = v
end)
Toggle(pageCombat, "Check équipe", "aim.teamCheck", true, function(on)
    C.aim.teamCheck = on
end)
Toggle(pageCombat, "Check murs", "aim.wallCheck", true, function(on)
    C.aim.wallCheck = on
end)

section(pageCombat, "Hitbox")
Toggle(pageCombat, "Étendre la hitbox", "hitbox.enabled", false, function(on)
    C.hitbox.enabled = on
    applyHitbox()
end)
Slider(pageCombat, "Taille", "hitbox.size", 4, 20, 1, 8, " st", function(v)
    C.hitbox.size = v
    applyHitbox()
end)

--=====================================================================
--  19. UI — VISUEL
--=====================================================================
local pageVisual = Pages["Visuel"].page

section(pageVisual, "ESP")
Toggle(pageVisual, "Activer l'ESP", "esp.enabled", false, function(on)
    C.esp.enabled = on
    if not on then clearAllEsp() end
end)
Toggle(pageVisual, "Boîtes", "esp.box", true, function(on) C.esp.box = on end)
Toggle(pageVisual, "Noms", "esp.name", true, function(on) C.esp.name = on end)
Toggle(pageVisual, "Vie", "esp.health", true, function(on) C.esp.health = on end)
Toggle(pageVisual, "Distance", "esp.distance", true, function(on) C.esp.distance = on end)
Toggle(pageVisual, "Traçantes", "esp.tracer", false, function(on) C.esp.tracer = on end)
Toggle(pageVisual, "Chams", "esp.chams", false, function(on) C.esp.chams = on end)
Toggle(pageVisual, "Check équipe", "esp.teamCheck", true, function(on) C.esp.teamCheck = on end)
Slider(pageVisual, "Portée max", "esp.maxDistance", 200, 5000, 100, 1200, " st", function(v)
    C.esp.maxDistance = v
end)

section(pageVisual, "Monde")
Toggle(pageVisual, "Fullbright", "world.fullbright", false, function(on)
    C.world.fullbright = on
    applyWorld()
end)
Toggle(pageVisual, "Supprimer le brouillard", "world.noFog", false, function(on)
    C.world.noFog = on
    applyWorld()
end)
Slider(pageVisual, "FOV camera", "world.fov", 40, 130, 1, 70, "°", function(v)
    C.world.fov = v
    applyWorld()
end)
Slider(pageVisual, "Heure", "world.clock", 0, 24, 1, 14, " h", function(v)
    C.world.clock = v
    applyWorld()
end)

--=====================================================================
--  20. UI — TELEPORT
--=====================================================================
local pageTp = Pages["Teleport"].page
local playerOptions = {}
local PlayerDropdown

local function refreshPlayerOptions()
    local list = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= Players.LocalPlayer then
            list[#list + 1] = plr.Name
        end
    end
    table.sort(list)
    playerOptions = list
    if PlayerDropdown then
        PlayerDropdown.setOptions(list, true)
    end
end

section(pageTp, "Joueurs")
PlayerDropdown = Dropdown(pageTp, "Cible", "tp.target", { "aucun" }, "aucun", function() end)
Button(pageTp, "Aller au joueur", P.text, function()
    local target = PlayerDropdown.get()
    local plr = Players:FindFirstChild(target)
    if plr then
        teleportToPlayer(plr)
    else
        Notify("Teleport", "Joueur introuvable.", P.danger)
    end
end)
Button(pageTp, "Rafraîchir la liste", P.muted, function()
    refreshPlayerOptions()
    Notify("Teleport", "Liste rafraîchie.", P.info)
end)
Button(pageTp, "Aller sous la souris", P.text, function()
    teleportToMouse()
end)

section(pageTp, "Points")
local pointOptions = {}
local PointDropdown

local function refreshPointOptions()
    local list = { "aucun" }
    for _, point in ipairs(Panel.Profile.points) do
        list[#list + 1] = point.name
    end
    pointOptions = list
    if PointDropdown then
        PointDropdown.setOptions(list, true)
    end
end

PointDropdown = Dropdown(pageTp, "Point", "tp.point", { "aucun" }, "aucun", function() end)
local pointNameBox = TextBox(pageTp, "Nom du point", "tp.pointName", "spawn", "ex: farm", function() end)
Button(pageTp, "Enregistrer la position", P.text, function()
    local name = pointNameBox.get()
    if type(name) ~= "string" or name == "" then
        Notify("Points", "Nom vide.", P.danger)
        return
    end
    savePoint(name)
    refreshPointOptions()
    Notify("Points", "Point '" .. name .. "' enregistré.", P.accent)
end)
Button(pageTp, "Aller au point", P.text, function()
    local target = PointDropdown.get()
    for _, point in ipairs(Panel.Profile.points) do
        if point.name == target then
            teleportTo(pointPosition(point))
            return
        end
    end
    Notify("Points", "Point introuvable.", P.danger)
end)
Button(pageTp, "Supprimer le point", P.danger, function()
    local target = PointDropdown.get()
    for index, point in ipairs(Panel.Profile.points) do
        if point.name == target then
            table.remove(Panel.Profile.points, index)
            refreshPointOptions()
            Notify("Points", "Point supprimé.", P.muted)
            return
        end
    end
end)

--=====================================================================
--  21. UI — FARM
--=====================================================================
local pageFarm = Pages["Farm"].page
local RemoteDropdown
local RemoteCountLabel
local remotePaths = {}
local ScanState = { running = false, last = 0, total = 0, farmCount = 0 }

local function refreshRemoteOptions(preferred)
    local list = { "aucun" }
    for _, path in ipairs(remotePaths) do
        list[#list + 1] = path
    end
    RemoteDropdown.setOptions(list, preferred ~= nil)
    if preferred and table.find(list, preferred) then
        RemoteDropdown.set(preferred)
    end
    RemoteCountLabel.Text = string.format("%d remotes · %d farm", ScanState.total or #remotePaths, ScanState.farmCount or 0)
end

local function scanAndBind(silent)
    if ScanState.running then return end
    ScanState.running = true
    if not silent then
        Notify("Scan", "Analyse de ReplicatedStorage...", P.info)
    end

    task.spawn(function()
        local ok, list = pcall(collectRemotes, 15000)
        ScanState.running = false
        if not ok then
            Notify("Scan", "Scan impossible : " .. tostring(list), P.danger)
            return
        end

        local learned = {}
        local farmCount = 0
        for _, entry in ipairs(list) do
            learned[#learned + 1] = { path = entry.path, class = entry.class, tag = entry.tag }
            if entry.tag == "farm" then
                farmCount = farmCount + 1
            end
        end

        table.sort(learned, function(a, b)
            local rankA = REMOTE_RANK[a.tag] or 9
            local rankB = REMOTE_RANK[b.tag] or 9
            if rankA ~= rankB then return rankA < rankB end
            return a.path < b.path
        end)

        remotePaths = {}
        for index, entry in ipairs(learned) do
            if index > REMOTE_OPTION_LIMIT then break end
            remotePaths[index] = entry.path
        end

        indexRemotes(list)

        ScanState.farmCount = farmCount
        ScanState.total = #learned
        ScanState.last = os.clock()

        Panel.Profile.remotes = learned
        Learned[game.PlaceId] = Learned[game.PlaceId] or {}
        Learned[game.PlaceId].remotes = learned
        Learned[game.PlaceId].name = Panel.Profile.name

        local current = RemoteDropdown.get()
        refreshRemoteOptions(current)
        if not silent then
            Notify("Scan", string.format("%d remotes indexés.", #learned), P.accent)
        end
    end)
end

section(pageFarm, "Remote actif")
RemoteCountLabel = label(pageFarm, "0 remotes", UDim2.new(1, 0, 0, 18), P.muted, Enum.Font.GothamMedium, 11)
RemoteDropdown = Dropdown(pageFarm, "Remote", "farm.remote", { "aucun" }, "aucun", function(path)
    C.farm.remote = path
end)
TextBox(pageFarm, "Arguments", "farm.args", "", "1, true, \"text\"", function(text)
    C.farm.args = text
end)
Button(pageFarm, "Scanner les remotes", P.text, function()
    scanAndBind(false)
end)
Button(pageFarm, "Tirer une fois", P.text, function()
    local path = RemoteDropdown.get()
    local inst = RemoteIndex[path]
    if not inst then
        Notify("Farm", "Remote introuvable. Scanne d'abord.", P.danger)
        return
    end
    local ok, result = fireRemote(inst, parseArgs(C.farm.args))
    Notify("Farm", tostring(result), ok and P.accent or P.danger)
end)

section(pageFarm, "Boucle")
Toggle(pageFarm, "Auto farm", "farm.enabled", false, function(on)
    C.farm.enabled = on
end)
Slider(pageFarm, "Cadence", "farm.cadence", 0.1, 5, 0.1, 0.4, " s", function(v)
    C.farm.cadence = v
end)
Toggle(pageFarm, "Auto clic", "autoclick.enabled", false, function(on)
    C.autoclick.enabled = on
end)
Slider(pageFarm, "Intervalle clic", "autoclick.rate", 0.1, 5, 0.1, 0.5, " s", function(v)
    C.autoclick.rate = v
end)

--=====================================================================
--  22. UI — JEU (adaptation)
--=====================================================================
local pageGame = Pages["Jeu"].page
local InfoLabels = {}

local function infoRow(name)
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
    }, pageGame)
    label(holder, name, UDim2.new(0, 130, 1, 0), P.muted, Enum.Font.GothamMedium, 11)
    local value = label(holder, "-", UDim2.new(1, -130, 1, 0), P.text, Enum.Font.GothamMedium, 11)
    value.Position = UDim2.fromOffset(130, 0)
    InfoLabels[name] = value
    return value
end

section(pageGame, "Détection")
local infoProfile = infoRow("Profil")
local infoPlace = infoRow("PlaceId")
local infoGameId = infoRow("GameId")
local infoExecutor = infoRow("Exécuteur")
local infoDrawing = infoRow("Drawing")
local infoTeams = infoRow("Équipes")
local infoRemotes = infoRow("Remotes")

infoPlace.Text = tostring(game.PlaceId)
infoGameId.Text = tostring(game.GameId)
infoExecutor.Text = EXECUTOR
infoDrawing.Text = HAS_DRAWING and "oui" or "non (fallback)"
infoTeams.Text = tostring(#Teams:GetTeams())

section(pageGame, "Adaptation")
Button(pageGame, "Relancer la détection", P.text, function()
    Panel.ApplyProfile(resolveGameName(), true)
    Notify("Profil", "Profil réappliqué : " .. Panel.Profile.name, P.accent)
end)
Button(pageGame, "Copier le profil Lua", P.text, function()
    if not CAP.setclipboard then
        Notify("Presse-papiers", "Indisponible dans cet exécuteur.", P.danger)
        return
    end
    local lines = {
        string.format("[%d] = {", game.PlaceId),
        string.format("    name = %q,", Panel.Profile.name),
        string.format("    keywords = { %q },", string.lower(Panel.Profile.name)),
        "    defaults = {",
        string.format("        walk = %d, jump = %d, espDistance = %d, teamCheck = %s,",
            C.walk.value, C.jump.value, C.esp.maxDistance, tostring(C.esp.teamCheck)),
        "    },",
        "    remotes = {",
    }
    for _, entry in ipairs(Panel.Profile.remotes or {}) do
        lines[#lines + 1] = string.format("        { path = %q, class = %q, tag = %q },",
            entry.path, entry.class, entry.tag or "autre")
    end
    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "},"
    pcall(CAP.setclipboard, table.concat(lines, "\n"))
    Notify("Presse-papiers", "Profil copié : colle-le dans SEEDS.", P.accent)
end)
Button(pageGame, "Sauvegarder les points", P.text, function()
    Panel.Save(true)
    Notify("Sauvegarde", "Points + remotes écrits sur disque.", P.accent)
end)

section(pageGame, "Notes")
local notesLabel = label(pageGame, "", UDim2.new(1, 0, 0, 40), P.muted, Enum.Font.GothamMedium, 11)
notesLabel.TextWrapped = true
notesLabel.TextYAlignment = Enum.TextYAlignment.Top

--=====================================================================
--  23. UI — CONFIG
--=====================================================================
local pageConfig = Pages["Config"].page

section(pageConfig, "Interface")
Keybind(pageConfig, "Touche du menu", "ui.key", Enum.KeyCode.RightShift, function(code)
    C.menuKey = code
end)
Button(pageConfig, "Sauvegarder la config", P.text, function()
    Panel.Save(false)
end)
Button(pageConfig, "Charger la config", P.text, function()
    Panel.Load()
end)
Button(pageConfig, "Reset la config", P.danger, function()
    if CAP.delfile then
        pcall(CAP.delfile, FS.file)
    end
    Notify("Config", "Fichier supprimé. Réexécute le script.", P.muted)
end)

section(pageConfig, "Serveur")
Button(pageConfig, "Rejoindre le même serveur", P.text, function()
    pcall(function()
        TeleportSvc:TeleportToPlaceInstance(game.PlaceId, game.JobId, Players.LocalPlayer)
    end)
    Notify("Serveur", "Rejoin en cours.", P.info)
end)
Button(pageConfig, "Nouveau serveur", P.text, function()
    pcall(function()
        TeleportSvc:Teleport(game.PlaceId, Players.LocalPlayer)
    end)
    Notify("Serveur", "Teleport vers un autre serveur.", P.info)
end)
Button(pageConfig, "Copier le JobId", P.muted, function()
    if CAP.setclipboard then
        pcall(CAP.setclipboard, game.JobId)
        Notify("Serveur", "JobId copié.", P.accent)
    end
end)

section(pageConfig, "Divers")
if CAP.setfpscap then
    Slider(pageConfig, "Cap FPS", "misc.fps", 30, 360, 10, 240, " fps", function(v)
        pcall(CAP.setfpscap, v)
    end)
end
Toggle(pageConfig, "Décharger", "misc.unload", false, function(on)
    if on then
        task.defer(function() Panel.Unload() end)
    end
end)
Note(pageConfig, "Config : " .. FS.file .. (FS.ready and "" or "  (disque indisponible — mémoire seule)"))

--=====================================================================
--  24. BOUCLE CENTRALE
--=====================================================================
local accumulators = {
    walk = 0, jump = 0, noclip = 0, esp = 0,
    hitbox = 0, farm = 0, click = 0, world = 0, ui = 0,
}

local connections = {}

local function track(connection)
    connections[#connections + 1] = connection
    return connection
end

local function heartbeat(dt)
    accumulators.walk += dt
    accumulators.jump += dt
    accumulators.noclip += dt
    accumulators.esp += dt
    accumulators.hitbox += dt
    accumulators.farm += dt
    accumulators.click += dt

    if accumulators.walk >= 0.25 then
        accumulators.walk = 0
        if C.walk.enabled then pcall(applyWalk) end
    end

    if accumulators.jump >= 0.5 then
        accumulators.jump = 0
        if C.jump.enabled then pcall(applyJump) end
    end

    if accumulators.noclip >= 0.2 then
        accumulators.noclip = 0
        if C.noclip then pcall(setNoclip, true) end
    end

    if accumulators.esp >= 0.05 then
        accumulators.esp = 0
        pcall(updateEsp)
    end

    if accumulators.hitbox >= 0.5 then
        accumulators.hitbox = 0
        if C.hitbox.enabled then pcall(applyHitbox) end
    end

    if accumulators.farm >= C.farm.cadence then
        accumulators.farm = 0
        if C.farm.enabled then
            local inst = RemoteIndex[C.farm.remote]
            if inst then
                pcall(fireRemote, inst, parseArgs(C.farm.args))
            end
        end
    end

    if accumulators.click >= C.autoclick.rate then
        accumulators.click = 0
        if C.autoclick.enabled then
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton1(Vector2.new(0, 0))
            end)
        end
    end
end

track(RunService.Heartbeat:Connect(function(dt)
    local ok = pcall(heartbeat, dt)
    if not ok then
        -- une frame cassee ne doit pas tuer la boucle
    end
end))

track(UIS.JumpRequest:Connect(function()
    if not C.infJump then return end
    local hum = humanoid()
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end))

track(UIS.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == C.aim.key then
        C.aim.held = true
    end
    if input.KeyCode == C.menuKey then
        Root.Visible = not Root.Visible
    end
end))

track(UIS.InputEnded:Connect(function(input)
    if input.KeyCode == C.aim.key then
        C.aim.held = false
    end
end))

track(Players.PlayerAdded:Connect(function()
    task.defer(refreshPlayerOptions)
end))
track(Players.PlayerRemoving:Connect(function()
    task.defer(refreshPlayerOptions)
end))

if LP then
    track(LP.Idled:Connect(function()
        if not C.antiAfk then return end
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end))
end

--=====================================================================
--  25. PROFIL + APPLICATION
--=====================================================================
function Panel.ApplyProfile(name, force)
    local profile = profileForPlace(name)
    Panel.Profile = profile

    if force or not Panel.LoadedConfig then
        C.walk.value = profile.defaults.walk or 16
        C.jump.value = profile.defaults.jump or 50
        C.esp.maxDistance = profile.defaults.espDistance or 1200
        C.esp.teamCheck = profile.defaults.teamCheck and true or false
        Controls["walk.value"].set(C.walk.value)
        Controls["jump.value"].set(C.jump.value)
        Controls["esp.maxDistance"].set(C.esp.maxDistance)
        Controls["esp.teamCheck"].set(C.esp.teamCheck)
    end

    ProfileChip.Text = profile.name .. "  ·  " .. tostring(profile.id)
    infoProfile.Text = profile.name .. " (" .. profile.kind .. ")"
    notesLabel.Text = profile.notes ~= "" and profile.notes
        or "Aucun profil connu : les modules universels tournent, le scan remotes sert de base."

    if #profile.remotes > 0 then
        local seen = {}
        remotePaths = {}
        for _, entry in ipairs(profile.remotes) do
            if #remotePaths >= REMOTE_OPTION_LIMIT then break end
            if entry.path and not seen[entry.path] then
                seen[entry.path] = true
                remotePaths[#remotePaths + 1] = entry.path
            end
        end
        ScanState.total = #profile.remotes
        refreshRemoteOptions(nil)
    end

    refreshPointOptions()
    refreshPlayerOptions()
    return profile
end

function Panel.Save(silent)
    local data = {
        version = Panel.Version,
        flags = {},
        games = Learned,
    }
    for key, ctrl in pairs(Controls) do
        local ok, value = pcall(ctrl.get)
        if ok and value ~= nil then
            data.flags[key] = value
        end
    end
    Learned[game.PlaceId] = Learned[game.PlaceId] or {}
    Learned[game.PlaceId].points = Panel.Profile.points
    Learned[game.PlaceId].name = Panel.Profile.name

    local ok = writeConfig(data)
    if not silent then
        if ok then
            Notify("Config", "Sauvegardé dans " .. FS.file, P.accent)
        else
            Notify("Config", "Écriture impossible sur ce disque.", P.danger)
        end
    end
    return ok
end

function Panel.Load()
    local data = readConfig()
    if type(data.flags) ~= "table" then return false end
    for key, value in pairs(data.flags) do
        local ctrl = Controls[key]
        if ctrl and ctrl.set then
            pcall(ctrl.set, value)
        end
    end
    Panel.LoadedConfig = true
    if type(data.games) == "table" then
        for placeId, entry in pairs(data.games) do
            Learned[placeId] = entry
        end
    end
    return true
end

function Panel.Unload()
    if Panel._unloaded then return end
    Panel._unloaded = true

    pcall(stopFly)
    pcall(stopAim)
    pcall(clearAllEsp)
    pcall(restoreWorld)
    pcall(function()
        local hrp = rootPart()
        if hrp then
            hrp.Size = Vector3.new(2, 2, 1)
            hrp.Transparency = 0
        end
    end)

    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    connections = {}

    pcall(function() Gui:Destroy() end)
    if GENV then GENV.butiampanel = nil end
    print("[butiampanel] unloaded")
end

--=====================================================================
--  26. INIT
--=====================================================================
if GENV then GENV.butiampanel = Panel end

do
    local data = readConfig()
    if type(data.games) == "table" then
        for placeId, entry in pairs(data.games) do
            Learned[placeId] = entry
        end
    end
end

Pages["Joueur"].select()

-- affichage immediat, puis resolution du nom en tache de fond
Panel.ApplyProfile(game.Name, false)

task.spawn(function()
    local name = resolveGameName()
    if name then
        Panel.ApplyProfile(name, false)
    end
    infoRemotes.Text = "scan en attente"
    scanAndBind(true)
end)

-- recharge la config apres application du profil
task.spawn(function()
    task.wait(0.2)
    local data = readConfig()
    if type(data.flags) == "table" then
        for key, value in pairs(data.flags) do
            local ctrl = Controls[key]
            if ctrl and ctrl.set then
                pcall(ctrl.set, value)
            end
        end
        Panel.LoadedConfig = true
    end
end)

-- refresh de la liste joueurs toutes les 2,5 s
task.spawn(function()
    while true do
        task.wait(2.5)
        if Panel._unloaded then break end
        pcall(refreshPlayerOptions)
    end
end)

-- rafraichit le libelle remotes
task.spawn(function()
    while true do
        task.wait(1)
        if Panel._unloaded then break end
        if RemoteCountLabel and #remotePaths > 0 then
            RemoteCountLabel.Text = string.format("%d remotes · %d farm", ScanState.total or #remotePaths, ScanState.farmCount or 0)
            infoRemotes.Text = tostring(ScanState.total or #remotePaths)
        end
    end
end)

print(string.format("[butiampanel] v%s chargé — executor: %s | drawing: %s | place: %d",
    Panel.Version, EXECUTOR, HAS_DRAWING and "oui" or "non", game.PlaceId))

Notify("butiampanel", "Prêt. RightShift pour ouvrir.", P.accent)
