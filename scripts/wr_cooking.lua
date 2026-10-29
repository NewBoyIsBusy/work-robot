local M={}
local function Pot(w,e)
    return w:Available(e) and e.prefab=="cookpot" and e.components.stewer
        and e.components.container and not e.components.container:IsOpen()
        and not e.components.container.readonlycontainer
        and (not e.components.nearbyautocook or not e.components.nearbyautocook:CanManage())
end
local function Ingredients(container)
    local meat,berries
    for i=1,(container.maxslots or container:GetNumSlots()) do
        local e=container:GetItemInSlot(i)
        if e then
            if not meat and (e.prefab=="meat" or e.prefab=="smallmeat" or e.prefab=="monstermeat") then meat=e end
            if e.prefab=="berries" and e.components.stackable and e.components.stackable:StackSize()>=3 then berries=e end
        end
    end
    if meat and berries then return {meat,berries,berries,berries} end
end
function M.NextAction(w,es)
    local inv=w.inst.components.inventory
    local empty
    for _,e in ipairs(es) do
        if Pot(w,e) then
            if e.components.stewer:IsDone() and not inv:IsFull() then return w:MakeAction("cook_harvest",e) end
            if not e.components.stewer:IsCooking() and not e.components.stewer:IsDone()
                and e.components.container:IsEmpty() then empty=empty or e end
        end
    end
    if not empty then return nil end
    if Ingredients(inv) then return w:MakeAction("cook_start",empty) end
    -- Start a batch with an empty cargo hold; never split a partial recipe across pots.
    if inv:NumItems()>0 or inv:GetActiveItem() then return nil end
    for _,e in ipairs(es) do
        if (w.supply==nil or w.supply==e) and w:Available(e) and w:Chest(e) and Ingredients(e.components.container) then
            return w:MakeAction("cook_fetch",e)
        end
    end
end
function M.Perform(w,job)
    local e=job.target
    local inv=w.inst.components.inventory
    if job.kind=="cook_harvest" then
        return Pot(w,e) and not inv:IsFull() and e.components.stewer:Harvest(w.inst)
    elseif job.kind=="cook_fetch" then
        if not w:Chest(e) or inv:NumItems()>0 then return false end
        local ingredients=Ingredients(e.components.container)
        if not ingredients then return false end
        for _,item in ipairs(ingredients) do
            local unit=e.components.container:RemoveItem(item,false)
            if unit then inv:GiveItem(unit) else return false end
        end
        return true
    elseif job.kind=="cook_start" then
        if not Pot(w,e) or not e.components.container:IsEmpty() or e.components.stewer:IsCooking()
            or e.components.stewer:IsDone() then return false end
        local ingredients=Ingredients(inv)
        if not ingredients then return false end
        local prefabs={}
        for i,v in ipairs(ingredients) do prefabs[i]=v.prefab end
        local recipe=require("cooking").CalculateRecipe(e.prefab,prefabs)
        if recipe~="meatballs" then return false end
        local placed={}
        for i,item in ipairs(ingredients) do
            local unit=inv:RemoveItem(item,false)
            if unit==nil or not e.components.container:GiveItem(unit,i,nil,false) then
                if unit and unit:IsValid() then inv:GiveItem(unit) end
                for _,v in ipairs(placed) do if v:IsValid() then inv:GiveItem(e.components.container:RemoveItem(v,true)) end end
                return false
            end
            placed[#placed+1]=unit
        end
        e.components.stewer:StartCooking(w.inst)
        return e.components.stewer:IsCooking()
    end
    return false
end
return M
