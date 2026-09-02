-- MultiBuyer: shift-click vendor items to buy large amounts at once.
-- Modern rewrite of the BuyEmAll concept for WoW 12.1+.

local MB = {}
_G.MultiBuyer = MB

------------------------------------------------------------
-- Localization (enUS default, deDE override)
------------------------------------------------------------
local L = {
    CONFIRM     = "Are you sure you want to buy\n%d × %s?",
    STACK_PURCH = "Stack purchase",
    STACK_SIZE  = "Stack size",
    PARTIAL     = "Partial stack",
    MAX_PURCH   = "Maximum purchase",
    FIT         = "You can fit",
    AFFORD      = "You can afford",
    AVAILABLE   = "Vendor has",
    STACK       = "Stack",
    MAX         = "Max",
}
if GetLocale() == "deDE" then
    L.CONFIRM     = "Willst du wirklich\n%d × %s kaufen?"
    L.STACK_PURCH = "Stack kaufen/auffüllen"
    L.STACK_SIZE  = "Stackgröße"
    L.PARTIAL     = "Benötigt zum Auffüllen"
    L.MAX_PURCH   = "Maximaler Einkauf"
    L.FIT         = "Du hast Platz für"
    L.AFFORD      = "Du kannst dir leisten"
    L.AVAILABLE   = "Der Händler hat"
end

------------------------------------------------------------
-- Frame construction (pure Lua, no XML)
------------------------------------------------------------
local f = CreateFrame("Frame", "MultiBuyerFrame", UIParent, "BackdropTemplate")
f:SetSize(190, 120)
f:SetFrameStrata("HIGH")
f:SetToplevel(true)
f:EnableMouse(true)
f:SetClampedToScreen(true)
f:Hide()
f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
})

local editBox = CreateFrame("EditBox", "MultiBuyerEditBox", f, "InputBoxTemplate")
editBox:SetSize(70, 20)
editBox:SetPoint("TOP", 4, -16)
editBox:SetAutoFocus(true)
editBox:SetNumeric(true)
editBox:SetMaxLetters(8)
editBox:SetJustifyH("CENTER")

local leftArrow = CreateFrame("Button", "MultiBuyerLeftButton", f)
leftArrow:SetSize(18, 18)
leftArrow:SetPoint("RIGHT", editBox, "LEFT", -10, 0)
leftArrow:SetNormalTexture("Interface\\MoneyFrame\\Arrow-Left-Up")
leftArrow:SetPushedTexture("Interface\\MoneyFrame\\Arrow-Left-Down")
leftArrow:SetDisabledTexture("Interface\\MoneyFrame\\Arrow-Left-Disabled")

local rightArrow = CreateFrame("Button", "MultiBuyerRightButton", f)
rightArrow:SetSize(18, 18)
rightArrow:SetPoint("LEFT", editBox, "RIGHT", 4, 0)
rightArrow:SetNormalTexture("Interface\\MoneyFrame\\Arrow-Right-Up")
rightArrow:SetPushedTexture("Interface\\MoneyFrame\\Arrow-Right-Down")
rightArrow:SetDisabledTexture("Interface\\MoneyFrame\\Arrow-Right-Disabled")

local costText = f:CreateFontString("MultiBuyerCostText", "OVERLAY", "GameFontHighlight")
costText:SetPoint("TOP", editBox, "BOTTOM", -4, -8)
costText:SetWidth(175)

local function MakeButton(name, text, x, y)
    local b = CreateFrame("Button", "MultiBuyer" .. name .. "Button", f, "UIPanelButtonTemplate")
    b:SetSize(80, 22)
    b:SetPoint("BOTTOMLEFT", x, y)
    b:SetText(text)
    return b
end
local stackBtn  = MakeButton("Stack", L.STACK, 11, 36)
local maxBtn    = MakeButton("Max", L.MAX, 99, 36)
local okayBtn   = MakeButton("Okay", OKAY, 11, 12)
local cancelBtn = MakeButton("Cancel", CANCEL, 99, 12)
stackBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

------------------------------------------------------------
-- Auto-skinning: EllesmereUI (own skin API) and ElvUI
------------------------------------------------------------
if EllesmereUI and EllesmereUI.RegisterSkin then
    EllesmereUI.RegisterSkin("MultiBuyer", function(S)
        f:SetBackdrop(nil)
        S.Panel(f)
        S.Button(stackBtn)
        S.Button(maxBtn)
        S.Button(okayBtn)
        S.Button(cancelBtn)
        S.EditBox(editBox)
        S.Font(costText)
    end)
end

local function TrySkin()
    if EllesmereUI then return end -- EUI skin already registered above
    if not (ElvUI and C_AddOns.IsAddOnLoaded("ElvUI")) then return end
    local E = unpack(ElvUI)
    local S = E:GetModule("Skins", true)
    if not S then return end
    f:SetBackdrop(nil)
    f:SetTemplate("Transparent")
    S:HandleButton(stackBtn)
    S:HandleButton(maxBtn)
    S:HandleButton(okayBtn)
    S:HandleButton(cancelBtn)
    S:HandleEditBox(editBox)
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function ItemIsUnique(itemLink)
    local itemID = tonumber(strmatch(itemLink, "|Hitem:(%d+):"))
    if not itemID then return false end
    local tooltip = C_TooltipInfo.GetItemByID(itemID)
    if not tooltip or not tooltip.lines then return false end
    for _, line in ipairs(tooltip.lines) do
        if line.leftText == ITEM_UNIQUE then
            return true
        end
    end
    return false
end

local function HasBagEquippedInSlot(bagID)
    local invSlot = GetInventorySlotInfo("Bag" .. (bagID - 1) .. "Slot")
    return GetInventoryItemID("player", invSlot) ~= nil
end

-- How many of itemID still fit into the player's bags, and the item's stack size.
function MB:GetFreeBagSpace(itemID)
    local canFit = 0
    local itemFamily = C_Item.GetItemFamily(itemID) or 0
    local stackSize = select(8, C_Item.GetItemInfo(itemID)) or 1

    for bag = 0, NUM_BAG_SLOTS do
        local freeSlots, bagType = C_Container.GetContainerNumFreeSlots(bag)
        if bagType == 0 or (bag > 0 and HasBagEquippedInSlot(bag)
                and (bagType == itemFamily or bit.band(itemFamily, bagType) == bagType)) then
            canFit = canFit + (freeSlots or 0) * stackSize
            for slot = 1, C_Container.GetContainerNumSlots(bag) do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID == itemID then
                    canFit = canFit + (stackSize - (info.stackCount or 0))
                end
            end
        end
    end
    return canFit, stackSize
end

------------------------------------------------------------
-- Display
------------------------------------------------------------

-- Rounds an alt-currency purchase up to the next multiple of the vendor preset.
function MB:AltCurrRounding(amount)
    if self.AltCurrencyMode and amount % self.preset ~= 0 then
        for i = 1, self.NumAltCurrency do
            if self.AltCurrPrice[i] == 1 then
                return amount + (self.preset - (amount % self.preset))
            end
        end
    end
    return amount
end

function MB:SetStackClick()
    local increase = (self.partialFit == 0 and self.stack or self.partialFit) - (self.split % self.stack)
    self.stackClick = self.split + (increase == 0 and self.stack or increase)
end

function MB:UpdateDisplay(skipText)
    local minSplit = self.AltCurrencyMode and self.preset or 1
    leftArrow:SetEnabled(self.split > minSplit)
    rightArrow:SetEnabled(self.split < self.max)
    maxBtn:SetEnabled(self.split < self.max)

    self:SetStackClick()
    stackBtn:SetEnabled(self.max >= self.stackClick or self.split > self.stack)

    if not skipText then
        editBox:SetText(self.split)
        editBox:HighlightText()
    end

    if not self.AltCurrencyMode then
        local cost = ceil(self.split * (self.price / self.defaultStack))
        costText:SetText(GetMoneyString(cost, true))
    else
        local numPurchases = self:AltCurrRounding(self.split) / self.preset
        local parts = {}
        for i = 1, self.NumAltCurrency do
            parts[i] = format("%d |T%s:14|t", numPurchases * self.AltCurrPrice[i], self.AltCurrTex[i])
        end
        costText:SetText(table.concat(parts, "  "))
    end
end

function MB:SetSplit(value)
    self.split = max(self.AltCurrencyMode and self.preset or 1, min(value, self.max))
    self:UpdateDisplay()
end

------------------------------------------------------------
-- Purchasing
------------------------------------------------------------
local purchaseTicker

local function CancelPurchase()
    if purchaseTicker then
        purchaseTicker:Cancel()
        purchaseTicker = nil
    end
end

function MB:DoPurchase(amount)
    f:Hide()
    if strmatch(self.itemLink, "currency") then
        BuyMerchantItem(self.itemIndex, amount)
        return
    end

    CancelPurchase()
    local index, stack = self.itemIndex, self.stack
    local remaining = amount

    local function buyNext()
        local buy = min(remaining, stack)
        BuyMerchantItem(index, buy)
        remaining = remaining - buy
        if remaining <= 0 then CancelPurchase() end
    end

    buyNext()
    if remaining > 0 then
        -- ponytail: fixed 0.5s throttle between stack purchases, same pacing BuyEmAll used to avoid server throttling.
        purchaseTicker = C_Timer.NewTicker(0.5, buyNext)
    end
end

function MB:VerifyPurchase(amount)
    amount = self:AltCurrRounding(amount or self.split)
    if amount <= 0 then return end
    if amount > self.stack and amount > self.defaultStack and MultiBuyerConfirm then
        local dialog = StaticPopup_Show("MULTIBUYER_CONFIRM", amount, self.itemName)
        if dialog then dialog.data = amount end
    else
        self:DoPurchase(amount)
    end
end

------------------------------------------------------------
-- Show logic (hooked into merchant shift-click)
------------------------------------------------------------
function MB:ShowFrame(anchor)
    self.defaultStack = self.preset
    self:SetStackClick()
    f:ClearAllPoints()
    f:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 0)
    f:Show()
    self:UpdateDisplay()
end

function MB:AltCurrencyHandling(itemIndex, anchor)
    self.AltCurrencyMode = true
    self.NumAltCurrency = GetMerchantItemCostInfo(itemIndex)
    self.AltCurrTex, self.AltCurrPrice = {}, {}

    if self.NumAltCurrency <= 0 then
        self.afford = self.fit
    else
        self.afford = math.huge
        for i = 1, self.NumAltCurrency do
            local tex, price, link = GetMerchantItemCostItem(itemIndex, i)
            self.AltCurrTex[i] = tex
            self.AltCurrPrice[i] = price
            local owned
            if link and strmatch(link, "currency") then
                owned = C_CurrencyInfo.GetCurrencyInfoFromLink(link).quantity
            elseif link then
                owned = C_Item.GetItemCount(tonumber(strmatch(link, "item:(%d+):")), true)
            end
            if owned then
                self.afford = min(self.afford, floor(owned / price) * self.preset)
            end
        end
    end

    if self.itemID and ItemIsUnique(self.itemLink) then
        self.afford = 1
    end

    self.max = min(self.fit, self.afford)
    if self.available > -1 then
        self.max = min(self.max, self.available * self.preset)
    end

    if self.max == 0 then
        return
    elseif self.max == 1 then
        MerchantItemButton_OnClick(anchor, "LeftButton")
        return
    end

    self.split = self.preset
    self.partialFit = self.fit % self.stack
    self:ShowFrame(anchor)
end

function MB:OnModifiedClick(button, mouseButton)
    self.itemIndex = button:GetID()
    self.AltCurrencyMode = false

    local info = C_MerchantFrame.GetItemInfo(self.itemIndex)
    if not info then return end

    self.itemName = info.name
    self.price = info.price
    self.preset = info.stackCount
    self.available = info.numAvailable
    self.itemLink = GetMerchantItemLink(self.itemIndex)
    self.itemID = nil

    -- Purchasable things without an itemlink: plain confirm, no amount UI possible.
    if not self.itemLink then
        self.noLinkIndex = self.itemIndex
        StaticPopup_Show("MULTIBUYER_CONFIRM_NOLINK", self.preset, self.itemName)
        return
    end

    if strmatch(self.itemLink, "currency") then
        local currInfo = C_CurrencyInfo.GetCurrencyInfoFromLink(self.itemLink)
        local totalMax = currInfo.maxQuantity
        self.fit = (totalMax <= 0) and 10000000 or (totalMax - currInfo.quantity)
        self.stack = self.preset
        self.partialFit = 0
        if not self.price or self.price <= 0 then
            self:AltCurrencyHandling(self.itemIndex, button)
            return
        end
    else
        self.itemID = tonumber(strmatch(self.itemLink, "item:(%d+):"))
        self.fit, self.stack = self:GetFreeBagSpace(self.itemID)
        self.partialFit = self.fit % self.stack
    end

    if info.hasExtendedCost and (not self.price or self.price <= 0) then
        self:AltCurrencyHandling(self.itemIndex, button)
        return
    end

    if self.itemID and ItemIsUnique(self.itemLink) then
        self.afford = 1
    elseif not self.price or self.price <= 0 then
        self.afford = self.fit
    else
        self.afford = floor(GetMoney() / ceil(self.price / self.preset))
    end

    self.max = min(self.fit, self.afford)
    if self.available > -1 then
        self.max = min(self.max, self.available)
    end

    if self.max == 0 then
        return
    elseif self.max == 1 then
        MerchantItemButton_OnClick(button, "LeftButton")
        return
    end

    self.split = 1
    self:ShowFrame(button)
end

------------------------------------------------------------
-- Scripts
------------------------------------------------------------
local function Step(direction)
    MB:SetSplit(MB.split + direction * (MB.AltCurrencyMode and MB.preset or 1))
end
leftArrow:SetScript("OnClick", function() Step(-1) end)
rightArrow:SetScript("OnClick", function() Step(1) end)
maxBtn:SetScript("OnClick", function() MB:SetSplit(MB.max) end)
okayBtn:SetScript("OnClick", function() MB:VerifyPurchase(tonumber(editBox:GetText())) end)
cancelBtn:SetScript("OnClick", function() f:Hide() end)

stackBtn:SetScript("OnClick", function(btn, mouseButton)
    if mouseButton == "RightButton" then
        MB:SetSplit(MB.split <= MB.stack and 1 or MB.split - MB.stack)
    else
        MB:SetSplit(MB.stackClick)
    end
    if btn:IsEnabled() then MB:ShowTooltip(btn) else GameTooltip:Hide() end
end)

editBox:SetScript("OnTextChanged", function(box, userInput)
    if not userInput then return end
    local value = tonumber(box:GetText())
    if not value then return end
    if value > MB.max then
        value = MB.max
        box:SetText(value)
    end
    MB.split = max(1, value)
    MB:UpdateDisplay(true)
end)
editBox:SetScript("OnEnterPressed", function(box) MB:VerifyPurchase(tonumber(box:GetText())) end)
editBox:SetScript("OnEscapePressed", function() f:Hide() end)

f:SetScript("OnHide", function()
    StaticPopup_Hide("MULTIBUYER_CONFIRM")
    editBox:ClearFocus()
end)

------------------------------------------------------------
-- Tooltips for Stack/Max buttons
------------------------------------------------------------
local tooltipLines = {
    [true] = { -- stack button
        label = L.STACK_PURCH, field = "stackClick",
        { label = L.STACK_SIZE, field = "stack" },
        { label = L.PARTIAL, field = "partialFit" },
    },
    [false] = { -- max button
        label = L.MAX_PURCH, field = "max",
        { label = L.AFFORD, field = "afford" },
        { label = L.FIT, field = "fit" },
        { label = L.AVAILABLE, field = "available", Hide = function() return MB.available <= 1 end },
    },
}

function MB:ShowTooltip(btn)
    local lines = tooltipLines[btn == stackBtn]
    local headAmount = self[lines.field]
    GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:SetText(lines.label .. "|cFFFFFFFF - |r" .. GREEN_FONT_COLOR_CODE .. headAmount .. "|r")
    for _, line in ipairs(lines) do
        if not (line.Hide and line.Hide()) then
            local amount = self[line.field]
            local color = (amount == headAmount) and GREEN_FONT_COLOR or HIGHLIGHT_FONT_COLOR
            GameTooltip:AddDoubleLine(line.label, amount, 1, 1, 1, color.r, color.g, color.b)
        end
    end
    GameTooltip:Show()
end

for _, btn in ipairs({ stackBtn, maxBtn }) do
    btn:SetScript("OnEnter", function(b) MB:ShowTooltip(b) end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

------------------------------------------------------------
-- Popups
------------------------------------------------------------
StaticPopupDialogs["MULTIBUYER_CONFIRM"] = {
    preferredIndex = 3,
    text = L.CONFIRM,
    button1 = YES,
    button2 = NO,
    OnAccept = function(dialog) MB:DoPurchase(dialog.data) end,
    timeout = 0,
    hideOnEscape = true,
}
StaticPopupDialogs["MULTIBUYER_CONFIRM_NOLINK"] = {
    preferredIndex = 3,
    text = L.CONFIRM,
    button1 = YES,
    button2 = NO,
    OnAccept = function() BuyMerchantItem(MB.noLinkIndex) end,
    timeout = 0,
    hideOnEscape = true,
}

------------------------------------------------------------
-- Hooks & events
------------------------------------------------------------
local hooked = false
local function InstallHooks()
    if hooked then return end
    if type(MerchantItemButton_OnModifiedClick) ~= "function" or not MerchantFrame then return end
    hooked = true

    local orig = MerchantItemButton_OnModifiedClick
    MerchantItemButton_OnModifiedClick = function(button, mouseButton)
        if MerchantFrame.selectedTab == 1
                and IsShiftKeyDown() and not IsControlKeyDown()
                and not ChatFrame1EditBox:HasFocus()
                and not (C_AzeriteEmpoweredItem
                    and C_AzeriteEmpoweredItem.IsAzeriteEmpoweredItemByID(GetMerchantItemLink(button:GetID()) or 0)
                    and mouseButton == "RightButton") then
            MB:OnModifiedClick(button, mouseButton)
        else
            orig(button, mouseButton)
        end
    end

    MerchantFrame:HookScript("OnHide", function()
        f:Hide()
        CancelPurchase()
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("MERCHANT_SHOW")
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "MultiBuyer" then
        if MultiBuyerConfirm == nil then MultiBuyerConfirm = true end
        InstallHooks()
    elseif event == "PLAYER_LOGIN" then
        TrySkin()
    elseif event == "MERCHANT_SHOW" then
        InstallHooks()
    end
end)

------------------------------------------------------------
-- Slash command
------------------------------------------------------------
SLASH_MULTIBUYER1 = "/multibuyer"
SLASH_MULTIBUYER2 = "/mb"
SlashCmdList["MULTIBUYER"] = function(message)
    if message == "confirm" then
        MultiBuyerConfirm = not MultiBuyerConfirm
        print("MultiBuyer: " .. (MultiBuyerConfirm
            and "Bestätigung für Großeinkäufe |cff00ff00aktiviert|r."
            or "Bestätigung für Großeinkäufe |cffff0000deaktiviert|r."))
    else
        print("MultiBuyer: Shift-Klick auf Händler-Items zum Massenkauf. /mb confirm schaltet den Bestätigungsdialog um.")
    end
end
