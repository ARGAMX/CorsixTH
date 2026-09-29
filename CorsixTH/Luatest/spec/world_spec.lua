--[[ Copyright (c) 2026 Bruno Lima
Copyright (c) 2026 Joshua "gojomoso1" DeVries

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

-- Load the modules world.lua depends on in the same order as app.lua does.
-- world.lua also reads the global _A (the app) while loading, so provide a
-- minimal stub for that.
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
_G._A = saved_A

local World = _G["World"]
local EntityMap = _G["EntityMap"]
local Humanoid = _G["Humanoid"]

describe("world.lua: ", function()
  local function makeWorld(entities)
    local world = {entities = entities, entities_to_destroy = {}}
    setmetatable(world, {__index = World})
    return world
  end

  local function makeEntity(name)
    local entity = {
      name = name,
      ticks = true,
      tick_count = 0,
    }
    function entity:tick()
      self.tick_count = self.tick_count + 1
    end
    function entity:onDestroy()
      self.destroyed = true
    end
    return entity
  end

  -- Simulates the entity tick loop of World:onTick, including the guard that
  -- skips entities queued for destruction and the flush after the loop.
  local function runTickLoop(world)
    for _, entity in ipairs(world.entities) do
      if entity.ticks and not entity.to_destroy then
        world.current_tick_entity = entity
        entity:tick()
      end
    end
    world.current_tick_entity = nil
    world:_flushDestroyedEntities()
  end

  -- Simulates the entity tickDay loop of World:onEndDay. Mirrors the real
  -- structure: humanoids and plants are dispatched separately, and plants
  -- also set current_tick_entity so deferred destruction applies to them.
  local function runTickDayLoop(world)
    for _, entity in ipairs(world.entities) do
      if entity.kind == "humanoid" and not entity.to_destroy then
        world.current_tick_entity = entity
        entity:tickDay()
      elseif entity.kind == "plant" and not entity.to_destroy then
        world.current_tick_entity = entity
        entity:tickDay()
      end
    end
    world.current_tick_entity = nil
    world:_flushDestroyedEntities()
  end

  -- Simulates the entity checkForDeadlock loop of World:onEndMonth.
  local function runDeadlockLoop(world)
    for _, entity in ipairs(world.entities) do
      if entity.checkForDeadlock and not entity.to_destroy then
        world.current_tick_entity = entity
        entity:checkForDeadlock()
      end
    end
    world.current_tick_entity = nil
    world:_flushDestroyedEntities()
  end

  it("removes entity immediately outside an entities loop", function()
    local e1, e2 = makeEntity("e1"), makeEntity("e2")
    local world = makeWorld({e1, e2})

    world:destroyEntity(e1)

    assert.are.equal(1, #world.entities)
    assert.is.equal(e2, world.entities[1])
    assert.is_true(e1.destroyed)
    assert.are.equal(0, #world.entities_to_destroy)
  end)

  it("destroys entity not present in the list", function()
    local e1 = makeEntity("e1")
    local world = makeWorld({})

    world:destroyEntity(e1)

    assert.is_true(e1.destroyed)
    assert.are.equal(0, #world.entities)
  end)

  it("defers removal while iterating the entities list", function()
    local e1, e2, e3 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3")
    local world = makeWorld({e1, e2, e3})
    world.current_tick_entity = e2

    world:destroyEntity(e2)

    assert.are.equal(3, #world.entities)
    assert.are.equal(1, #world.entities_to_destroy)
    assert.is_true(e2.destroyed)
    assert.is_true(e2.to_destroy)

    world.current_tick_entity = nil
    world:_flushDestroyedEntities()

    assert.are.equal(2, #world.entities)
    assert.is.equal(e1, world.entities[1])
    assert.is.equal(e3, world.entities[2])
    assert.is_nil(e2.to_destroy)
    assert.are.equal(0, #world.entities_to_destroy)
  end)

  it("queues an entity for destruction only once", function()
    local e1 = makeEntity("e1")
    local world = makeWorld({e1})
    world.current_tick_entity = e1

    world:destroyEntity(e1)
    world:destroyEntity(e1)

    assert.are.equal(1, #world.entities_to_destroy)
  end)

  it("flushes multiple deferred destructions in one pass", function()
    local e1, e2, e3, e4 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3"), makeEntity("e4")
    local world = makeWorld({e1, e2, e3, e4})
    world.current_tick_entity = e2

    world:destroyEntity(e2)
    world:destroyEntity(e4)

    world.current_tick_entity = nil
    world:_flushDestroyedEntities()

    assert.are.equal(2, #world.entities)
    assert.is.equal(e1, world.entities[1])
    assert.is.equal(e3, world.entities[2])
  end)

  it("flush does nothing with an empty queue", function()
    local e1 = makeEntity("e1")
    local world = makeWorld({e1})

    world:_flushDestroyedEntities()

    assert.are.equal(1, #world.entities)
    assert.are.equal(0, #world.entities_to_destroy)
  end)

  it("does not skip entities when an earlier entity is destroyed mid-loop", function()
    local e1, e2, e3, e4 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3"), makeEntity("e4")
    local world = makeWorld({e1, e2, e3, e4})
    e2.tick = function(self)
      self.tick_count = self.tick_count + 1
      -- Destroy an entity that already ticked (before the current index) and
      -- one that has not ticked yet (after the current index). Without the
      -- deferred removal, e3 would be skipped.
      world:destroyEntity(e1)
      world:destroyEntity(e4)
    end

    runTickLoop(world)

    assert.are.equal(1, e1.tick_count)
    assert.are.equal(1, e2.tick_count)
    assert.are.equal(1, e3.tick_count)
    assert.is_true(e4.destroyed)
    assert.are.equal(0, e4.tick_count)
    assert.are.equal(2, #world.entities)
    assert.is.equal(e2, world.entities[1])
    assert.is.equal(e3, world.entities[2])
  end)

  it("does not tick an entity destroyed earlier in the same loop", function()
    local e1, e2, e3 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3")
    local world = makeWorld({e1, e2, e3})
    e1.tick = function(self)
      self.tick_count = self.tick_count + 1
      world:destroyEntity(e3)
    end

    runTickLoop(world)

    assert.are.equal(1, e1.tick_count)
    assert.are.equal(1, e2.tick_count)
    assert.is_true(e3.destroyed)
    assert.are.equal(0, e3.tick_count)
    assert.are.equal(2, #world.entities)
  end)

  it("destroys itself during its tick and is removed after the loop", function()
    local e1, e2 = makeEntity("e1"), makeEntity("e2")
    local world = makeWorld({e1, e2})
    e1.tick = function(self)
      self.tick_count = self.tick_count + 1
      world:destroyEntity(self)
    end

    runTickLoop(world)

    assert.are.equal(1, e1.tick_count)
    assert.are.equal(1, e2.tick_count)
    assert.is_true(e1.destroyed)
    assert.are.equal(1, #world.entities)
    assert.is.equal(e2, world.entities[1])
  end)

  it("handles cascading destructions during a single loop", function()
    local e1, e2, e3, e4 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3"), makeEntity("e4")
    local world = makeWorld({e1, e2, e3, e4})
    e2.tick = function(self)
      self.tick_count = self.tick_count + 1
      world:destroyEntity(e3)
    end
    -- Destroying e3 destroys e4 as well, mimicking a room crashing and
    -- taking its objects with it.
    e3.onDestroy = function(self)
      self.destroyed = true
      world:destroyEntity(e4)
    end

    runTickLoop(world)

    assert.are.equal(1, e1.tick_count)
    assert.are.equal(1, e2.tick_count)
    assert.is_true(e3.destroyed)
    assert.is_true(e4.destroyed)
    assert.are.equal(0, e3.tick_count)
    assert.are.equal(0, e4.tick_count)
    assert.are.equal(2, #world.entities)
  end)

  it("ticks entities added to the list during the loop", function()
    local e1, e2, e3 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3")
    local world = makeWorld({e1, e2, e3})
    local e4 = makeEntity("e4")
    e2.tick = function(self)
      self.tick_count = self.tick_count + 1
      world.entities[#world.entities + 1] = e4
    end

    runTickLoop(world)

    assert.are.equal(1, e1.tick_count)
    assert.are.equal(1, e2.tick_count)
    assert.are.equal(1, e3.tick_count)
    assert.are.equal(1, e4.tick_count)
    assert.are.equal(4, #world.entities)
  end)

  it("recovers when the loop is interrupted before flushing", function()
    local e1, e2, e3 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3")
    local world = makeWorld({e1, e2, e3})
    world.current_tick_entity = e1
    world:destroyEntity(e2)
    -- The error handling in app.lua clears current_tick_entity without a
    -- flush, so the queue survives into the next loop.
    world.current_tick_entity = nil

    runTickLoop(world)

    assert.are.equal(1, e1.tick_count)
    assert.are.equal(1, e3.tick_count)
    assert.is_true(e2.destroyed)
    assert.are.equal(0, e2.tick_count)
    assert.are.equal(2, #world.entities)
  end)

  it("does nothing when destroying an already queued entity outside a loop", function()
    local e1, e2 = makeEntity("e1"), makeEntity("e2")
    local world = makeWorld({e1, e2})
    world.current_tick_entity = e1
    world:destroyEntity(e2)
    world.current_tick_entity = nil

    world:destroyEntity(e2)

    assert.are.equal(2, #world.entities)
    assert.is_true(e2.to_destroy)
    world:_flushDestroyedEntities()
    assert.are.equal(1, #world.entities)
  end)

  it("destroys immediately outside a loop even with pending queued entities", function()
    local e1, e2, e3 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3")
    local world = makeWorld({e1, e2, e3})
    world.current_tick_entity = e1
    world:destroyEntity(e1)
    world.current_tick_entity = nil

    world:destroyEntity(e3)

    assert.is_true(e3.destroyed)
    assert.is_nil(e3.to_destroy)
    assert.are.equal(1, #world.entities_to_destroy)
    world:_flushDestroyedEntities()
    assert.are.equal(1, #world.entities)
    assert.is.equal(e2, world.entities[1])
  end)

  it("reuses the queue across consecutive loops", function()
    local e1, e2, e3 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3")
    local world = makeWorld({e1, e2, e3})
    e1.tick = function(self)
      self.tick_count = self.tick_count + 1
      world:destroyEntity(e2)
    end

    runTickLoop(world)

    assert.are.equal(2, #world.entities)
    assert.is_true(e2.destroyed)
    assert.are.equal(0, #world.entities_to_destroy)
    e3.tick = function(self)
      self.tick_count = self.tick_count + 1
      world:destroyEntity(e1)
    end

    runTickLoop(world)

    assert.are.equal(1, #world.entities)
    assert.is.equal(e3, world.entities[1])
    assert.are.equal(2, e1.tick_count)
    assert.are.equal(2, e3.tick_count)
    assert.are.equal(0, #world.entities_to_destroy)
  end)

  it("does not skip entities destroyed during the tickDay loop", function()
    local e1 = makeEntity("e1")
    local e2, e3, e4 = makeEntity("e2"), makeEntity("e3"), makeEntity("e4")
    e1.kind, e2.kind, e3.kind, e4.kind = "humanoid", "humanoid", "humanoid", "humanoid"
    local world = makeWorld({e1, e2, e3, e4})
    e2.tickDay = function(self)
      self.tick_count = self.tick_count + 1
      world:destroyEntity(e1)
      world:destroyEntity(e4)
    end
    e1.tickDay = function(self) self.tick_count = self.tick_count + 1 end
    e3.tickDay = function(self) self.tick_count = self.tick_count + 1 end

    runTickDayLoop(world)

    assert.are.equal(1, e1.tick_count)
    assert.are.equal(1, e2.tick_count)
    assert.are.equal(1, e3.tick_count)
    assert.is_true(e4.destroyed)
    assert.are.equal(0, e4.tick_count)
    assert.are.equal(2, #world.entities)
  end)

  it("defers destruction triggered by a plant during the tickDay loop", function()
    local plant = makeEntity("plant")
    local e2, e3 = makeEntity("e2"), makeEntity("e3")
    plant.kind, e2.kind, e3.kind = "plant", "humanoid", "humanoid"
    local world = makeWorld({plant, e2, e3})
    plant.tickDay = function(self)
      self.tick_count = self.tick_count + 1
      world:destroyEntity(e3)
    end
    e2.tickDay = function(self) self.tick_count = self.tick_count + 1 end

    runTickDayLoop(world)

    assert.are.equal(1, plant.tick_count)
    assert.are.equal(1, e2.tick_count)
    assert.is_true(e3.destroyed)
    assert.are.equal(0, e3.tick_count)
    assert.are.equal(2, #world.entities)
    assert.is.equal(plant, world.entities[1])
    assert.is.equal(e2, world.entities[2])
  end)

  it("does not skip entities destroyed during the checkForDeadlock loop", function()
    local e1, e2, e3 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3")
    local world = makeWorld({e1, e2, e3})
    e1.checkForDeadlock = function(self)
      self.tick_count = self.tick_count + 1
      world:destroyEntity(e3)
    end
    e2.checkForDeadlock = function(self) self.tick_count = self.tick_count + 1 end

    runDeadlockLoop(world)

    assert.are.equal(1, e1.tick_count)
    assert.are.equal(1, e2.tick_count)
    assert.is_true(e3.destroyed)
    assert.are.equal(2, #world.entities)
  end)



  it("destroys an entity not in the list during a loop without side effects", function()
    local e1, e2 = makeEntity("e1"), makeEntity("e2")
    local stray = makeEntity("stray")
    local world = makeWorld({e1, e2})
    world.current_tick_entity = e1

    world:destroyEntity(stray)

    assert.is_true(stray.destroyed)
    assert.is_true(stray.to_destroy)
    assert.are.equal(1, #world.entities_to_destroy)
    world.current_tick_entity = nil
    world:_flushDestroyedEntities()
    assert.are.equal(2, #world.entities)
    assert.is_nil(stray.to_destroy)
    assert.are.equal(0, #world.entities_to_destroy)
  end)

  it("flush is safe to call twice in a row", function()
    local e1, e2 = makeEntity("e1"), makeEntity("e2")
    local world = makeWorld({e1, e2})
    world.current_tick_entity = e1
    world:destroyEntity(e2)
    world.current_tick_entity = nil

    world:_flushDestroyedEntities()
    world:_flushDestroyedEntities()

    assert.are.equal(1, #world.entities)
    assert.are.equal(0, #world.entities_to_destroy)
  end)

  it("destroys from a nested iteration still defer until the outer loop ends", function()
    local e1, e2, e3 = makeEntity("e1"), makeEntity("e2"), makeEntity("e3")
    local world = makeWorld({e1, e2, e3})
    e2.tick = function(self)
      self.tick_count = self.tick_count + 1
      -- Simulates code that iterates world.entities from inside a tick.
      for _, inner in ipairs(world.entities) do
        if inner == e3 then
          world:destroyEntity(e3)
        end
      end
    end

    runTickLoop(world)

    assert.are.equal(1, e1.tick_count)
    assert.are.equal(1, e2.tick_count)
    assert.is_true(e3.destroyed)
    assert.are.equal(0, e3.tick_count)
    assert.are.equal(2, #world.entities)
  end)

  it("adds rat buckets when loading an upstream version 265 save", function()
    local entity_map = {
      width = 1,
      height = 1,
      entity_map = {{{humanoids = {}, objects = {}}}},
    }
    setmetatable(entity_map, {__index = EntityMap})

    entity_map:afterLoad(265, 266)

    assert.same({}, entity_map.entity_map[1][1].rats)

    local rat = {}
    entity_map.entity_map[1][1].rats = {rat}
    entity_map:afterLoad(265, 266)
    assert.is.equal(rat, entity_map.entity_map[1][1].rats[1])
  end)

  it("detects a moving rat across the full proximity radius", function()
    local rat = {
      tile_x = 64,
      tile_y = 64,
      th = {getPosition = function() return -32, -16 end},
    }
    local map = {width = 128, height = 128}
    setmetatable(map, {__index = Map})
    local world = makeWorld({rat})
    world.map = map
    world.entity_map = {
      getRatsAtCoordinate = function(_, x, y)
        return x == rat.tile_x and y == rat.tile_y and {rat} or {}
      end,
    }

    -- The rat is drawn one tile west of its entity-map tile while moving.
    -- This cursor is exactly 24 pixels farther west, crossing another tile.
    assert.is_true(world:isNearRat(-56, 2000))
    assert.is_false(world:isNearRat(-57, 2000))
  end)
  describe("blocked-area connectivity", function()
    local function makeFlagMap(initial)
      local flags = {}
      for key, values in pairs(initial) do
        flags[key] = {}
        for name, value in pairs(values) do flags[key][name] = value end
      end

      local map = {}
      function map:getCellFlags(x, y)
        return flags[x .. ":" .. y]
      end
      function map:setCellFlags(x, y, changed)
        local tile = flags[x .. ":" .. y]
        for name, value in pairs(changed) do tile[name] = value end
      end
      function map:getCell()
        return 0
      end
      return map, flags
    end

    it("allows a humanoid to path from a non-passable starting tile", function()
      local map = makeFlagMap({
        ["1:1"] = {passable = true},
        ["2:2"] = {passable = false},
      })
      local world = makeWorld({})
      world.map = {th = map}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 10 and 1 <= y and y <= 10
      end
      world.pathfinder = {
        findDistance = function(_, x1, y1, x2, y2)
          return x1 == 2 and y1 == 2 and x2 == 1 and y2 == 1 and 1 or nil
        end,
      }
      local ingress = {{x = 1, y = 1}}

      assert.is_false(world:isTileConnectedToBlockingOffAreaIngress(2, 2, ingress))
      assert.is_true(world:isHumanoidConnectedToBlockingOffAreaIngress(2, 2, ingress))
    end)

    it("runs the zero-spawn fallback with old topology removed and rolls back", function()
      local map, flags = makeFlagMap({
        ["1:1"] = {passable = false},
        ["3:1"] = {passable = true},
      })
      local world = makeWorld({})
      world.map = {th = map}
      world.spawn_points = {}
      world.rooms = {}
      world.objects = {}
      world.isOnMap = function(_, x, y)
        return (x == 1 or x == 3) and y == 1
      end
      world.getLocalPlayerHospital = function() return nil end

      local object_type = {
        id = "plant",
        class = "Object",
        orientations = {north = {footprint = {{0, 0}}}},
      }
      local existing_object = {
        picked_up = true,
        tile_x = 1,
        tile_y = 1,
        direction = "north",
        object_type = object_type,
        th = {isVisible = function() return false end},
      }

      local unsafe = world:wouldCorridorObjectBlockProtectedArea(
        3, 1, object_type, "north", {
          existing_object = existing_object,
          check_existing = true,
          strict_check = function()
            assert.is_true(flags["1:1"].passable)
            assert.is_false(flags["3:1"].passable)
            return false
          end,
        })

      assert.is_nil(unsafe)
      assert.is_false(flags["1:1"].passable)
      assert.is_true(flags["3:1"].passable)
    end)

    it("uses the zero-anchor strict fallback for a Reception Desk", function()
      local map, flags = makeFlagMap({
        ["3:1"] = {passable = true},
        ["4:1"] = {passable = true},
        ["5:1"] = {passable = true},
      })
      local world = makeWorld({})
      world.map = {th = map}
      world.spawn_points = {}
      world.rooms = {}
      world.objects = {}
      world.isOnMap = function(_, x, y)
        return 3 <= x and x <= 5 and y == 1
      end
      world.getLocalPlayerHospital = function() return nil end

      local object_type = {
        id = "reception_desk",
        class = "Object",
        orientations = {
          north = {
            footprint = {{0, 0}},
            use_position = {1, 0},
            use_position_secondary = {2, 0},
          },
        },
      }

      local strict_calls = 0
      local unsafe = world:wouldCorridorObjectBlockProtectedArea(
        3, 1, object_type, "north", {
          check_existing = false,
          strict_check = function()
            strict_calls = strict_calls + 1
            assert.is_false(flags["3:1"].passable)
            return false
          end,
        })

      assert.are.equal(1, strict_calls)
      assert.is_nil(unsafe)
      assert.is_true(flags["3:1"].passable)

      unsafe = world:wouldCorridorObjectBlockProtectedArea(
        3, 1, object_type, "north", {
          check_existing = false,
          strict_check = function()
            return true
          end,
        })
      assert.is_true(unsafe)
      assert.is_true(flags["3:1"].passable)
    end)

    it("runs the zero-spawn SideObject fallback with old edge removed", function()
      local map, flags = makeFlagMap({
        ["1:1"] = {travelEast = false},
        ["2:1"] = {travelWest = false},
        ["3:1"] = {travelEast = true},
        ["4:1"] = {travelWest = true},
      })
      local world = makeWorld({})
      world.map = {th = map}
      world.spawn_points = {}
      world.rooms = {}
      world.objects = {}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 4 and y == 1
      end
      world.getLocalPlayerHospital = function() return nil end

      local object_type = {
        id = "radiator",
        class = "SideObject",
        orientations = {east = {footprint = {{0, 0, only_side = true}}}},
      }
      local existing_object = {
        picked_up = true,
        set_passable_flags = true,
        tile_x = 1,
        tile_y = 1,
        direction = "east",
        object_type = object_type,
        th = {isVisible = function() return false end},
      }

      local unsafe = world:wouldCorridorObjectBlockProtectedArea(
        3, 1, object_type, "east", {
          existing_object = existing_object,
          check_existing = true,
          strict_check = function()
            assert.is_true(flags["1:1"].travelEast)
            assert.is_true(flags["2:1"].travelWest)
            assert.is_false(flags["3:1"].travelEast)
            assert.is_false(flags["4:1"].travelWest)
            return false
          end,
        })

      assert.is_nil(unsafe)
      assert.is_false(flags["1:1"].travelEast)
      assert.is_false(flags["2:1"].travelWest)
      assert.is_true(flags["3:1"].travelEast)
      assert.is_true(flags["4:1"].travelWest)
    end)

    it("keeps a SideObject edge blocked when another object covers it", function()
      local map, flags = makeFlagMap({
        ["1:1"] = {travelEast = false},
        ["2:1"] = {travelWest = false},
        ["3:1"] = {travelEast = true},
        ["4:1"] = {travelWest = true},
      })
      local world = makeWorld({})
      world.map = {th = map}
      world.spawn_points = {}
      world.rooms = {}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 4 and y == 1
      end
      world.getLocalPlayerHospital = function() return nil end

      local object_type = {
        id = "radiator",
        class = "SideObject",
        orientations = {
          east = {footprint = {{0, 0, only_side = true}}},
          west = {footprint = {{0, 0, only_side = true}}},
        },
      }
      local existing_object = {
        picked_up = true,
        set_passable_flags = true,
        tile_x = 1,
        tile_y = 1,
        direction = "east",
        object_type = object_type,
        th = {isVisible = function() return false end},
      }
      local overlapping_object = {
        tile_x = 2,
        tile_y = 1,
        direction = "west",
        object_type = object_type,
      }
      world.objects = {
        [1] = {existing_object},
        [2] = {overlapping_object},
      }

      world:wouldCorridorObjectBlockProtectedArea(3, 1, object_type, "east", {
        existing_object = existing_object,
        strict_check = function()
          assert.is_false(flags["1:1"].travelEast)
          assert.is_false(flags["2:1"].travelWest)
          assert.is_false(flags["3:1"].travelEast)
          assert.is_false(flags["4:1"].travelWest)
          return false
        end,
      })

      assert.is_false(flags["1:1"].travelEast)
      assert.is_false(flags["2:1"].travelWest)
      assert.is_true(flags["3:1"].travelEast)
      assert.is_true(flags["4:1"].travelWest)
    end)

    it("protects Reception Desk candidate usage positions", function()
      local map, flags = makeFlagMap({
        ["1:1"] = {passable = true},
        ["3:1"] = {passable = true},
        ["4:1"] = {passable = true},
        ["5:1"] = {passable = true},
      })
      local world = makeWorld({})
      world.map = {th = map}
      world.spawn_points = {{x = 1, y = 1}}
      world.rooms = {}
      world.objects = {}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 5 and y == 1
      end
      world.getLocalPlayerHospital = function() return nil end

      local secondary_connected = false
      world.pathfinder = {
        findDistance = function(_, x1, y1, x2, y2)
          if x2 ~= 1 or y2 ~= 1 then return nil end
          if x1 == 1 and y1 == 1 then return 0 end
          if x1 == 4 and y1 == 1 then return 3 end
          if x1 == 5 and y1 == 1 and secondary_connected then return 4 end
          return nil
        end,
      }

      local object_type = {
        id = "reception_desk",
        class = "Object",
        orientations = {
          north = {
            footprint = {{0, 0}},
            use_position = {1, 0},
            use_position_secondary = {2, 0},
          },
        },
      }

      local unsafe = world:wouldCorridorObjectBlockProtectedArea(
        3, 1, object_type, "north", {check_existing = false})
      assert.is_true(unsafe)
      assert.is_true(flags["3:1"].passable)

      secondary_connected = true
      unsafe = world:wouldCorridorObjectBlockProtectedArea(
        3, 1, object_type, "north", {check_existing = false})
      assert.is_false(unsafe)
      assert.is_true(flags["3:1"].passable)
    end)

    it("does not scan protected endpoints when placement has no topology impact", function()
      local world = makeWorld({})
      world.spawn_points = {{x = 1, y = 1}}
      world.getLocalPlayerHospital = function() return nil end
      world._getCorridorCandidateBoundaryTiles = function()
        return {{x = 2, y = 1}}
      end
      world._captureBlockingOffAreaImpactBaseline = function()
        return {tiles = {}, reaches_ingress = {}, ingress_components = {}}
      end
      world._getBlockingOffAreaImpact = function()
        return false, {}
      end
      world._withProspectiveCorridorObjectTopology = function(_, _, _, _, _, _, callback, before)
        local baseline = before and before()
        return callback(baseline)
      end
      world._captureBlockingOffAreaProtectedBaseline = function()
        error("protected endpoints must not be scanned")
      end

      local object_type = {
        id = "plant",
        class = "Object",
        orientations = {north = {footprint = {{0, 0}}}},
      }
      local unsafe = world:wouldCorridorObjectBlockProtectedArea(
        3, 1, object_type, "north", {check_existing = true})

      assert.is_false(unsafe)
    end)

    it("defers protected endpoint scan until a new blocked area exists", function()
      local world = makeWorld({})
      world.spawn_points = {{x = 1, y = 1}}
      world.getLocalPlayerHospital = function() return nil end
      world._getCorridorCandidateBoundaryTiles = function()
        return {{x = 2, y = 1}}
      end
      world._captureBlockingOffAreaImpactBaseline = function()
        return {tiles = {}, reaches_ingress = {}, ingress_components = {}}
      end
      world._getBlockingOffAreaImpact = function()
        return false, {{x = 2, y = 1}}
      end
      world._collectBlockingOffAreaTiles = function(_, areas)
        assert.are.equal(1, #areas)
        return {["2:1"] = true}
      end
      world._withProspectiveCorridorObjectTopology = function(_, _, _, _, _, _, callback, before)
        local baseline = before and before()
        return callback(baseline)
      end
      local protected_calls = 0
      world._captureBlockingOffAreaProtectedBaseline = function(_, _, options)
        protected_calls = protected_calls + 1
        assert.is_true(options.affected_tiles["2:1"])
        return {{x = 2, y = 1, was_valid = true, description = "room door"}}
      end
      world._blockingOffAreaProtectedEndpointsUnsafe = function(_, endpoints)
        assert.are.equal(1, #endpoints)
        return true
      end

      local object_type = {
        id = "plant",
        class = "Object",
        orientations = {north = {footprint = {{0, 0}}}},
      }
      local unsafe = world:wouldCorridorObjectBlockProtectedArea(
        3, 1, object_type, "north", {check_existing = true})

      assert.is_true(unsafe)
      assert.are.equal(1, protected_calls)
    end)

    it("checks multiple candidate tiles against the ingress network once", function()
      local initial = {}
      local ingress = {}
      for x = 1, 16 do
        initial[x .. ":1"] = {passable = true}
        ingress[#ingress + 1] = {x = x, y = 1}
      end
      initial[17 .. ":1"] = {passable = true}
      initial[18 .. ":1"] = {passable = true}
      local map = makeFlagMap(initial)
      local world = makeWorld({})
      world.map = {th = map}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 18 and y == 1
      end
      local calls = 0
      world.pathfinder = {
        findDistance = function()
          calls = calls + 1
          return 1
        end,
      }

      assert.is_true(world:_areBlockingOffAreaTilesConnectedToIngress(
        {{x = 17, y = 1}, {x = 18, y = 1}}, ingress))
      assert.are.equal(17, calls)
    end)

    it("groups a connected ingress network without all-pairs pathfinding", function()
      local initial = {}
      local ingress = {}
      for x = 1, 16 do
        initial[x .. ":1"] = {passable = true}
        ingress[#ingress + 1] = {x = x, y = 1}
      end
      local map = makeFlagMap(initial)
      local world = makeWorld({})
      world.map = {th = map}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 16 and y == 1
      end
      local calls = 0
      world.pathfinder = {
        findDistance = function()
          calls = calls + 1
          return 1
        end,
      }

      local baseline = world:_captureBlockingOffAreaImpactBaseline(ingress, {})
      assert.are.equal(15, calls)
      assert.are.equal(1, #baseline.ingress_components)
      assert.are.equal(16, #baseline.ingress_components[1])

      calls = 0
      local ingress_broken, blocked = world:_getBlockingOffAreaImpact(
        ingress, baseline)
      assert.is_false(ingress_broken)
      assert.are.equal(0, #blocked)
      assert.are.equal(15, calls)
    end)

    it("checks an affected endpoint once per baseline ingress component", function()
      local initial = {
        ["20:1"] = {passable = true},
      }
      local ingress = {}
      local component = {}
      for x = 1, 16 do
        initial[x .. ":1"] = {passable = true}
        ingress[#ingress + 1] = {x = x, y = 1}
        component[#component + 1] = x
      end
      local map = makeFlagMap(initial)
      local room = {
        door = {tile_x = 20, tile_y = 1},
        getEntranceXY = function() return 20, 1 end,
      }
      local world = makeWorld({})
      world.map = {th = map}
      world.rooms = {room}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 20 and y == 1
      end
      local calls = 0
      world.pathfinder = {
        findDistance = function()
          calls = calls + 1
          return 1
        end,
      }

      local endpoints = world:_captureBlockingOffAreaProtectedBaseline(
        ingress, {
          affected_tiles = {["20:1"] = true},
          ingress_baseline = {
            ingress_components = {component},
            all_ingress_usable = true,
          },
        })

      assert.are.equal(1, #endpoints)
      assert.is_true(endpoints[1].was_valid)
      assert.are.equal(1, calls)
    end)

    it("marks affected endpoints invalid without pathfinding when an ingress is unusable", function()
      local map = makeFlagMap({
        ["1:1"] = {passable = true},
        ["2:1"] = {passable = true},
      })
      local room = {
        door = {tile_x = 2, tile_y = 1},
        getEntranceXY = function() return 2, 1 end,
      }
      local world = makeWorld({})
      world.map = {th = map}
      world.rooms = {room}
      world.isOnMap = function() return true end
      local calls = 0
      world.pathfinder = {
        findDistance = function()
          calls = calls + 1
          return 1
        end,
      }

      local endpoints = world:_captureBlockingOffAreaProtectedBaseline(
        {{x = 1, y = 1}}, {
          affected_tiles = {["2:1"] = true},
          ingress_baseline = {
            ingress_components = {{1}},
            all_ingress_usable = false,
          },
        })

      assert.are.equal(1, #endpoints)
      assert.is_false(endpoints[1].was_valid)
      assert.are.equal(0, calls)
    end)

    it("flood-fills only tiles in the newly blocked component", function()
      local map = makeFlagMap({
        ["1:1"] = {
          passable = true,
          travelEast = true,
          travelWest = false,
          travelNorth = false,
          travelSouth = false,
        },
        ["2:1"] = {
          passable = true,
          travelEast = true,
          travelWest = true,
          travelNorth = false,
          travelSouth = false,
        },
        ["3:1"] = {
          passable = true,
          travelEast = false,
          travelWest = true,
          travelNorth = false,
          travelSouth = false,
        },
        ["4:1"] = {
          passable = true,
          travelEast = false,
          travelWest = false,
          travelNorth = false,
          travelSouth = false,
        },
      })
      local world = makeWorld({})
      world.map = {th = map}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 4 and y == 1
      end

      local blocked = world:_collectBlockingOffAreaTiles({{x = 1, y = 1}})
      assert.is_true(blocked["1:1"])
      assert.is_true(blocked["2:1"])
      assert.is_true(blocked["3:1"])
      assert.is_nil(blocked["4:1"])
    end)

    it("pathfinds only protected endpoints inside the affected tile set", function()
      local map = makeFlagMap({
        ["1:1"] = {passable = true},
        ["2:1"] = {passable = true},
        ["9:1"] = {passable = true},
      })
      local room_inside = {
        door = {tile_x = 2, tile_y = 1},
        getEntranceXY = function() return 2, 1 end,
      }
      local room_outside = {
        door = {tile_x = 9, tile_y = 1},
        getEntranceXY = function() return 9, 1 end,
      }
      local world = makeWorld({})
      world.map = {th = map}
      world.rooms = {room_inside, room_outside}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 9 and y == 1
      end
      local calls = 0
      world.pathfinder = {
        findDistance = function(_, x1, y1, x2, y2)
          calls = calls + 1
          if x1 == 2 and y1 == 1 and x2 == 1 and y2 == 1 then return 1 end
          return nil
        end,
      }

      local endpoints = world:_captureBlockingOffAreaProtectedBaseline(
        {{x = 1, y = 1}}, {
          affected_tiles = {["2:1"] = true},
          check_humanoids = true,
        })

      assert.are.equal(1, #endpoints)
      assert.are.equal(2, endpoints[1].x)
      assert.is_true(endpoints[1].was_valid)
      assert.are.equal(1, calls)
    end)

    it("does not double-pathfind an affected humanoid", function()
      local map = makeFlagMap({
        ["1:1"] = {passable = true},
        ["2:1"] = {passable = false},
      })
      local humanoid = {
        tile_x = 2,
        tile_y = 1,
        humanoid_class = "Nurse",
        action_queue = {{name = "idle"}},
      }
      setmetatable(humanoid, {__index = Humanoid})
      function humanoid:getCurrentAction()
        return self.action_queue[1]
      end

      local world = makeWorld({humanoid})
      world.map = {th = map}
      world.rooms = {}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 2 and y == 1
      end
      local calls = 0
      world.pathfinder = {
        findDistance = function(_, x1, y1, x2, y2)
          calls = calls + 1
          if x1 == 2 and y1 == 1 and x2 == 1 and y2 == 1 then return 1 end
          return nil
        end,
      }

      local endpoints = world:_captureBlockingOffAreaProtectedBaseline(
        {{x = 1, y = 1}}, {
          affected_tiles = {["2:1"] = true},
          check_humanoids = true,
        })

      assert.are.equal(1, #endpoints)
      assert.is_true(endpoints[1].was_valid)
      assert.are.equal(1, calls)
    end)

    it("ignores a pre-existing blocked boundary component", function()
      local map = makeFlagMap({
        ["1:1"] = {passable = true},
        ["2:1"] = {passable = true},
      })
      local world = makeWorld({})
      world.map = {th = map}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 2 and y == 1
      end
      world.pathfinder = {
        findDistance = function(_, x1, y1, x2, y2)
          if x1 == x2 and y1 == y2 then return 0 end
          return nil
        end,
      }
      local ingress = {{x = 1, y = 1}}
      local baseline = world:_captureBlockingOffAreaImpactBaseline(
        ingress, {{x = 2, y = 1}})
      local ingress_broken, blocked = world:_getBlockingOffAreaImpact(
        ingress, baseline)

      assert.is_false(ingress_broken)
      assert.are.equal(0, #blocked)
    end)

    it("detects a newly-created blocked boundary component", function()
      local map = makeFlagMap({
        ["1:1"] = {passable = true},
        ["2:1"] = {passable = true},
      })
      local world = makeWorld({})
      world.map = {th = map}
      world.isOnMap = function(_, x, y)
        return 1 <= x and x <= 2 and y == 1
      end
      local connected = true
      world.pathfinder = {
        findDistance = function(_, x1, y1, x2, y2)
          if x1 == x2 and y1 == y2 then return 0 end
          if connected then return 1 end
          return nil
        end,
      }
      local ingress = {{x = 1, y = 1}}
      local baseline = world:_captureBlockingOffAreaImpactBaseline(
        ingress, {{x = 2, y = 1}})
      connected = false
      local ingress_broken, blocked = world:_getBlockingOffAreaImpact(
        ingress, baseline)

      assert.is_false(ingress_broken)
      assert.are.equal(1, #blocked)
      assert.are.equal(2, blocked[1].x)
      assert.are.equal(1, blocked[1].y)
    end)

    it("uses the pre-use walking tile for a humanoid using an object", function()
      local humanoid = {
        tile_x = 79,
        tile_y = 101,
        humanoid_class = "Nurse",
        action_queue = {{
          name = "use_object",
          old_tile_x = 80,
          old_tile_y = 100,
        }},
      }
      setmetatable(humanoid, {__index = Humanoid})
      function humanoid:getCurrentAction()
        return self.action_queue[1]
      end

      local world = makeWorld({humanoid})
      world.rooms = {}
      local endpoints = world:_collectBlockingOffAreaProtectedEndpoints({
        check_humanoids = true,
      })

      assert.are.equal(1, #endpoints)
      assert.are.equal(80, endpoints[1].x)
      assert.are.equal(100, endpoints[1].y)
      assert.is_true(endpoints[1].humanoid)
      assert.are.equal("use_object", endpoints[1].action)
    end)

    it("logs and ignores a pre-existing invalid endpoint inside an affected area", function()
      local world = makeWorld({})
      world.pathfinder = {
        findDistance = function() return 1 end,
      }
      local logs = {}
      world.gameLog = function(_, message)
        logs[#logs + 1] = message
      end

      local unsafe = world:_blockingOffAreaProtectedEndpointsUnsafe({{
        x = 2,
        y = 1,
        description = "Nurse",
        action = "use_object",
        was_valid = false,
      }})

      assert.is_false(unsafe)
      assert.are.equal(1, #logs)
      assert.is_truthy(logs[1]:find("Nurse", 1, true))
      assert.is_truthy(logs[1]:find("use_object", 1, true))
    end)

    it("rolls back zero-spawn move topology when the fallback errors", function()
      local map, flags = makeFlagMap({
        ["1:1"] = {passable = false},
        ["3:1"] = {passable = true},
      })
      local world = makeWorld({})
      world.map = {th = map}
      world.spawn_points = {}
      world.rooms = {}
      world.objects = {}
      world.isOnMap = function(_, x, y)
        return (x == 1 or x == 3) and y == 1
      end
      world.getLocalPlayerHospital = function() return nil end

      local object_type = {
        id = "plant",
        class = "Object",
        orientations = {north = {footprint = {{0, 0}}}},
      }
      local existing_object = {
        picked_up = true,
        tile_x = 1,
        tile_y = 1,
        direction = "north",
        object_type = object_type,
        th = {isVisible = function() return false end},
      }

      assert.has_error(function()
        world:wouldCorridorObjectBlockProtectedArea(
          3, 1, object_type, "north", {
            existing_object = existing_object,
            check_existing = true,
            strict_check = function()
              error("fallback failed")
            end,
          })
      end)

      assert.is_false(flags["1:1"].passable)
      assert.is_true(flags["3:1"].passable)
    end)
  end)

end)
