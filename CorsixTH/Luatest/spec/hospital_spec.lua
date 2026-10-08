--[[ Copyright (c) 2026 Joshua "gojomoso1" DeVries

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
require("map")
require("hospital")

local Hospital = _G["Hospital"]

describe("hospital.lua: ", function()
  -- Build a minimal duck-typed hospital that reuses the real rathole/debug
  -- rat methods, with only the map and world primitives stubbed out.
  local function createHospital(opts)
    opts = opts or {}
    local map = {
      th = {getCellFlags = function() return {roomId = 0, buildable = true} end},
      width = 10,
      height = 10,
      WorldToScreen = function(_, x, y) return x * 10, y * 10 end,
    }
    setmetatable(map, {__index = Map})

    local rat_spawns = {}
    local hospital = setmetatable({
      ratholes = opts.ratholes or {},
      world = {
        map = map,
        newObject = function() return {} end,
        newEntity = function()
          return {
            setTile = function(_, x, y) rat_spawns[#rat_spawns + 1] = {x = x, y = y} end,
            setTilePositionSpeed = function() end,
            init = function() end,
          }
        end,
      },
      isInHospital = function() return true end,
      getWallsAround = opts.get_walls_around or function() return {} end,
    }, {__index = Hospital})
    return hospital, rat_spawns
  end

  it("does not spawn a debug rat when no rathole can be found or created", function()
    local hospital, rat_spawns = createHospital()
    hospital:makeDebugRat(0, 0, 100, 100)
    assert.are.equal(0, #rat_spawns)
  end)

  it("does not fall back to an off-screen rathole for the debug spawn", function()
    local off_screen_hole = {x = 50, y = 50, wall = "north"}
    local hospital, rat_spawns = createHospital({ratholes = {off_screen_hole}})
    hospital:makeDebugRat(0, 0, 10, 10)
    assert.are.equal(0, #rat_spawns)
  end)

  it("spawns from a newly created visible hole", function()
    local get_walls_around = function(_, x, y)
      if x == 1 and y == 1 then return {{wall = "north", parcel = 1}} end
      return {}
    end
    local hospital, rat_spawns = createHospital({get_walls_around = get_walls_around})
    hospital:makeDebugRat(0, 0, 100, 100)
    assert.are.equal(1, #rat_spawns)
    assert.are.equal(1, rat_spawns[1].x)
    assert.are.equal(1, rat_spawns[1].y)
  end)

  it("spawns from an existing visible hole without adding new ones", function()
    local hole_a = {x = 2, y = 2, wall = "north"}
    local hole_b = {x = 3, y = 3, wall = "west"}
    local hospital, rat_spawns = createHospital({ratholes = {hole_a, hole_b}})
    hospital:makeDebugRat(0, 0, 100, 100)
    assert.are.equal(2, #hospital.ratholes) -- no new holes were created
    assert.are.equal(1, #rat_spawns)
    assert.is_true((rat_spawns[1].x == hole_a.x and rat_spawns[1].y == hole_a.y) or
        (rat_spawns[1].x == hole_b.x and rat_spawns[1].y == hole_b.y))
  end)
end)

describe("hospital.lua: insurance billing", function()
  -- A hospital with just enough state for addInsuranceMoney and logTransaction.
  -- logTransaction reads world:date() and the current balance, so both are
  -- stubbed here rather than pulling in a whole world.
  local function createBillingHospital(opts)
    opts = opts or {}
    local hospital = {
      world = {
        free_build_mode = opts.free_build_mode or false,
        date = function()
          return {
            dayOfMonth = function() return 7 end,
            monthOfYear = function() return 2 end,
          }
        end,
      },
      transactions = {},
      balance = opts.balance or 1000,
      money_in = opts.money_in or 500,
      insurance_balance = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}},
    }
    setmetatable(hospital, {__index = Hospital})
    return hospital
  end

  it("adds the amount to the insurer's balance for the current month", function()
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(2, 340)
    assert.are.equal(340, hospital.insurance_balance[2][1])
  end)

  it("does not credit the hospital balance, because the money is not paid yet", function()
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(2, 340)
    assert.are.equal(1000, hospital.balance)
  end)

  it("does not count the amount as money in", function()
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(2, 340)
    assert.are.equal(500, hospital.money_in)
  end)

  it("logs the amount so the treatment is not left unaccounted for", function()
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(2, 340, "Insurance: Bloaty Head")
    assert.are.equal(1, #hospital.transactions)
    assert.are.equal(340, hospital.transactions[1].insurance)
  end)

  it("logs the balance unchanged, so the statement does not imply the money is held", function()
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(2, 340, "reason")
    assert.are.equal(1000, hospital.transactions[1].balance)
  end)

  it("does not record the amount as received money", function()
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(2, 340, "reason")
    assert.is_nil(hospital.transactions[1].receive)
  end)

  it("does not record the amount as spent money", function()
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(2, 340, "reason")
    assert.is_nil(hospital.transactions[1].spend)
  end)

  it("carries neither a received nor a spent amount, so both money columns stay empty", function()
    -- The statement draws a money column only when spend or receive is set, so
    -- an entry with neither leaves the money in and money out cells blank.
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(2, 340, "Insurance: Bloaty Head")
    local entry = hospital.transactions[1]
    assert.is_true(entry.receive == nil and entry.spend == nil)
  end)

  it("stamps the log entry with the current date", function()
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(2, 340, "reason")
    assert.are.equal(7, hospital.transactions[1].day)
    assert.are.equal(2, hospital.transactions[1].month)
  end)

  it("keeps the description it was given", function()
    local hospital = createBillingHospital()
    local reason = "Insurance: Bloaty Head"
    hospital:addInsuranceMoney(2, 340, reason)
    assert.are.equal(reason, hospital.transactions[1].desc)
  end)

  it("does not log anything in free build mode", function()
    local hospital = createBillingHospital({free_build_mode = true})
    hospital:addInsuranceMoney(2, 340, "reason")
    assert.are.equal(0, #hospital.transactions)
  end)

  it("still banks the insurer's balance in free build mode, matching the previous behaviour", function()
    -- receiveMoney guards its own side effects on free_build_mode, so the
    -- balance entry must not become conditional on it too.
    local hospital = createBillingHospital({free_build_mode = true})
    hospital:addInsuranceMoney(2, 340, "reason")
    assert.are.equal(340, hospital.insurance_balance[2][1])
  end)

  it("accumulates several billings to the same insurer in the same month", function()
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(1, 100, "first")
    hospital:addInsuranceMoney(1, 250, "second")
    assert.are.equal(350, hospital.insurance_balance[1][1])
    assert.are.equal(2, #hospital.transactions)
  end)

  it("keeps separate insurers separate", function()
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(1, 100, "first")
    hospital:addInsuranceMoney(3, 700, "second")
    assert.are.equal(100, hospital.insurance_balance[1][1])
    assert.are.equal(0, hospital.insurance_balance[2][1])
    assert.are.equal(700, hospital.insurance_balance[3][1])
  end)

  it("does not change the balance of any other month slot", function()
    local hospital = createBillingHospital()
    hospital.insurance_balance[2] = {50, 60, 70}
    hospital:addInsuranceMoney(2, 340)
    assert.are.equal(390, hospital.insurance_balance[2][1])
    assert.are.equal(60, hospital.insurance_balance[2][2])
    assert.are.equal(70, hospital.insurance_balance[2][3])
  end)

  it("logs without a description rather than failing", function()
    -- The reason is optional so a caller that has none can still record the
    -- event. The statement draws an empty details cell rather than crashing.
    local hospital = createBillingHospital()
    hospital:addInsuranceMoney(2, 340)
    assert.are.equal(1, #hospital.transactions)
    assert.is_nil(hospital.transactions[1].desc)
  end)
end)

describe("hospital.lua: insurance billing description", function()
  -- receiveMoneyForTreatment builds the statement wording, and the wording is
  -- what overflowed the details column the first time round, so it is pinned
  -- here rather than left to be eyeballed in game.
  local function createTreatment(opts)
    opts = opts or {}
    local real_S = _G['_S']
    _G['_S'] = {
      transactions = {
        cure_colon = "Cure:",
        treat_colon = "Treat:",
        insurance_colon = "Insurance:",
      },
    }
    local billed
    local hospital = {
      world = {
        free_build_mode = false,
        date = function()
          return {dayOfMonth = function() return 4 end, monthOfYear = function() return 3 end}
        end,
      },
      transactions = {},
      balance = 2000,
      money_in = 800,
      insurance = {"Mutant United", "Ethicare", "Beauregard"},
      insurance_balance = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0}},
      disease_casebook = {
        d1 = {disease = {name = opts.disease or "Bloaty Head"}, pseudo = false, money_earned = 0},
      },
      getTreatmentPrice = function() return 500 end,
      computePriceLevelImpact = function() end,
      addInsuranceMoney = function(_, company, amount, reason)
        billed = {company = company, amount = amount, reason = reason}
      end,
      receiveMoney = function() end,
    }
    setmetatable(hospital, {__index = Hospital})
    local patient = {
      insurance_company = opts.insurance_company,
      pay_amount = opts.amount,
      world = {newFloatingDollarSign = function() end},
      getTreatmentDiseaseId = function() return opts.disease_id or "d1" end,
    }
    return hospital, patient, function() return billed end,
        function() _G['_S'] = real_S end
  end

  it("names the insurer's payment rather than repeating the treatment", function()
    local hospital, patient, billed, restore = createTreatment({insurance_company = 2, amount = 340})
    hospital:receiveMoneyForTreatment(patient)
    assert.are.equal("Insurance: Bloaty Head", billed().reason)
    restore()
  end)

  it("keeps the description short enough for the details column", function()
    local hospital, patient, billed, restore = createTreatment({insurance_company = 2, amount = 340})
    hospital:receiveMoneyForTreatment(patient)
    -- The first wording was "Cure: Bloaty Head - billed to insurance: Mutant
    -- United", which ran off the right of the screen.
    assert.is_true(#billed().reason <= 30)
    restore()
  end)

  it("credits the company the patient's policy names", function()
    local hospital, patient, billed, restore = createTreatment({insurance_company = 3, amount = 700})
    hospital:receiveMoneyForTreatment(patient)
    assert.are.equal(3, billed().company)
    assert.are.equal(700, billed().amount)
    restore()
  end)

  it("does nothing for a patient paying themselves", function()
    local hospital, patient, billed, restore = createTreatment({amount = 340})
    hospital:receiveMoneyForTreatment(patient)
    assert.is_nil(billed())
    restore()
  end)
end)
