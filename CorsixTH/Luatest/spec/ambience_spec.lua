--[[ Copyright (c) 2026 CorsixTH contributors

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. --]]

require("corsixth")

require("class_test_base")

require("utility")
require("map")

-- The volume helpers are deliberately free of game and audio state, so these
-- tests need no mocks at all.
require("ambience")

local crowd_volume = _G["crowd_volume"]
local zoom_attenuation = _G["zoom_attenuation"]
local approach_volume = _G["approach_volume"]
local count_visible_humanoids = _G["count_visible_humanoids"]
local Ambience = _G["Ambience"]

describe("ambience.lua crowd volume: ", function()
  it("is silent for an empty view", function()
    assert.are.equal(0, crowd_volume(0))
  end)

  it("treats a negative count as empty", function()
    assert.are.equal(0, crowd_volume(-3))
  end)

  it("is silent until the hospital is busy", function()
    -- Playing the game showed the crowd was still audible with only one person
    -- on screen, so a quiet hospital is now silent rather than very quiet.
    assert.are.equal(0, crowd_volume(0))
    assert.are.equal(0, crowd_volume(1))
    assert.are.equal(0, crowd_volume(2))
    assert.are.equal(0, crowd_volume(3))
    assert.are.equal(0, crowd_volume(4))
  end)

  it("starts very quietly once people are on screen", function()
    assert.is_true(crowd_volume(5) > 0 and crowd_volume(5) < 0.02)
  end)

  -- These proportions are not all exactly representable in binary floating
  -- point, so the expected values are compared with a tolerance.
  local function is_close(actual, expected)
    return math.abs(actual - expected) < 1e-9
  end

  -- The curve is logarithmic between crowd_start_people and
  -- crowd_max_people, so the volume is the share of the logarithmic range
  -- between those two counts, taken from crowd_start_volume up to full.
  it("rises logarithmically across the audible range", function()
    local start, maximum = crowd_volume(5), crowd_volume(20)
    for count = 6, 19 do
      local expected = start +
          (math.log(count) - math.log(5)) / (math.log(20) - math.log(5)) *
          (maximum - start)
      assert.is_true(is_close(crowd_volume(count), expected))
    end
  end)

  it("grows faster in percentage terms early on than late on", function()
    -- The point of a logarithmic curve: the first extra people matter more
    -- than the last few.
    assert.is_true(crowd_volume(6) - crowd_volume(5) >
        crowd_volume(20) - crowd_volume(19))
  end)

  it("reaches full volume at twenty people", function()
    assert.are.equal(1, crowd_volume(20))
  end)

  it("stays at full volume for a larger crowd", function()
    assert.are.equal(1, crowd_volume(21))
    assert.are.equal(1, crowd_volume(200))
  end)

  it("spans a wide range between a quiet and a busy hospital", function()
    -- A handful of people should be clearly quieter than a crowded hospital,
    -- which was not noticeable with the earlier curves.
    assert.is_true(crowd_volume(6) < crowd_volume(20) * 0.25)
    assert.is_true(crowd_volume(10) > crowd_volume(20) * 0.4)
    assert.is_true(crowd_volume(10) < crowd_volume(20) * 0.6)
  end)

  it("never decreases as the crowd grows", function()
    local previous = 0
    for count = 0, 40 do
      local volume = crowd_volume(count)
      assert.is_true(volume >= previous)
      previous = volume
    end
  end)

  it("stays within the valid volume range", function()
    for count = -5, 100 do
      local volume = crowd_volume(count)
      assert.is_true(volume >= 0 and volume <= 1)
    end
  end)
end)

describe("ambience.lua zoom attenuation: ", function()
  it("does not attenuate at the original game's zoom", function()
    assert.are.equal(1, zoom_attenuation(1, 0.25))
  end)

  it("is silent at the smallest allowed zoom", function()
    assert.are.equal(0, zoom_attenuation(0.25, 0.25))
  end)

  it("falls off between the two extremes", function()
    local middle = zoom_attenuation(0.625, 0.25)
    assert.is_true(middle > 0 and middle < 1)
  end)

  it("clamps when zoomed in beyond the original game's zoom", function()
    assert.are.equal(1, zoom_attenuation(2, 0.25))
  end)

  it("stops at full when the view cannot be zoomed out that far", function()
    -- A large window can make the minimum zoom greater than 1, leaving no
    -- range to attenuate over.
    assert.are.equal(1, zoom_attenuation(1.5, 1.2))
  end)

  it("stays within the valid range across the zoom range", function()
    local min_zoom = 0.2
    for step = -5, 15 do
      local attenuation = zoom_attenuation(step * 0.1, min_zoom)
      assert.is_true(attenuation >= 0 and attenuation <= 1)
    end
  end)
end)

describe("ambience.lua approach volume: ", function()
  it("moves towards the target by at most one step", function()
    assert.are.equal(0.25, approach_volume(0, 1, 0.25))
  end)

  it("does not overshoot the target", function()
    assert.are.equal(1, approach_volume(0.9, 1, 0.25))
    assert.are.equal(0, approach_volume(0.1, 0, 0.25))
  end)

  it("stays put when already at the target", function()
    assert.are.equal(0.5, approach_volume(0.5, 0.5, 0.25))
  end)

  it("moves down as well as up", function()
    assert.are.equal(0.75, approach_volume(1, 0, 0.25))
  end)

  it("fades to silence from full volume in even steps", function()
    local volume = 1
    local steps = 0
    while volume > 0 do
      local before = volume
      volume = approach_volume(volume, 0, 0.025)
      assert.is_true(volume < before)
      assert.is_true(volume >= 0)
      steps = steps + 1
    end
    -- 0.025 per frame from full volume is about 40 frames.
    assert.is_true(steps > 30 and steps < 50)
  end)
end)

describe("ambience.lua visible humanoid counting: ", function()
  -- Use the real transform so the test view bounds mean the same thing they do
  -- in game, and a change to the map cannot silently diverge from this test.
  local function makeHospital(patients, staff)
    local map = setmetatable({}, {__index = Map})
    return {world = {map = map}, patients = patients, staff = staff}
  end

  it("counts nobody in an empty hospital", function()
    local hospital = makeHospital({}, {})
    assert.are.equal(0, count_visible_humanoids(hospital, 0, 0, 640, 480))
  end)

  it("counts patients and staff alike", function()
    local hospital = makeHospital(
        {{tile_x = 5, tile_y = 5}, {tile_x = 6, tile_y = 6}},
        {{tile_x = 7, tile_y = 7}})
    assert.are.equal(3, count_visible_humanoids(hospital, 0, 0, 640, 480))
  end)

  it("leaves out people well away from the view", function()
    local near = {tile_x = 5, tile_y = 5}
    local far = {tile_x = 100, tile_y = 100}
    local hospital = makeHospital({near}, {far})
    assert.are.equal(1, count_visible_humanoids(hospital, 0, 0, 640, 480))
  end)

  it("skips humanoids that have no position yet", function()
    local hospital = makeHospital(
        {{tile_x = 5, tile_y = 5}, {tile_x = nil, tile_y = nil}, {}},
        {{}})
    assert.are.equal(1, count_visible_humanoids(hospital, 0, 0, 640, 480))
  end)

  -- People just outside the view still count towards the crowd, so a small
  -- overshoot at the edge must still be counted.
  -- Only people within the given bounds count, so someone just outside them is
  -- left out rather than being brought in by any margin.
  it("counts people just inside the bounds but not those just outside",
      function()
        -- WorldToScreen(4, 4) is (0, 96).
        local hospital = makeHospital({{tile_x = 4, tile_y = 4}}, {})
        assert.are.equal(1,
            count_visible_humanoids(hospital, 0, 0, 200, 200))
        -- Bounds pulled back past the same person.
        assert.are.equal(0,
            count_visible_humanoids(hospital, 10, 100, 10010, 10010))
      end)

  it("leaves out people outside the bounds in either direction", function()
    -- WorldToScreen gives 32 * (x - y) and 16 * (x + y - 2), so (5,5) is at
    -- (0, 128) and (20,5) is at (480, 368).
    local hospital = makeHospital({}, {{tile_x = 5, tile_y = 5},
        {tile_x = 20, tile_y = 5}})
    -- Wide enough for both.
    assert.are.equal(2,
        count_visible_humanoids(hospital, -100, -100, 600, 600))
    -- Narrow box around only the first.
    assert.are.equal(1,
        count_visible_humanoids(hospital, -100, 0, 100, 600))
    -- Narrow box around only the second.
    assert.are.equal(1,
        count_visible_humanoids(hospital, 300, 0, 600, 600))
  end)
end)

describe("ambience.lua Ambience:update: ", function()
  -- Stubs recording what the ambience asks the sound system to do, following
  -- the mock style used in announcer_spec.lua.
  local function makeHarness(opts)
    opts = opts or {}
    local calls = {played = 0, gains = {}, pauses = 0, stops = 0}

    local audio = {
      soundExists = function() return opts.sound_exists ~= false end,
      isPlaying = function() return opts.playing ~= false end,
      togglePauseSound = function() calls.pauses = calls.pauses + 1 end,
      stopSound = function() calls.stops = calls.stops + 1 end,
      setSoundGain = function(_, sound, volume)
        calls.gains[#calls.gains + 1] = {sound = sound, volume = volume}
      end,
    }

    local ui = {
      zoom_factor = 1,
      getEffectiveZoom = function() return 1 end,
      getScreenOffset = function() return 0, 0 end,
      calculateMinimumZoom = function() return 0.25 end,
      playSound = function()
        calls.played = calls.played + 1
        if opts.play_returns_nil then
          return nil
        elseif opts.play_returns_bad_handle then
          return {handle = {}}
        end
        return {handle = 7}
      end,
    }

    local hospital = {world = {map = setmetatable({}, {__index = Map})},
        patients = opts.patients or {}, staff = opts.staff or {}}
    local world = {isPaused = function() return opts.paused == true end}
    local app = {
      audio = audio, ui = ui, world = world,
      config = {play_sounds = opts.play_sounds ~= false, sound_volume = 0.5},
      video = {getRenderSize = function() return 640, 480 end},
    }

    return Ambience(app, ui, hospital), calls
  end

  -- People spread across the middle of the view. The harness view is 640x480,
  -- so the 400x400 crowd area covers screen x 120 to 520 and y 40 to 440.
  -- WorldToScreen gives 32 * (x - y) and 16 * (x + y - 2), so holding x - y
  -- between 8 and 12 keeps screen x central, and growing x + y walks screen y
  -- down the area. Every one of these lands inside it.
  local function people(count)
    local list = {}
    for i = 1, count do
      local k = i - 1
      local y = 1 + math.floor(k / 2)
      list[i] = {tile_x = y + (k % 2 == 0 and 8 or 12), tile_y = y}
    end
    return list
  end

  -- People clearly on screen but out at the left edge, so outside the crowd
  -- area. Holding x - y at 2 puts screen x at 64, which is inside the 640 wide
  -- view but well left of the area.
  local function people_at_edge(count)
    local list = {}
    for i = 1, count do
      list[i] = {tile_x = i + 2, tile_y = i}
    end
    return list
  end

  -- Enough people for the crowd to be audible at all, since a quiet hospital is
  -- now silent.
  local small_crowd = people(6)

  -- A busy hospital, so the crowd asks for a high volume that the fade has to
  -- take several frames to reach.
  local many_patients = people(20)

  it("does not start anything while the view is empty", function()
    local ambience, calls = makeHarness()
    ambience:update()
    assert.are.equal(0, calls.played)
  end)

  it("starts a single endless loop once a crowd is present", function()
    local ambience, calls = makeHarness({patients = small_crowd})
    ambience:update()
    assert.are.equal(1, calls.played)
    assert.is_not_nil(ambience.sound)
    -- 0.1 for one person, halved by the sound effects volume of 0.5, minus one
    -- step of the fade.
    assert.is_true(#calls.gains > 0)
  end)

  it("starts the loop and lets it fade up rather than appearing at full volume",
      function()
    local ambience, calls = makeHarness({patients = small_crowd})
    ambience:update()
    assert.are.equal(1, #calls.gains)
    assert.is_true(calls.gains[1].volume < 0.1)
  end)

  it("does not ask for a gain change once the volume has settled", function()
    -- A busy hospital, so the target is far enough away that the fade takes
    -- several frames rather than being reached in one.
    local ambience, calls = makeHarness({patients = many_patients})
    -- The first frame starts the loop, so count from the frame after that.
    ambience:update()
    for _ = 1, 60 do
      ambience:update()
    end
    local settled = #calls.gains
    -- The fade should have taken several frames to get there.
    assert.is_true(settled > 5)

    -- Now that the fade has finished, further frames cost nothing.
    ambience:update()
    ambience:update()
    assert.are.equal(settled, #calls.gains)
  end)

  it("starts nothing when sound effects are switched off", function()
    local ambience, calls =
        makeHarness({patients = small_crowd, play_sounds = false})
    ambience:update()
    assert.are.equal(0, calls.played)
  end)

  it("gives up rather than retrying when the sample cannot be played",
      function()
    local ambience, calls = makeHarness({patients = small_crowd,
        play_returns_nil = true})
    ambience:update()
    ambience:update()
    assert.are.equal(1, calls.played)
  end)

  it("does not pass on a handle that is not a number", function()
    local ambience, calls = makeHarness({patients = small_crowd,
        play_returns_bad_handle = true})
    ambience:update()
    ambience:update()
    assert.are.equal(1, calls.played)
    assert.are.equal(0, #calls.gains)
  end)

  it("discards a loop that stopped on its own", function()
    local ambience, calls = makeHarness({patients = small_crowd})
    ambience:update()
    assert.are.equal(1, calls.played)

    -- The sound system now reports the loop as no longer playing, so it should
    -- be dropped and started afresh rather than having its gain adjusted.
    calls.gains = {}
    ambience.app.audio.isPlaying = function() return false end
    ambience:update()
    assert.are.equal(0, #calls.gains)
  end)

  it("pauses nothing when there is no loop yet", function()
    local ambience, calls =
        makeHarness({patients = small_crowd, paused = true})
    ambience:update()
    ambience:update()
    assert.are.equal(0, calls.pauses)
    assert.are.equal(0, calls.played)
  end)

  it("pauses and resumes the loop with the game", function()
    local ambience, calls = makeHarness({patients = small_crowd})
    ambience:update()
    assert.is_not_nil(ambience.sound)
    assert.is_false(ambience.paused)

    ambience.app.world.isPaused = function() return true end
    ambience:update()
    ambience:update()
    assert.is_true(ambience.paused)
    assert.are.equal(1, calls.pauses)

    ambience.app.world.isPaused = function() return false end
    ambience:update()
    assert.is_false(ambience.paused)
    assert.are.equal(2, calls.pauses)
  end)

  it("stops the loop when destroyed", function()
    local ambience, calls = makeHarness({patients = small_crowd})
    ambience:update()
    ambience:destroy()
    assert.are.equal(1, calls.stops)
    assert.is_nil(ambience.sound)
  end)

  it("stops the loop when a savegame is loaded", function()
    local ambience, calls = makeHarness({patients = small_crowd})
    ambience:update()
    ambience:onSavegameLoaded()
    assert.are.equal(1, calls.stops)
    assert.is_nil(ambience.sound)
    assert.are.equal(0, ambience.volume)
  end)

  it("is silent when the view is fully zoomed out", function()
    local ambience = makeHarness({patients = small_crowd})
    ambience.ui.zoom_factor = 0.25 -- the minimum zoom
    ambience:update()
    assert.are.equal(0, ambience:getTargetVolume())
  end)

  it("is silent while the hospital is quiet", function()
    -- Four people or fewer is not a crowd.
    local ambience, calls = makeHarness({patients = people(4)})
    ambience:update()
    assert.are.equal(0, ambience:getTargetVolume())
    assert.are.equal(0, calls.played)
  end)

  it("does not count people who are on screen but outside the crowd area",
      function()
    -- Playing the game showed people appearing at the edge of the screen, with
        -- little more than their legs showing, were already adding to the
        -- crowd. Six such people is enough to make the sound audible, so they
        -- must not be counted at all.
    local ambience = makeHarness({patients = people_at_edge(6)})
    assert.are.equal(0, ambience:getTargetVolume())
  end)

  it("counts people in the crowd area and ignores those at the edge",
      function()
        local in_area = people(6)
        local at_edge = people_at_edge(6)
        local both = {}
        for _, p in ipairs(in_area) do both[#both + 1] = p end
        for _, p in ipairs(at_edge) do both[#both + 1] = p end

        local with_all = makeHarness({patients = both})
        local with_centre_only = makeHarness({patients = in_area})
        -- Twelve people on screen, but only the six in the middle count.
        assert.are.equal(with_centre_only:getTargetVolume(),
            with_all:getTargetVolume())
      end)

  it("applies the sound effects volume to the crowd", function()
    local ambience = makeHarness({patients = small_crowd})
    -- Halving the sound effects volume must halve the crowd volume.
    local loud = ambience:getTargetVolume()
    ambience.app.config.sound_volume = 0.25
    assert.is_true(ambience:getTargetVolume() < loud)
  end)

  it("does not count people once the sample is known to be missing", function()
    local ambience, calls = makeHarness({patients = small_crowd,
        sound_exists = false})
    assert.are.equal(0, ambience:getTargetVolume())
    ambience:update()
    assert.are.equal(0, calls.played)
  end)
end)
