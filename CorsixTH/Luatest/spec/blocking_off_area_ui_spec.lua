--[[ Copyright (c) 2026 CorsixTH contributors

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
require("corsixth")
require("class_test_base")
require("utility")
require("persistance")

local saved_A = _G._A
_G._A = {cheats = {}}
require("map")
require("entity")
require("entities.humanoid")
require("entities.object")
require("entities.machine")
require("room")
require("humanoid_action")
require("world")
require("window")
require("dialogs.place_objects")
require("dialogs.edit_room")
require("dialogs.place_staff")
_G._A = saved_A

local UIEditRoom = _G["UIEditRoom"]
local UIPlaceStaff = _G["UIPlaceStaff"]

describe("special-map blocked-area UI connectivity", function()
  local function makeEditRoom(ingress_tiles, has_normal_spawns)
    local protected_result = true
    local strict_result = true
    local calls = {prospective = 0, strict = 0, protected = 0}
    local world = {}
    function world:getBlockingOffAreaIngressTiles()
      return ingress_tiles, has_normal_spawns
    end
    function world:_wouldBlockingOffAreaTopologyBeUnsafe()
      if #ingress_tiles == 0 then return nil, has_normal_spawns end
      calls.prospective = calls.prospective + 1
      return not protected_result, has_normal_spawns
    end

    local edit_room = {
      ui = {app = {world = world}},
      room = nil,
      blueprint_rect = {x = 2, y = 2, w = 2, h = 2},
    }
    setmetatable(edit_room, {__index = UIEditRoom})
    function edit_room:_getBlueprintDoorOutsideTile()
      return 7, 8
    end
    function edit_room:_withBlockedRoomBlueprint(callback)
      calls.strict = calls.strict + 1
      return callback()
    end
    function edit_room:checkReachability()
      return strict_result
    end

    return edit_room, calls,
      function(value) protected_result = value end,
      function(value) strict_result = value end
  end

  it("uses legacy strict room validation when there are no ingress anchors", function()
    local edit_room, calls, _, set_strict = makeEditRoom({}, false)

    assert.is_true(UIEditRoom._isBlueprintDoorNetworkValid(edit_room))
    assert.are.equal(0, calls.prospective)
    assert.are.equal(1, calls.strict)
    assert.are.equal(0, calls.protected)

    calls.strict = 0
    assert.is_true(UIEditRoom._isRoomPlacementNetworkValid(edit_room, {
      check_humanoids = true,
      include_door = true,
    }))
    assert.are.equal(0, calls.prospective)
    assert.are.equal(1, calls.strict)
    assert.are.equal(0, calls.protected)

    set_strict(false)
    assert.is_false(UIEditRoom._isBlueprintDoorNetworkValid(edit_room))
    assert.is_false(UIEditRoom._isRoomPlacementNetworkValid(edit_room, {
      check_humanoids = true,
      include_door = true,
    }))
  end)

  it("requires both heliport connectivity and strict fallback without normal spawns", function()
    local edit_room, _, set_protected, set_strict = makeEditRoom({{x = 1, y = 1}}, false)

    assert.is_true(UIEditRoom._isBlueprintDoorNetworkValid(edit_room))
    assert.is_true(UIEditRoom._isRoomPlacementNetworkValid(edit_room, {
      check_humanoids = true,
      include_door = true,
    }))

    set_protected(false)
    assert.is_false(UIEditRoom._isBlueprintDoorNetworkValid(edit_room))
    assert.is_false(UIEditRoom._isRoomPlacementNetworkValid(edit_room, {
      check_humanoids = true,
      include_door = true,
    }))

    set_protected(true)
    set_strict(false)
    assert.is_false(UIEditRoom._isBlueprintDoorNetworkValid(edit_room))
    assert.is_false(UIEditRoom._isRoomPlacementNetworkValid(edit_room, {
      check_humanoids = true,
      include_door = true,
    }))
  end)

  it("preserves local staff placement only when no ingress network exists", function()
    local ingress_tiles = {}
    local network_calls = 0
    local world = {
      map = {th = {}},
    }
    function world.map.th:getCellFlags(_, _, cache)
      cache.owner = 1
      cache.hospital = true
      cache.passable = true
      cache.roomId = 0
      return cache
    end
    function world:getRoom() return nil end
    function world:getBlockingOffAreaIngressTiles() return ingress_tiles, false end
    function world:isTileConnectedToBlockingOffAreaIngress(x, y, supplied_ingress)
      network_calls = network_calls + 1
      assert.are.equal(2, x)
      assert.are.equal(2, y)
      assert.is.equal(ingress_tiles, supplied_ingress)
      return false
    end

    local place_staff = {
      world = world,
      tile_x = 2,
      tile_y = 2,
      allow_in_rooms = true,
      ui = {hospital = {getPlayerIndex = function() return 1 end}},
      profile = {isType = function() return false end},
    }

    assert.is_true(UIPlaceStaff._isValidStaffPlacement(place_staff))
    assert.are.equal(0, network_calls)

    ingress_tiles = {{x = 1, y = 1}}
    assert.is_false(UIPlaceStaff._isValidStaffPlacement(place_staff))
    assert.are.equal(1, network_calls)
  end)
end)
