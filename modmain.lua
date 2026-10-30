local G = GLOBAL
PrefabFiles = { "work_robot" }
G.TUNING.WORK_ROBOT = {}
G.STRINGS.NAMES.WORK_ROBOT = "勤务机器人"
G.STRINGS.RECIPE_DESC.WORK_ROBOT = "让机械小帮手照看农田和搬运收成。"
G.STRINGS.CHARACTERS.GENERIC.DESCRIBE.WORK_ROBOT = "右键进入设置视角，再给它选择箱子和工作目标。"

AddRecipe2("work_robot", {
    G.Ingredient("storage_robot", 1), G.Ingredient("transistor", 2), G.Ingredient("boards", 4),
}, G.TECH.SCIENCE_TWO, {image="storage_robot.tex", atlas=G.GetInventoryItemAtlas("storage_robot.tex")}, {"SCIENCE", "GARDENING"})

local action = AddAction("WR_WORK", "工作", function(act)
    local worker = act.doer.components.wr_worker
    return worker ~= nil and worker:Perform(act.wr_job) or false
end)
action.distance = 1.5
G.require("wr_focus")(env)
