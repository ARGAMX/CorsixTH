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

-- Crowd ambience: a continuously looping background noise whose volume follows
-- how many people are visible on screen.
--
-- The original game plays a single looping sample whose volume tracks the size
-- of the crowd. All of the functions used to work out that volume are kept free
-- of any audio or game state so that they can be tested on their own; the
-- Ambience class at the bottom is the thin layer that connects them to the
-- game.

-- The looping crowd sample.
local crowd_sound_name = "ATMOS.wav"

-- Crowd volume curve. The hospital has to be properly busy before the crowd is
-- heard at all: while four or fewer people are in view there is no sound, and
-- from there it builds logarithmically up to full volume at twenty people.
-- This came from playing the game, where the crowd was still too audible with a
-- single person on screen.
--
-- The growth is logarithmic because the difference between two quiet volumes
-- sounds larger than the same difference between two loud ones, so even
-- increases in the value below would sound like increasingly abrupt steps. The
-- sound system converts the value logarithmically as well
-- (linear_to_logarithmic_volume in th_sound.h), which keeps the total rise
-- reasonably even to the ear.
local crowd_silent_people = 4   -- People in view before the crowd is audible
local crowd_start_people = 5     -- People at which the crowd starts to be heard
local crowd_start_volume = 0.01  -- Volume at crowd_start_people
local crowd_max_people = 20      -- People at which the volume reaches 1.0

-- Natural log of the two ends of the ramp, worked out once since the curve is
-- evaluated every frame.
local crowd_log_start = math.log(crowd_start_people)
local crowd_log_span = math.log(crowd_max_people) - crowd_log_start

-- Size of the area in the middle of the view that the crowd is counted in,
-- in map screen pixels. This is deliberately a fixed size rather than the size
-- of the view: counting the whole view meant people appearing at its edge, with
-- little more than their legs showing, were already counted, and a larger
-- window brought that moment earlier.
local crowd_area_size = 400

-- How quickly the volume is allowed to move, as a fraction of full scale per
-- frame. The user interface ticks every 18ms (see usertick_period_ms in
-- CorsixTH/Src/lua_sdl.h), so this takes roughly 0.7s to travel the whole
-- range. The original game faded the crowd in and out rather than cutting it.
local volume_step_per_frame = 0.025

strict_declare_global "crowd_volume"
strict_declare_global "zoom_attenuation"
strict_declare_global "approach_volume"
strict_declare_global "count_visible_humanoids"

--! Work out the crowd volume for a number of visible people.
-- Silent until the hospital is busy enough, then rising logarithmically to full
-- volume at crowd_max_people.
--!param count (integer) Number of people visible on screen.
--!return (number) Volume in the range 0.0 to 1.0.
function crowd_volume(count)
  if count <= crowd_silent_people then
    return 0
  elseif count >= crowd_max_people then
    return 1
  end
  local rise = (math.log(count) - crowd_log_start) / crowd_log_span
  return crowd_start_volume + rise * (1 - crowd_start_volume)
end

--! Work out how much of the crowd volume survives at the current zoom.
-- The original game had no zoom, so a zoom of 1 is taken as full volume. The
-- further out the view is zoomed the quieter the crowd becomes, reaching
-- silence at the minimum zoom.
--!param zoom_factor (number) The current zoom factor.
--!param min_zoom (number) The smallest zoom factor the view allows.
--!return (number) Attenuation factor in the range 0.0 to 1.0.
function zoom_attenuation(zoom_factor, min_zoom)
  if min_zoom >= 1 then
    -- The view cannot be zoomed out past the original game's zoom, so there is
    -- no range to attenuate over.
    return 1
  end
  local attenuation = (zoom_factor - min_zoom) / (1 - min_zoom)
  if attenuation < 0 then
    return 0
  elseif attenuation > 1 then
    return 1
  end
  return attenuation
end

--! Move a volume towards its target without overshooting it.
--!param current (number) The volume to move.
--!param target (number) The volume to move towards.
--!param step (number) The largest amount to move by.
--!return (number) The new volume.
function approach_volume(current, target, step)
  if current < target then
    local raised = current + step
    return raised > target and target or raised
  elseif current > target then
    local lowered = current - step
    return lowered < target and target or lowered
  end
  return current
end

--! Count the people of a hospital who are inside the crowd area.
-- The area is a fixed size in the middle of the view rather than the whole
-- view. Counting the whole view meant people who were only just appearing at
-- the edge, sometimes no more than their legs showing, were already adding to
-- the crowd, and the wider the window the earlier that happened. A fixed area
-- keeps the count steady whatever the resolution.
--!param hospital (Hospital) The hospital to count the people of.
--!param left (number) Left edge of the crowd area in map screen coordinates.
--!param top (number) Top edge of the crowd area in map screen coordinates.
--!param right (number) Right edge of the crowd area in map screen coordinates.
--!param bottom (number) Bottom edge of the crowd area in map screen coordinates.
--!return (integer) The number of staff and patients in the crowd area.
function count_visible_humanoids(hospital, left, top, right, bottom)
  local map = hospital.world.map
  local count = 0
  local function count_list(humanoids)
    for _, humanoid in ipairs(humanoids) do
      local x, y = humanoid.tile_x, humanoid.tile_y
      if x and y then
        local screen_x, screen_y = map:WorldToScreen(x, y)
        if screen_x >= left and screen_x <= right
            and screen_y >= top and screen_y <= bottom then
          count = count + 1
        end
      end
    end
  end

  count_list(hospital.patients)
  count_list(hospital.staff)
  return count
end

-- Holds the playing crowd sample and keeps its volume up to date.
class "Ambience"

---@type Ambience
local Ambience = _G["Ambience"]

--! Create the crowd ambience for a hospital.
--!param app (App) The application.
--!param ui (GameUI) The user interface, used to find the current view.
--!param hospital (Hospital) The hospital whose crowd is heard.
function Ambience:Ambience(app, ui, hospital)
  self.app = app
  self.ui = ui
  self.hospital = hospital
  self.sound = nil
  self.volume = 0
  self.paused = false
  -- Guard against starting the sample before the sound effects are available,
  -- for example before the first hospital is up.
  self.available = app.audio:soundExists(crowd_sound_name)
end

--! The volume the crowd should currently be at.
--!return (number) Volume in the range 0.0 to 1.0.
function Ambience:getTargetVolume()
  if not self.available then
    return 0
  end

  -- Fully zoomed out there is no crowd worth hearing, so skip counting.
  local attenuation = zoom_attenuation(self.ui.zoom_factor,
      self.ui:calculateMinimumZoom())
  if attenuation == 0 then
    return 0
  end

  local zoom = self.ui:getEffectiveZoom()
  local scr_w, scr_h = self.app.video:getRenderSize()
  local left, top = self.ui:getScreenOffset()

  -- A fixed area centred on the view, measured in map screen pixels, so it
  -- covers the same part of the hospital at any resolution. Half the size is
  -- used because the area is centred on the middle of the view.
  local half = crowd_area_size / 2
  local centre_x = left + scr_w / zoom / 2
  local centre_y = top + scr_h / zoom / 2
  local count = count_visible_humanoids(self.hospital,
      centre_x - half, centre_y - half, centre_x + half, centre_y + half)

  -- Sound effects volume is applied here rather than left to the sound system,
  -- because setGain is absolute and so does not honour it by itself. Without
  -- this the ambience would ignore the player's sound effects volume setting.
  return crowd_volume(count) * attenuation * self.app.config.sound_volume
end

--! Bring the crowd volume one step closer to its target.
function Ambience:update()
  if self.app.world:isPaused() then
    if self.sound and not self.paused then
      self.app.audio:togglePauseSound(self.sound)
      self.paused = true
    end
    return
  end

  if self.paused then
    if self.sound then
      self.app.audio:togglePauseSound(self.sound)
    end
    self.paused = false
  end

  -- Follow the sound effects setting, so that turning sounds off silences the
  -- crowd along with everything else.
  local target = self.app.config.play_sounds and self:getTargetVolume() or 0
  if not self.sound then
    if target <= 0 then
      return
    end
    -- Start the loop quietly and let it fade up, rather than appearing at full
    -- volume on the first frame that has anyone on screen.
    local sound = self.ui:playSound(crowd_sound_name, nil, nil, -1)
    if not sound or type(sound.handle) ~= "number" then
      -- playSound returns nothing when sound effects are switched off, and a
      -- table holding something other than a handle when the sample is missing
      -- from the archive. Neither may be passed on to the sound system.
      self.available = false
      return
    end
    self.sound = sound
    self.volume = 0
  elseif not self.app.audio:isPlaying(self.sound) then
    -- The sample stopped on its own, so start it again from silence.
    self.sound = nil
    self.volume = 0
    return
  end

  local volume = approach_volume(self.volume, target, volume_step_per_frame)
  if volume ~= self.volume then
    self.volume = volume
    self.app.audio:setSoundGain(self.sound, volume)
  end
end

--! Stop the crowd ambience and release its sound channel.
function Ambience:destroy()
  if self.sound then
    self.app.audio:stopSound(self.sound)
    self.sound = nil
  end
  self.volume = 0
  self.paused = false
end

--! Forget the playing sample once a savegame has been loaded.
-- The loop started before the save was loaded is still going, so it has to be
-- stopped rather than dropped, or the two would overlap. The crowd then fades
-- back in rather than resuming part way through the sample.
function Ambience:onSavegameLoaded()
  self:destroy()
end