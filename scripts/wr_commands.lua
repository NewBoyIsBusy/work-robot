local M={}
local Policy=require("wr_policy")
local json=require("json")
local names={farm="播种补耕",harvest="收菜",tend="照料",fish="收鱼",haul="搬运",cook="做肉丸",guard="站哨战斗"}
function M.Status(w)
    local tasks={}
    for _,k in ipairs(Policy.TASKS) do if w.config[k] then tasks[#tasks+1]=names[k] end end
    return (w.inst:HasTag("broken") and "损坏待修（给予石头）" or w.config.paused and "已暂停" or w.job and "工作中" or "待命").."；半径 "..w.config.radius.."；任务："..table.concat(tasks,"、")
        .."；补给箱："..(w.supply==nil and "自动" or w.supply:IsValid() and tostring(w.supply.GUID) or "已丢失")
        .."；交货箱："..(w.output==nil and "自动" or w.output:IsValid() and tostring(w.output.GUID) or "已丢失")
end
local function Near(player,r,radius)
    return r and r:IsValid() and r.components.wr_worker and not r:IsInLimbo()
        and player:GetDistanceSqToInst(r)<=radius*radius
end
function M.HandleOne(player,text,reply,options)
    if not player or not player:IsValid() or not player:HasTag("player") or player:HasTag("playerghost")
        or type(text)~="string" or #text>800 then return end
    text=text:match("^%s*(.-)%s*$")
    if text=="" or text=="帮助" then
        reply("先靠近机器人输入 /robot 选择。指令：种田 / 只收菜 / 收鱼 / 搬运 / 做饭 / 站哨 / 暂停 / 继续 / 状态 / 半径 12 / 中心 / 补给箱 / 交货箱 / 解绑。")
        return
    end
    if text=="选择" then
        local x,y,z=player.Transform:GetWorldPosition()
        local best,dist=nil,36
        for _,r in ipairs(TheSim:FindEntities(x,y,z,6,{"wr_robot"},{"INLIMBO"})) do
            local d=player:GetDistanceSqToInst(r)
            if d<dist then best=r;dist=d end
        end
        if best then player._wr_selected=best;reply("已选中勤务机器人 #"..best.GUID.."。"..M.Status(best.components.wr_worker))
        else reply("6 距离内没有勤务机器人。") end
        return
    end
    local r=player._wr_selected
    if not Near(player,r,80) then reply("请先靠近机器人输入 /robot 选择，或右键选中它。") return end
    local w=r.components.wr_worker
    if text=="状态" then reply("#"..r.GUID.." "..M.Status(w));return end
    -- Any new command invalidates a pending interpretation, including pause/reselection.
    w.commandrevision=(w.commandrevision or 0)+1
    if text=="中心" then
        if player:GetCurrentPlatform() then reply("请在陆地设置工作中心。") return end
        w:SetHome(player:GetPosition());reply("工作中心已移到你脚下。");return
    elseif text=="解绑" then w.supply=nil;w.output=nil;w:Sync();reply("已恢复自动选择箱子。");return
    elseif text=="补给箱" or text=="交货箱" then
        local x,y,z=player.Transform:GetWorldPosition()
        local best,dist=nil,16
        for _,e in ipairs(TheSim:FindEntities(x,y,z,4,{"structure"},{"INLIMBO"})) do
            if w:Chest(e) and w:Inside(e) and player:GetDistanceSqToInst(e)<dist then best=e;dist=player:GetDistanceSqToInst(e) end
        end
        if best then
            w[text=="补给箱" and "supply" or "output"]=best;w:Cancel();w:Sync()
            reply(text.."已绑定 #"..best.GUID.."。")
        else reply("请站在工作范围内的箱子旁，关闭箱子后再指定。") end
        return
    end
    local policy=Policy.Parse(text)
    if policy then w:ApplyPolicy(policy);reply(M.Status(w).."（本地指令，0 token）");return end
    if not options.enabled then reply("未识别为本地指令。DeepSeek 桥接未启用；输入 /robot 帮助 查看可用指令。");return end
    local client=TheNet:GetClientTableForUser(player.userid)
    if not options.allplayers and not (client and client.admin) then reply("AI 指令仅房主或管理员可用，本地指令不受此限制。");return end
    if player._wr_ai_time and GetTime()-player._wr_ai_time<10 then reply("请稍候再发 AI 指令。");return end
    player._wr_ai_time=GetTime()
    local revision=w.commandrevision
    local selectionversion=player._wr_selection_version
    reply("正在理解指令；日常工作不会持续调用 AI。")
    local finished=false
    local timer=player:DoTaskInTime(15,function()
        if not finished then finished=true;reply("AI 响应超时，原有设置保持不变。") end
    end)
    TheSim:QueryServer(options.endpoint or "http://127.0.0.1:8765/plan",function(body,success,code)
        if finished then return end
        finished=true;timer:Cancel()
        if not Near(player,r,80) or player._wr_selected~=r or w.commandrevision~=revision
            or player._wr_selection_version~=selectionversion then return end
        if not success or code~=200 or type(body)~="string" or #body>8192 then reply("桥接不可用，原有设置保持不变。");return end
        local ok,data=pcall(json.decode,body)
        if not ok or type(data)~="table" then reply("AI 返回无效，原有设置保持不变。");return end
        if data.policy and Policy.Validate(data.policy) and (options.apply or function(p)return w:ApplyPolicy(p)end)(data.policy) then
            reply(M.Status(w).."（"..(data.source=="cache" and "复用已缓存指令" or "AI 理解，本地执行").."）")
        elseif data.error=="unavailable" then reply("AI 桥接未就绪、预算已用尽或服务响应失败；原有设置保持不变。")
        else reply("这条指令目前无法执行；支持任务组合、半径和暂停/继续，暂不支持数量、定时或先后顺序。") end
    end,"POST",json.encode({text=text,current=options.current or w.config}))
end

function M.Label(r) return (r.components.wr_worker.label or "勤务机器人").." #"..r.GUID end
function M.Select(player,robots)
    player._wr_selection=robots
    player._wr_selected=robots[1]
    player._wr_selection_version=(player._wr_selection_version or 0)+1
end
local function Selection(player)
    local out={}
    for _,r in ipairs(player._wr_selection or {player._wr_selected}) do
        if Near(player,r,80) then out[#out+1]=r end
    end
    return out
end
local function Nearby(player)
    local x,y,z=player.Transform:GetWorldPosition()
    local es=TheSim:FindEntities(x,y,z,80,{"wr_robot"},{"INLIMBO"})
    table.sort(es,function(a,b)return player:GetDistanceSqToInst(a)<player:GetDistanceSqToInst(b) end)
    return es
end
function M.Handle(player,text,reply,options)
    if not player or not player:IsValid() or not player:HasTag("player") or player:HasTag("playerghost")
        or type(text)~="string" or #text>800 then return end
    text=text:match("^%s*(.-)%s*$")
    local address,order=text:match("^@([^%s]+)%s+(.+)$")
    if address then
        local group={}
        for _,r in ipairs(Nearby(player)) do
            if r.components.wr_worker.group==address then group[#group+1]=r end
        end
        if #group==0 or #group>16 then reply("该组未找到，或超过一次 16 台的上限。");return end
        if order:sub(1,1)=="@" then reply("一次只能指挥一个组。");return end
        M.Select(player,group)
        return M.Handle(player,order,reply,options)
    end
    if text=="" or text=="帮助" then
        reply("原版聊天窗：/robot 选择 [名字或编号]；列表；命名 小农；加选 小渔；编组 农田组；选择组 农田组；选择全部；@农田组 种田。")
        reply("任务：种田 / 只收菜 / 收鱼 / 搬运 / 做饭 / 站哨 / 暂停 / 继续 / 状态；设置：半径 12 / 中心 / 补给箱 / 交货箱 / 解绑。")
        return
    end
    if text=="列表" then
        local es=Nearby(player)
        if #es==0 then reply("80 距离内没有勤务机器人。") end
        for i,r in ipairs(es) do
            if i>24 then reply("仅显示最近的 24 台。");break end
            reply(M.Label(r).."；组："..(r.components.wr_worker.group or "未分组"))
        end
        return
    end
    local name=text:match("^选择%s+(.+)$")
    local add=text:match("^加选%s+(.+)$")
    local group=text:match("^选择组%s+(.+)$")
    if text=="选择" or name or add or group or text=="选择全部" then
        local chosen={}
        for _,r in ipairs(Nearby(player)) do
            if (text=="选择" and #chosen==0 and player:GetDistanceSqToInst(r)<=36)
                or text=="选择全部" or (group and r.components.wr_worker.group==group)
                or ((name or add) and (r.components.wr_worker.label==(name or add) or tostring(r.GUID)==(name or add))) then
                chosen[#chosen+1]=r
            end
        end
        if #chosen==0 then reply("未找到机器人；请靠近后输入 /robot 列表。");return end
        if (name or add) and #chosen>1 then reply("名字重复，请使用列表中的编号选择。");return end
        if add then for _,r in ipairs(Selection(player)) do if r~=chosen[1] then chosen[#chosen+1]=r end end end
        if #chosen>16 then reply("一次最多指挥 16 台，请分组选择。");return end
        M.Select(player,chosen)
        reply("已选中 "..#chosen.." 台："..M.Label(chosen[1])..(#chosen>1 and " 等。" or "。"))
        return
    end
    local robots=Selection(player)
    if #robots==0 then reply("请先输入 /robot 选择，或右键指挥机器人。");return end
    if text=="状态" then
        for _,r in ipairs(robots) do reply(M.Label(r).."："..M.Status(r.components.wr_worker)) end
        return
    end
    local label=text:match("^命名%s+(.+)$")
    local setgroup=text:match("^编组%s+(.+)$")
    if label or setgroup then
        local value=label or setgroup
        if #value>48 or value:find("[%c]") then reply("名字请控制在 16 个汉字以内。");return end
        if label and #robots~=1 then reply("命名前请只选择一台机器人。");return end
        for _,r in ipairs(robots) do r.components.wr_worker[label and "label" or "group"]=value end
        reply(label and "已命名为 "..label or "已将 "..#robots.." 台编入 "..setgroup)
        return
    end
    M.Select(player,robots) -- Invalidates previous in-flight requests for this player's selection.
    if Policy.Parse(text) or text=="中心" or text=="解绑" or text=="补给箱" or text=="交货箱" then
        local responses={}
        for _,r in ipairs(robots) do
            player._wr_selected=r
            M.HandleOne(player,text,function(s) responses[#responses+1]=M.Label(r).."："..s end,options)
        end
        player._wr_selected=robots[1]
        for _,s in ipairs(responses) do reply(s) end
        return
    end
    -- Parse once for the whole group. Only settings shared by the group are sent.
    local common={}
    for k,v in pairs(robots[1].components.wr_worker.config) do
        local same=true
        for i=2,#robots do if robots[i].components.wr_worker.config[k]~=v then same=false;break end end
        if same then common[k]=v end
    end
    local revisions={}
    for i=2,#robots do
        local w=robots[i].components.wr_worker
        w.commandrevision=(w.commandrevision or 0)+1;revisions[robots[i]]=w.commandrevision
    end
    local groupoptions={enabled=options.enabled,allplayers=options.allplayers,endpoint=options.endpoint,current=common}
    groupoptions.apply=function(policy)
        for r,version in pairs(revisions) do
            if not Near(player,r,80) or r.components.wr_worker.commandrevision~=version then return false end
        end
        for _,r in ipairs(robots) do r.components.wr_worker:ApplyPolicy(policy) end
        return true
    end
    M.HandleOne(player,text,function(s) reply((#robots>1 and "[整组 "..#robots.." 台，共用一次解析] " or "")..s) end,groupoptions)
end
return M
