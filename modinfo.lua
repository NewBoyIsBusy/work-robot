name = "勤务机器人"
description = "原版地图框选工作区域，点击分配机器人种田、收鱼、搬运、做饭与站哨。带卡住检测和绕行，全部工作无需 API；聊天指令和 DeepSeek 可选。"
author = "wanzi"
version = "0.2.0"
api_version = 10
dst_compatible = true
all_clients_require_mod = true
client_only_mod = false
forcemanifest = false
configuration_options = {
    { name="AI_BRIDGE",label="DeepSeek 本机桥接",options={
        {description="关闭",data=false},{description="启用（需运行桥接程序）",data=true},
    },default=false },
    { name="AI_ALL_PLAYERS",label="允许所有玩家使用 AI",options={
        {description="仅房主/管理员",data=false},{description="所有玩家",data=true},
    },default=false },
    { name = "RADIUS", label = "工作半径", options = {
        {description="8（两块地皮）",data=8}, {description="12（三块地皮）",data=12},
        {description="24（六块地皮）",data=24}, {description="40（十块地皮）",data=40},
        {description="80（二十块地皮）",data=80},
    }, default=24 },
}
local settings = {
    {"FARM", "播种与补耕"}, {"HARVEST", "收获成熟作物"},
    {"TEND", "照料作物"}, {"FISH", "收取捕鱼器"}, {"HAUL", "搬运地面物品"},
}
for i=1,#settings do
    local setting=settings[i]
    configuration_options[#configuration_options+1] = {
        name=setting[1], label=setting[2], options={
            {description="开启",data=true}, {description="关闭",data=false},
        }, default=true,
    }
end
