--[[ Copyright (c) 2011 Mark "Mark.L" Lawlor

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE. --]]

class "ShakeFistAction" (HumanoidAction)

---@type ShakeFistAction
local ShakeFistAction = _G["ShakeFistAction"]

function ShakeFistAction:ShakeFistAction()
  self:HumanoidAction("shake_fist")
  self:setMustHappen(true)
end

local action_shake_fist_end = permanent"action_shake_fist_end"( function(humanoid)
  humanoid:finishAction()
end)


local function action_shake_fist_start(action, humanoid)
  if math.random(0, 1) == 1 then
    humanoid.last_move_direction = "east"
  else
    humanoid.last_move_direction = "south"
  end

  assert(humanoid.shake_fist_anim, "Error: no shaking fist animation for humanoid " .. humanoid.humanoid_class)
  action.must_happen = true
  humanoid:setAnimation(humanoid.shake_fist_anim, humanoid.last_move_direction == "east" and 0 or 1)
  humanoid:setTimer(TheApp.animation_manager:getAnimLength(humanoid.shake_fist_anim), action_shake_fist_end)
end

return action_shake_fist_start
