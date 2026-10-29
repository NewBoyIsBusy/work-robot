require("behaviours/doaction")
require("behaviours/standstill")
local RobotBrain = Class(Brain, function(self, inst) Brain._ctor(self, inst) end)
function RobotBrain:OnStart()
    self.bt = BT(self.inst, PriorityNode({
        WhileNode(function()
            return not self.inst.sg:HasStateTag("busy") and self.inst.components.wr_worker:CanWork()
        end, "Available", DoAction(self.inst, function(inst)
            return inst.components.wr_worker:NextAction()
        end, "Work", false)),
        StandStill(self.inst),
    }, .5))
end
function RobotBrain:OnStop() self.inst.components.wr_worker:Cancel() end
return RobotBrain
