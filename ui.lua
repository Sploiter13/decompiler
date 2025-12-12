--!native
--!optimize 2

---- environment ----
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local crypt = crypt
local memory = memory
local table = table
local string = string
local pcall = pcall
local tonumber = tonumber
local tostring = tostring
local ipairs = ipairs
local pairs = pairs
local print = print
local warn = warn
local writefile = writefile
local task = task

local table_insert = table.insert
local table_sort = table.sort
local string_char = string.char
local string_len = string.len
local string_sub = string.sub
local string_gmatch = string.gmatch

---- constants ----
local SERVER_URL = "http://127.0.0.1:3000"
local MAX_BYTECODE_SIZE = 10_000_000

local MAIN_TITLE = "Script Decompiler"
local OUTPUT_FILE_DEFAULT = "decompiled.lua"

local HEADER_HEIGHT = 30
local LIST_ROW_HEIGHT = 22
local BUTTON_WIDTH = 90
local BUTTON_HEIGHT = 20

local POPUP_LINE_HEIGHT = 16

---- variables ----
local ScriptList = {} -- { {Instance, Path, Class}, ... }

local MainUI = {
    X = 100, Y = 100,
    Width = 500, Height = 400,
    Visible = true,
    Dragging = false,
    DragOffset = {x = 0, y = 0},
    ListPage = 1,
    ListPerPage = 1,
    TotalListPages = 1,
}

local PopupUI = {
    Visible = false,
    X = 200, Y = 150,
    Width = 600, Height = 450,
    Dragging = false,
    DragOffset = {x = 0, y = 0},
    Title = "",
    Content = "",
    Lines = {},
    PopupPage = 1,
    LinesPerPage = 1,
    TotalPages = 1,
}

local MouseState = {WasPressed = false}

---- helpers ----
local function IsValid(obj: Instance?): boolean
    if not obj then return false end
    local ok, parent = pcall(function()
        return obj.Parent
    end)
    return ok and parent ~= nil
end

local function GetMousePos(): vector
    if getmouseposition then
        return getmouseposition()
    end
    local vp = Camera and Camera.ViewportSize or vector.create(1920, 1080, 0)
    return vector.create(vp.X * 0.5, vp.Y * 0.5, 0)
end

local function IsMouseInRect(mousePos: {x:number,y:number}, x:number,y:number,w:number,h:number): boolean
    return mousePos.x >= x and mousePos.x <= x + w and
           mousePos.y >= y and mousePos.y <= y + h
end

local function CheckClick(): boolean
    local isPressed = false
    if isleftpressed then
        isPressed = isleftpressed()
    end
    if isPressed and not MouseState.WasPressed then
        MouseState.WasPressed = true
        return true
    end
    MouseState.WasPressed = isPressed
    return false
end

---- decompiler core ----
local function get_script_bytecode(script: Instance): (string?, number?)
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
    if not bytecode_size or bytecode_size == 0 or bytecode_size > MAX_BYTECODE_SIZE then
        return nil, nil
    end

    local bytes = table.create(bytecode_size)
    for i = 0, bytecode_size - 1 do
        bytes[i + 1] = string_char(memory.readu8(bytecode_ptr + i))
    end

    return table.concat(bytes), bytecode_size
end

local function build_path_from_instance(obj: Instance): string
    local parts = {}
    local current = obj
    while current and current ~= game do
        table_insert(parts, 1, current.Name)
        current = current.Parent
    end
    return "game." .. table.concat(parts, ".")
end

local function decompile_script(script: Instance, output_file: string?, silent: boolean?): string?
    output_file = output_file or OUTPUT_FILE_DEFAULT
    silent = silent or false

    local function log(msg: string)
        if not silent then
            print(msg)
        end
    end

    if not script or (script.ClassName ~= "LocalScript" and script.ClassName ~= "ModuleScript") then
        warn("[DECOMPILER] Invalid target (must be LocalScript or ModuleScript)")
        return nil
    end

    local path = build_path_from_instance(script)
    log("[DECOMPILER] Processing: " .. path)

    local bytecode, size = get_script_bytecode(script)
    if not bytecode then
        warn("[DECOMPILER] Failed to extract bytecode")
        return nil
    end
    log("[DECOMPILER] Extracted " .. tostring(size) .. " bytes")

    local b64 = crypt.base64.encode(bytecode)
    local ok, response = pcall(function()
        return game:HttpPost(SERVER_URL, b64, "text/plain", "text/plain", "")
    end)
    if not ok then
        warn("[DECOMPILER] HttpPost failed: " .. tostring(response))
        return nil
    end
    if type(response) ~= "string" or #response == 0 then
        warn("[DECOMPILER] Empty response from server")
        return nil
    end

    local success, err = pcall(function()
        writefile(output_file, response)
    end)
    if not success then
        warn("[DECOMPILER] Failed to save file: " .. tostring(err))
    end

    return response
end

---- restricted scan ----
local function ScanScripts()
    ScriptList = {}

    local roots = {
        Workspace,
        Players,
        ReplicatedStorage,
        ReplicatedFirst,
        StarterGui,
    }

    local function scanFolder(root: Instance)
        local ok, children = pcall(function()
            return root:GetChildren()
        end)
        if not ok or not children then
            return
        end

        for _, child in ipairs(children) do
            local className = child.ClassName
            if className == "LocalScript" or className == "ModuleScript" then
                local info = {
                    Instance = child,
                    Path = build_path_from_instance(child),
                    Class = className,
                }
                table_insert(ScriptList, info)
            end
            scanFolder(child)
        end
    end

    for _, root in ipairs(roots) do
        if IsValid(root) then
            scanFolder(root)
        end
    end

    table_sort(ScriptList, function(a, b)
        return a.Path < b.Path
    end)

    print("[Decompiler UI] Found scripts (restricted roots):", #ScriptList)
end

local function RecomputeListPages()
    local h = MainUI.Height
    local listY = MainUI.Y + HEADER_HEIGHT + 5 + 20
    local usable = h - (listY - MainUI.Y) - 10
    local per = usable > 0 and math.floor(usable / LIST_ROW_HEIGHT) or 1
    if per < 1 then per = 1 end
    MainUI.ListPerPage = per
    local total = math.ceil(math.max(#ScriptList, 1) / per)
    if total < 1 then total = 1 end
    MainUI.TotalListPages = total
    if MainUI.ListPage > total then
        MainUI.ListPage = total
    end
end

---- drawing helpers ----
local function DrawRect(x:number,y:number,w:number,h:number,color:Color3,opacity:number)
    DrawingImmediate.FilledRectangle(
        vector.create(x, y, 0),
        vector.create(w, h, 0),
        color,
        opacity
    )
end

local function DrawText(x:number,y:number,size:number,color:Color3,text:string,centered:boolean)
    DrawingImmediate.Text(
        vector.create(x, y, 0),
        size,
        color,
        1,
        text,
        centered,
        nil
    )
end

local function DrawOutlinedText(x:number,y:number,size:number,color:Color3,text:string,centered:boolean)
    DrawingImmediate.OutlinedText(
        vector.create(x, y, 0),
        size,
        color,
        1,
        text,
        centered,
        nil
    )
end

local function DrawButton(x:number,y:number,w:number,h:number,label:string,bg:Color3,fg:Color3)
    DrawRect(x, y, w, h, bg, 1)
    DrawText(x + w * 0.5, y + (h / 2) - 6, 14, fg, label, true)
end

---- popup pagination ----
local function PreparePopupLines()
    PopupUI.Lines = {}
    local text = PopupUI.Content or ""
    for line in string_gmatch(text, "([^\n]*)\n?") do
        if line == "" and #PopupUI.Lines == 0 then
        else
            table_insert(PopupUI.Lines, line)
        end
    end

    local contentHeight = PopupUI.Height - (HEADER_HEIGHT + 10 + 24) -- leave space for pager
    local per = contentHeight > 0 and math.floor(contentHeight / POPUP_LINE_HEIGHT) or 1
    if per < 1 then per = 1 end
    PopupUI.LinesPerPage = per

    local total = math.ceil(math.max(#PopupUI.Lines, 1) / per)
    if total < 1 then total = 1 end
    PopupUI.TotalPages = total
    if PopupUI.PopupPage > total then
        PopupUI.PopupPage = total
    end
end

local function ShowPopup(title: string, content: string)
    PopupUI.Visible = true
    PopupUI.Title = title
    PopupUI.Content = content
    PopupUI.PopupPage = 1

    local vp = Camera.ViewportSize
    PopupUI.Width = 600
    PopupUI.Height = 450
    PopupUI.X = (vp.X - PopupUI.Width) * 0.5
    PopupUI.Y = (vp.Y - PopupUI.Height) * 0.5

    PreparePopupLines()
end

local function ClampMainToScreen()
    local vp = Camera.ViewportSize
    if MainUI.X < 0 then MainUI.X = 0 end
    if MainUI.Y < 0 then MainUI.Y = 0 end
    if MainUI.X + MainUI.Width > vp.X then MainUI.X = vp.X - MainUI.Width end
    if MainUI.Y + MainUI.Height > vp.Y then MainUI.Y = vp.Y - MainUI.Height end
end

local function ClampPopupToScreen()
    local vp = Camera.ViewportSize
    if PopupUI.X < 0 then PopupUI.X = 0 end
    if PopupUI.Y < 0 then PopupUI.Y = 0 end
    if PopupUI.X + PopupUI.Width > vp.X then PopupUI.X = vp.X - PopupUI.Width end
    if PopupUI.Y + PopupUI.Height > vp.Y then PopupUI.Y = vp.Y - PopupUI.Height end
end

local function StartDecompileFor(info)
    if not IsValid(info.Instance) then
        warn("[Decompiler UI] Target script invalid")
        return
    end

    task.spawn(function()
        local result = decompile_script(info.Instance, OUTPUT_FILE_DEFAULT, false)
        if not result then
            ShowPopup("Error", "Decompile failed for\n" .. info.Path)
            return
        end
        ShowPopup(info.Path .. " (" .. info.Class .. ")", result)
    end)
end

---- render main window (paged list) ----
local function RenderMain(mousePos, clicked:boolean)
    if not MainUI.Visible then return end

    local x = MainUI.X
    local y = MainUI.Y
    local w = MainUI.Width
    local h = MainUI.Height

    DrawRect(x, y, w, h, Color3.fromRGB(30, 30, 30), 0.95)
    DrawRect(x, y, w, HEADER_HEIGHT, Color3.fromRGB(45, 45, 45), 1)

    DrawOutlinedText(x + 10, y + 8, 16, Color3.new(1, 1, 1), MAIN_TITLE, false)
    DrawText(x + w - 50, y + 8, 16, Color3.new(1, 0.4, 0.4), "X", false)

    -- page text in header
    local headerCenterX = x + w * 0.5
    local headerText = "<  " .. tostring(MainUI.ListPage) .. "/" .. tostring(MainUI.TotalListPages) .. "  >"
    DrawText(headerCenterX, y + 8, 14, Color3.new(0.8, 0.8, 0.8), headerText, true)

    local leftDown = false
    if isleftpressed then leftDown = isleftpressed() end

    -- dragging
    if leftDown and not MainUI.Dragging then
        if IsMouseInRect(mousePos, x, y, w, HEADER_HEIGHT) then
            MainUI.Dragging = true
            MainUI.DragOffset.x = mousePos.x - x
            MainUI.DragOffset.y = mousePos.y - y
        end
    end

    if not leftDown then
        MainUI.Dragging = false
    end

    if MainUI.Dragging then
        MainUI.X = mousePos.x - MainUI.DragOffset.x
        MainUI.Y = mousePos.y - MainUI.DragOffset.y
        ClampMainToScreen()
        x = MainUI.X
        y = MainUI.Y
    end

    -- close button
    if clicked and IsMouseInRect(mousePos, x + w - 40, y, 40, HEADER_HEIGHT) then
        MainUI.Visible = false
        return
    end

    -- header page controls
    local pageLabelWidth = 80
    local pageLabelX = headerCenterX - pageLabelWidth * 0.5
    local leftArrowRect = {x = pageLabelX - 15, y = y, w = 15, h = HEADER_HEIGHT}
    local rightArrowRect = {x = pageLabelX + pageLabelWidth, y = y, w = 15, h = HEADER_HEIGHT}

    if clicked and IsMouseInRect(mousePos, leftArrowRect.x, leftArrowRect.y, leftArrowRect.w, leftArrowRect.h) then
        if MainUI.ListPage > 1 then
            MainUI.ListPage -= 1
        end
    end
    if clicked and IsMouseInRect(mousePos, rightArrowRect.x, rightArrowRect.y, rightArrowRect.w, rightArrowRect.h) then
        if MainUI.ListPage < MainUI.TotalListPages then
            MainUI.ListPage += 1
        end
    end

    -- list info and rows
    local listY = y + HEADER_HEIGHT + 5
    DrawText(x + 10, listY, 14, Color3.new(1, 1, 1), "Scripts found: " .. tostring(#ScriptList), false)
    listY = listY + 20

    local per = MainUI.ListPerPage
    local startIndex = (MainUI.ListPage - 1) * per + 1
    local endIndex = startIndex + per - 1
    if endIndex > #ScriptList then
        endIndex = #ScriptList
    end

    for i = startIndex, endIndex do
        local info = ScriptList[i]
        if not info then break end

        local rowIndex = i - startIndex
        local rowY = listY + rowIndex * LIST_ROW_HEIGHT

        DrawRect(x + 5, rowY, w - 10, LIST_ROW_HEIGHT - 2, Color3.fromRGB(40, 40, 40), 0.8)

        local label = info.Path
        if string_len(label) > 60 then
            label = string_sub(label, 1, 57) .. "..."
        end

        DrawText(x + 10, rowY + 4, 14, Color3.new(1, 1, 1), label, false)

        local bx = x + w - BUTTON_WIDTH - 10
        local by = rowY + 2
        DrawButton(bx, by, BUTTON_WIDTH, BUTTON_HEIGHT, "Decompile", Color3.fromRGB(0, 160, 70), Color3.new(1, 1, 1))

        if clicked and IsMouseInRect(mousePos, bx, by, BUTTON_WIDTH, BUTTON_HEIGHT) then
            StartDecompileFor(info)
        end
    end
end

---- render popup (pager at bottom) ----
local function RenderPopup(mousePos, clicked:boolean)
    if not PopupUI.Visible then return end

    local x = PopupUI.X
    local y = PopupUI.Y
    local w = PopupUI.Width
    local h = PopupUI.Height

    DrawRect(x, y, w, h, Color3.fromRGB(20, 20, 25), 0.95)
    DrawRect(x, y, w, HEADER_HEIGHT, Color3.fromRGB(45, 45, 60), 1)

    DrawOutlinedText(x + 10, y + 8, 16, Color3.new(1, 1, 1), PopupUI.Title, false)
    DrawText(x + w - 50, y + 8, 16, Color3.new(1, 0.4, 0.4), "X", false)

    local leftDown = false
    if isleftpressed then leftDown = isleftpressed() end

    -- dragging
    if leftDown and not PopupUI.Dragging then
        if IsMouseInRect(mousePos, x, y, w, HEADER_HEIGHT) then
            PopupUI.Dragging = true
            PopupUI.DragOffset.x = mousePos.x - x
            PopupUI.DragOffset.y = mousePos.y - y
        end
    end

    if not leftDown then
        PopupUI.Dragging = false
    end

    if PopupUI.Dragging then
        PopupUI.X = mousePos.x - PopupUI.DragOffset.x
        PopupUI.Y = mousePos.y - PopupUI.DragOffset.y
        ClampPopupToScreen()
        x = PopupUI.X
        y = PopupUI.Y
    end

    -- close
    if clicked and IsMouseInRect(mousePos, x + w - 40, y, 40, HEADER_HEIGHT) then
        PopupUI.Visible = false
        return
    end

    -- content area bounds (leave space for bottom pager)
    local bottomPagerHeight = 24
    local contentTop = y + HEADER_HEIGHT + 5
    local contentBottom = y + h - bottomPagerHeight - 4
    local maxContentHeight = contentBottom - contentTop
    local per = PopupUI.LinesPerPage

    -- recompute per if height changed
    local expectedPer = maxContentHeight > 0 and math.floor(maxContentHeight / POPUP_LINE_HEIGHT) or 1
    if expectedPer < 1 then expectedPer = 1 end
    if expectedPer ~= per then
        PreparePopupLines()
        per = PopupUI.LinesPerPage
    end

    local startIndex = (PopupUI.PopupPage - 1) * per + 1
    local endIndex = startIndex + per - 1
    if endIndex > #PopupUI.Lines then
        endIndex = #PopupUI.Lines
    end

    local lineIndex = 0
    for i = startIndex, endIndex do
        local line = PopupUI.Lines[i]
        if not line then break end
        local ly = contentTop + lineIndex * POPUP_LINE_HEIGHT
        if ly + POPUP_LINE_HEIGHT > contentBottom then
            break
        end
        DrawText(x + 8, ly, 14, Color3.new(0.9, 0.9, 0.9), line, false)
        lineIndex += 1
    end

    -- bottom pager "< page / total >"
    local pagerY = y + h - bottomPagerHeight
    local headerCenterX = x + w * 0.5
    local pageText = "<  " .. tostring(PopupUI.PopupPage) .. "/" .. tostring(PopupUI.TotalPages) .. "  >"

    DrawRect(x, pagerY, w, bottomPagerHeight, Color3.fromRGB(30, 30, 40), 1)
    DrawText(headerCenterX, pagerY + 4, 14, Color3.new(0.8, 0.8, 0.8), pageText, true)

    local pageLabelWidth = 80
    local pageLabelX = headerCenterX - pageLabelWidth * 0.5
    local leftArrowRect = {x = pageLabelX - 15, y = pagerY, w = 15, h = bottomPagerHeight}
    local rightArrowRect = {x = pageLabelX + pageLabelWidth, y = pagerY, w = 15, h = bottomPagerHeight}

    if clicked and IsMouseInRect(mousePos, leftArrowRect.x, leftArrowRect.y, leftArrowRect.w, leftArrowRect.h) then
        if PopupUI.PopupPage > 1 then
            PopupUI.PopupPage -= 1
        end
    end
    if clicked and IsMouseInRect(mousePos, rightArrowRect.x, rightArrowRect.y, rightArrowRect.w, rightArrowRect.h) then
        if PopupUI.PopupPage < PopupUI.TotalPages then
            PopupUI.PopupPage += 1
        end
    end
end

---- runtime ----
ScanScripts()
RecomputeListPages()

local function RenderLoop()
    local m = GetMousePos()
    local mousePos = {x = m.x, y = m.y}
    local clicked = CheckClick()

    RecomputeListPages()

    RenderMain(mousePos, clicked)
    RenderPopup(mousePos, clicked)
end

RunService.Render:Connect(function()
    RenderLoop()
end)

print("[Decompiler UI] Loaded (paged), scripts:", #ScriptList)
