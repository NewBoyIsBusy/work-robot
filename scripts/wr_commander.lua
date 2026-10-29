return function(env)
    local G=env.GLOBAL
    local json=G.require("json")
    local Now=G.GetStaticTime or G.GetTime
    env.AddPrefabPostInit("world",function(inst)
        if inst.ismastersim then inst:AddComponent("wr_workzones") end
    end)
    env.AddPrefabPostInit("work_robot",function(inst)
        if G.TheWorld.ismastersim and G.TheWorld.components.wr_workzones then G.TheWorld.components.wr_workzones:Register(inst) end
    end)
    local function Reply(player,message)
        local zones=G.TheWorld.components.wr_workzones
        if zones and player and player:IsValid() and player.userid then
            env.SendModRPCToClient(env.GetClientModRPC("work_robot","commander_state"),player.userid,json.encode(zones:Snapshot(message)))
        end
    end
    env.AddModRPCHandler("work_robot","commander_query",function(player)
        if not player or not player:IsValid() or not player:HasTag("player") then return end
        if player._wr_map_query and Now()-player._wr_map_query<.5 then return end
        player._wr_map_query=Now();Reply(player)
    end)
    env.AddModRPCHandler("work_robot","commander_apply",function(player,encoded)
        if not player or not player:IsValid() or not player:HasTag("player") then return end
        if player._wr_map_apply and Now()-player._wr_map_apply<.3 then Reply(player,"操作太快，请稍候再试。");return end
        player._wr_map_apply=Now()
        if type(encoded)~="string" or #encoded>4096 then return end
        local ok,req=G.pcall(json.decode,encoded)
        local zones=G.TheWorld.components.wr_workzones
        if not ok or not zones then Reply(player,"区域数据无效。");return end
        local success,message=zones:Apply(player,req)
        Reply(player,message)
    end)
end
