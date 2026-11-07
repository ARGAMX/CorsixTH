--[[ Copyright (c) 2026 Artem Argus "ARGAMX" Gusakov

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

--! The weighted reputation accounting of the original game.
--!
--! The original never adjusts the reputation a player sees. It keeps an
--! accumulated credit and an accumulated weight, and the rating is calculated
--! from the two:
--!
--!     rating = clamp(trunc(500 * credit / weight), 0, 1000)
--!
--! with a neutral 500 whenever the weight is not positive. Both start at 20, so
--! a new hospital opens at 500, and the non-zero starting weight is a buffer:
--! the first patient a hospital takes on moves it a long way, and the same
--! event matters less and less as the hospital grows. A single credit is worth
--! 500/weight points, so +1 credit is about +25 at weight 20 and about +2 at
--! weight 250.
--!
--! Two consequences of the model are easy to get wrong, and both were
--! confirmed against the original retail game:
--!
--!   - Registering a patient raises the weight without raising credit, so
--!     reputation can *fall* without anything bad happening. That is the whole
--!     of the decline a hospital sees while it is taking on more work than it
--!     has yet cured.
--!   - Percentage events change credit by a percentage *of the weight*, not of
--!     the rating, and the figure truncates toward zero. A +4% event at weight
--!     20 is worth exactly nothing.
--!
--! The weight is only ever raised, so a rating that cannot be reached by
--! arithmetic should be treated as a bug in the caller rather than clamped
--! silently here.

--! Truncate toward zero, as the original's integer division does.
--!math.floor rounds toward negative infinity, which would turn -2.5 into -3
--! rather than -2, and bias every negative percentage event.
--!param value (number) The value to truncate
--!return (integer) The value with its fraction discarded, toward zero
local function trunc(value)
  if value < 0 then
    return -math.floor(-value)
  end
  return math.floor(value)
end

class "ReputationAccount"

---@class ReputationAccount
---@operator call: ReputationAccount
local ReputationAccount = _G["ReputationAccount"] ---@type ReputationAccount

-- The event identifiers, named for the call sites that use them. Several of the
-- original's identifiers do nothing at all, so nothing is named for them.
--
-- Two of these have no caller, deliberately:
--
--   event_diagnosis_failed (5) fires on one random low-confidence branch inside
--   the original's diagnosis routine. CorsixTH has no equivalent branch, and
--   inventing one would add a penalty that was never observed.
--
--   event_researched (9) fires on "an eligible research result", gated on
--   research conditions and a research index bound with no counterpart in
--   CorsixTH's research list. Until it is clear which of CorsixTH's research
--   outcomes count as eligible, leaving it out is better than rewarding the
--   wrong ones.
--
-- Defining a constant is not the behaviour; the caller is. Every constant here
-- except those two should have exactly one place that raises it.
ReputationAccount.event_cured = 0
ReputationAccount.event_death = 3
ReputationAccount.event_diagnosis_failed = 5
ReputationAccount.event_researched = 9
ReputationAccount.event_disaster = 11
ReputationAccount.event_emergency_won = 12
ReputationAccount.event_emergency_lost = 13
ReputationAccount.event_epidemic = 14
ReputationAccount.event_inspection_failed = 15
ReputationAccount.event_vip_best = 16
ReputationAccount.event_vip_middle = 17
ReputationAccount.event_vip_poor = 18
ReputationAccount.event_autopsy_discovered = 19
ReputationAccount.event_diagnosed = 21
ReputationAccount.event_registered = 22
ReputationAccount.event_award = 23
ReputationAccount.event_penalty = 24

-- The neutral starting accounting. 20/20 gives 500, and the starting weight
-- keeps the first events from dominating the rating.
ReputationAccount.start_credit = 20
ReputationAccount.start_weight = 20

-- The bounds of the rating the panel displays, and the value used when there is
-- no weight to divide by.
ReputationAccount.rating_min = 0
ReputationAccount.rating_max = 1000
ReputationAccount.rating_neutral = 500

-- How each reputation event changes the accounting. An event describes at most
-- one of each kind of change, and the three are cumulative:
--
--   credit    a flat signed change to credit
--   weight    a flat signed change to weight
--   percent   a change to credit worth this percentage of the weight the event
--             scales from, truncated toward zero
--   amount    the caller's own signed figure multiplies `percent`
--
-- The events with no descriptor at all are the ones the original defines but
-- which change neither counter. Several of them sit on patient journeys, which
-- is precisely why "the patient left" is not by itself evidence of a penalty.
local event_changes = {
  [0] = {credit = 1},                    -- a patient is cured
  [1] = {},                              -- no direct effect
  [2] = {},                              -- no direct effect
  [3] = {credit = -1},                   -- a patient dies
  [4] = {},                              -- no direct effect
  [5] = {percent = -5},                  -- adverse diagnosis branch
  [6] = {credit = 1},                    -- simulated outcome, computer hospitals
  [7] = {},                              -- no direct effect
  [8] = {},                              -- no direct effect
  [9] = {percent = 5},                   -- research completed
  [10] = {},                             -- no direct effect
  [11] = {percent = -10},                -- machine disaster
  [12] = {percent = 2},                  -- emergency met its cure requirement
  [13] = {percent = -4, amount = true},  -- emergency fell short
  [14] = {percent = -2},                 -- epidemic reported and fined
  [15] = {percent = -10},                -- severe concealed-epidemic inspection
  [16] = {percent = 4},                  -- best VIP outcome
  [17] = {percent = 2},                  -- middle VIP outcome
  [18] = {percent = -4},                 -- poor VIP outcome
  [19] = {percent = -20},                -- an autopsy is discovered
  [20] = {credit = -1},                  -- defined but with no known caller
  [21] = {credit = 1},                   -- a diagnosis is newly established
  [22] = {weight = 1},                   -- a patient is registered
  [23] = {percent = 1, amount = true},   -- signed year-end award
  [24] = {percent = 1, amount = true},   -- signed year-end penalty
}

--! The rating a given credit and weight produce.
--!param credit (integer) The accumulated credit
--!param weight (integer) The accumulated weight
--!return (integer) The rating, 0 to 1000
function ReputationAccount.calculate(credit, weight)
  if weight <= 0 then
    return ReputationAccount.rating_neutral
  end

  local rating = trunc(500 * credit / weight)
  if rating < ReputationAccount.rating_min then
    return ReputationAccount.rating_min
  elseif rating > ReputationAccount.rating_max then
    return ReputationAccount.rating_max
  end
  return rating
end

--! The change an event makes to the accounting.
--!
--! The delta is calculated from the weight *before* the event, and it is
--! returned rather than applied so that the same figure can be given to the
--! hospital and, when the event names a disease, to that disease. Their two
--! histories differ, so the same delta produces two different rating changes.
--!
--! The weight to scale from is the caller's choice. Percentage events use the
--! hospital's weight, except research, which uses the named disease's weight
--! when there is one.
--!param event (integer) The event identifier, 0 to 24
--!param weight (integer) The weight to scale a percentage event from
--!param amount (integer) The caller's signed figure, for the events that use one
--!return (integer, integer) The change to credit and the change to weight
function ReputationAccount.eventDelta(event, weight, amount)
  local change = event_changes[event]
  if not change then
    error("Unknown reputation event: " .. tostring(event))
  end

  local delta_credit = change.credit or 0
  local delta_weight = change.weight or 0

  if change.percent then
    local percent = change.percent
    if change.amount then
      percent = percent * (amount or 0)
    end
    delta_credit = delta_credit + trunc(percent * weight / 100)
  end

  return delta_credit, delta_weight
end

--! The credit that moves a rating by a given number of points.
--!
--! The rating is `500 * credit / weight`, so one point of rating is worth
--! `weight / 500` of credit.
--!param points (integer) The signed number of rating points
--!param weight (integer) The weight to convert against
--!return (integer) The change to credit that moves the rating by that much
function ReputationAccount.pointsToCredit(points, weight)
  return trunc(points * weight / ReputationAccount.rating_neutral)
end

--! A credit and weight that show a given rating at a plausible scale.
--!
--! Only the ratio of credit to weight sets the rating, so any pair with the
--! right ratio restores it, and the rating on its own does not fix the weight.
--! The weight still has to be plausible, because it is what decides how fast
--! the rating moves: one credit is worth 500/weight points, so an account
--! rebuilt at the bare starting weight of 20 swings 25 points on every single
--! patient. A hospital that saved at 1000 would come back showing 1000 and then
--! bleed towards neutral over the following twenty patients - not because
--! anything the player did, but because it had been rebuilt as an account that
--! could not exist, with twice the credit of a hospital that has seen almost
--! nobody.
--!
--! The number of outcomes already seen is the honest answer, and it is also
--! what the weight would have been had the accounting existed all along, since
--! every registered patient adds exactly one.
--!
--! Below neutral the weight carries the rating and above it the credit does,
--! but with the weight already fixed both are the same arithmetic - only the
--! ratio matters - so one formula covers the whole range.
--!param rating (integer) The rating to reproduce, defaulting to neutral
--!param outcomes (integer) How many outcomes have been seen, which sets the
--! scale. Omitting it costs stability rather than correctness: the weight falls
--! back to its starting value and the rating moves at full speed.
--!return (integer, integer) The credit and the weight to restore
function ReputationAccount.accountingForRating(rating, outcomes)
  rating = rating or ReputationAccount.rating_neutral

  local weight = ReputationAccount.start_weight + math.max(0, outcomes or 0)

  -- Solve the credit that gives this weight the wanted ratio, then try the
  -- neighbouring integers either side, because the rating truncates and the
  -- exact figure is often not reachable.
  local solved = rating * weight / ReputationAccount.rating_neutral
  local best_credit, best_gap
  for _, credit in ipairs({math.floor(solved + 0.5), math.floor(solved), math.ceil(solved)}) do
    if credit >= 0 then
      local gap = math.abs(ReputationAccount.calculate(credit, weight) - rating)
      if not best_gap or gap < best_gap then
        best_credit, best_gap = credit, gap
      end
    end
  end

  return best_credit, weight
end

--! Create an account.
--!param credit (integer) The starting credit, defaulting to 20
--!param weight (integer) The starting weight, defaulting to 20
function ReputationAccount:ReputationAccount(credit, weight)
  self.credit = credit or ReputationAccount.start_credit
  self.weight = weight or ReputationAccount.start_weight
end

--! The rating this account currently shows.
--!return (integer) The rating, 0 to 1000
function ReputationAccount:rating()
  return ReputationAccount.calculate(self.credit, self.weight)
end

--! Move the accounting by a given amount.
--!param delta_credit (integer) The change to credit
--!param delta_weight (integer) The change to weight
--!return (integer) The rating after the change
function ReputationAccount:applyDelta(delta_credit, delta_weight)
  self.credit = self.credit + delta_credit
  self.weight = self.weight + (delta_weight or 0)
  return self:rating()
end

--! Apply one reputation event to this account.
--!param event (integer) The event identifier, 0 to 24
--!param weight (integer) The weight to scale a percentage event from
--!param amount (integer) The caller's signed figure, for the events that use one
--!return (integer) The rating after the event
function ReputationAccount:applyEvent(event, weight, amount)
  local delta_credit, delta_weight = ReputationAccount.eventDelta(event, weight, amount)
  return self:applyDelta(delta_credit, delta_weight)
end
