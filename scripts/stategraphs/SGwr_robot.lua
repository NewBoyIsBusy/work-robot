require("stategraphs/commonstates")
local states = {
    State{
        name="idle", tags={"idle"},
        onenter=function(inst)
            inst.components.locomotor:StopMoving()
            inst.AnimState:PlayAnimation(inst:HasTag("broken") and "idle_broken" or "idle", true)
        end,
    },
    State{
        name="work", tags={"busy"},
        onenter=function(inst)
            inst.components.locomotor:StopMoving()
            inst.AnimState:PlayAnimation("pickup")
            inst.sg:SetTimeout(2.5)
        end,
        timeline={TimeEvent(.6, function(inst) inst:PerformBufferedAction() end)},
        events={EventHandler("animover", function(inst) inst.sg:GoToState("idle") end)},
        ontimeout=function(inst) inst.sg:GoToState("idle") end,
    },
}
CommonStates.AddWalkStates(states, nil, nil, true)
return StateGraph("wr_robot", states, {CommonHandlers.OnLocomote(false, true)}, "idle", {
    ActionHandler(ACTIONS.WR_WORK, "work"),
})
