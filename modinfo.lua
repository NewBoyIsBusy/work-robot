name = "勤务机器人"
description = "用原版瓦器人升级制作。通过原版聊天窗 /robot 指挥种田、收菜、收鱼、搬运、做饭和站哨；可选接入 DeepSeek。"
author = "wanzi"
version = "0.1.0"
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
        {description="16（四块地皮）",data=16}, {description="20（五块地皮）",data=20},
    }, default=12 },
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
