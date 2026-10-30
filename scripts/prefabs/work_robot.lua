local assets = { Asset("ANIM", "anim/storage_robot.zip"), Asset("INV_IMAGE", "storage_robot") }
local brain = require("brains/wr_robotbrain")

local function OnPickup(inst)
    inst.components.wr_worker:Cancel()
    inst.components.inventory:DropEverything()
    inst.components.locomotor:Stop()
    inst.components.locomotor:Clear()
    inst:ClearBufferedAction()
    inst.sg:GoToState("idle")
end

local function fn()
    local inst = CreateEntity()
    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddDynamicShadow()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()
    MakeCharacterPhysics(inst, 50, .4)
    inst.Transform:SetFourFaced()
    inst.AnimState:SetBank("storage_robot")
    inst.AnimState:SetBuild("storage_robot")
    inst.AnimState:PlayAnimation("idle", true)
    inst.AnimState:Hide("light_on")
    inst.AnimState:SetMultColour(.72, .92, 1, 1)
    inst.DynamicShadow:SetSize(2.8, 1.7)
    inst.MiniMapEntity:SetIcon("storage_robot.png")
    inst:AddTag("companion")
    inst:AddTag("NOBLOCK")
    inst:AddTag("wr_robot")
    inst._wr_state = net_string(inst.GUID,"work_robot.state","wr_statedirty")
    -- Server and client GUIDs differ. This replicated token lets a focus RPC
    -- resolve the same robot entity on every peer.
    inst._wr_id = net_string(inst.GUID,"work_robot.id")
    inst.entity:SetPristine()
    if not TheWorld.ismastersim then return inst end
    inst._wr_id:set(tostring(inst.GUID))

    inst:AddComponent("inspectable")
    inst:AddComponent("inventory")
    inst.components.inventory.maxslots = 6
    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:ChangeImageName("storage_robot")
    inst.components.inventoryitem.nobounce = true
    inst.components.inventoryitem:SetOnPickupFn(OnPickup)
    inst.components.inventoryitem:SetOnDroppedFn(function()
        inst:DoTaskInTime(0, function() inst.components.wr_worker:SetHome(inst:GetPosition()) end)
    end)
    inst:AddComponent("locomotor")
    inst.components.locomotor.walkspeed = 4
    inst.components.locomotor.runspeed = 4
    inst.components.locomotor:SetTriggersCreep(false)
    inst.components.locomotor.pathcaps = {ignorecreep=true}
    inst:AddComponent("farmtiller")
    inst:AddComponent("health")
    inst.components.health:SetMaxHealth(300)
    inst.components.health:SetMinHealth(1)
    inst:AddComponent("combat")
    inst.components.combat:SetDefaultDamage(20)
    inst.components.combat:SetAttackPeriod(1.5)
    inst.components.combat:SetRange(2,2.5)
    inst:AddComponent("talker")
    inst.components.talker.fontsize=24
    inst.components.talker.font=TALKINGFONT
    inst:AddComponent("wr_worker")
    inst:AddComponent("trader")
    inst.components.trader:SetAcceptTest(function(_,item)
        return item.prefab=="rocks" and inst.components.health:GetPercent()<1
    end)
    inst.components.trader:SetOnAccept(function()
        inst.components.health:SetInvincible(false)
        inst.components.health:DoDelta(30)
        inst:RemoveTag("broken");inst:RemoveTag("notarget")
        inst.sg:GoToState("idle")
    end)
    local function CheckBroken()
        if inst.components.health.currenthealth<=1 then
            -- Keep the broken robot clickable so the explicit repair action is
            -- always available.  "notarget" was why v0.2 repairs appeared dead.
            inst:AddTag("broken");inst:RemoveTag("notarget")
            inst.components.health:SetInvincible(true)
            inst.components.wr_worker:Cancel()
            inst:ClearBufferedAction()
            inst.components.locomotor:Stop()
            inst.sg:GoToState("idle")
        end
    end
    inst:ListenForEvent("healthdelta",CheckBroken)
    inst:SetStateGraph("SGwr_robot")
    inst:SetBrain(brain)
    inst:ListenForEvent("onremove", function() inst.components.wr_worker:Cancel() end)
    inst:DoTaskInTime(0, function()
        if inst.components.wr_worker.home == nil and inst.components.wr_worker.region == nil then inst.components.wr_worker:SetHome(inst:GetPosition()) end
        CheckBroken()
        inst.components.wr_worker:Sync()
    end)
    return inst
end

return Prefab("work_robot", fn, assets, {"farm_soil"})
