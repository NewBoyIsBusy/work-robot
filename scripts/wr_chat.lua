return function(env)
    local G=env.GLOBAL
    local Commands=G.require("wr_commands")
    local options={enabled=env.GetModConfigData("AI_BRIDGE")==true,allplayers=env.GetModConfigData("AI_ALL_PLAYERS")==true}
    local function Reply(player,message)
        if player:IsValid() and player.userid then
            env.SendModRPCToClient(env.GetClientModRPC("work_robot","reply"),player.userid,"[勤务机器人] "..message)
        end
    end
    env.AddClientModRPCHandler("work_robot","reply",function(message)
        if type(message)=="string" and G.ChatHistory then G.ChatHistory:SendCommandResponse(message) end
    end)
    env.AddModRPCHandler("work_robot","command",function(player,text)
        if player._wr_command_time and G.GetTime()-player._wr_command_time<.3 then return end
        player._wr_command_time=G.GetTime()
        Commands.Handle(player,text,function(s) Reply(player,s) end,options)
    end)
    env.AddUserCommand("robot",{
        prettyname="勤务机器人",desc="指挥选中的机器人。输入 /robot 帮助 查看用法。",
        permission=G.COMMAND_PERMISSION.USER,slash=true,usermenu=false,servermenu=false,
        params={},vote=false,
        localfn=function(params)
            env.SendModRPCToServer(env.GetModRPC("work_robot","command"),params.rest or "帮助")
        end,
    })
    local select=env.AddAction("WR_SELECT","指挥机器人",function(act)
        if act.target and act.target.components.wr_worker and act.doer:HasTag("player") then
            Commands.Select(act.doer,{act.target})
            Reply(act.doer,"已选中 #"..act.target.GUID.."。在原版聊天窗输入 /robot 帮助。")
            return true
        end
        return false
    end)
    select.rmb=true;select.priority=3;select.distance=3
    env.AddComponentAction("SCENE","wr_worker",function(inst,doer,actions,right)
        if right and not doer:HasTag("playerghost") then table.insert(actions,select) end
    end)
    env.AddStategraphActionHandler("wilson",G.ActionHandler(select,"doshortaction"))
    env.AddStategraphActionHandler("wilson_client",G.ActionHandler(select,"doshortaction"))
end
