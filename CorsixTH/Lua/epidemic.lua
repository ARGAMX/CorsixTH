--[[ Copyright (c) 2013 William "sadger" Gatens

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

corsixth.require("announcer")

local AnnouncementPriority = _G["AnnouncementPriority"]

class "Epidemic"

---@type Epidemic
local Epidemic = _G["Epidemic"]

--[[Manages the epidemics that occur in hospitals. Generally, any epidemic
logic that happens outside this class will call functions contained here.]]
function Epidemic:Epidemic(hospital, contagious_patient)
  self.hospital = hospital
  self.world = self.hospital.world

  -- Epidemic participants
  self.infected_patients = {}

  -- The contagious disease the epidemic is based around
  self.disease = contagious_patient.disease

  -- Can the epidemic be revealed to the player
  self.ready_to_reveal = false

  -- Is the epidemic revealed to the player?
  self.revealed = false

  -- Various values for the different outcomes - used when result fax is sent
  self.declare_fine = 0
  self.reputation_hit = 0
  self.coverup_fine = 0
  self.compensation = 0

  -- Is the epidemic bad enough to deserve the whole hospital to be evacuated
  self.will_be_evacuated = false

  -- Fax sent when the result of the cover up is revealed to the player
  self.cover_up_result_fax = {}

  -- Set if the user choses the cover up option instead of declaring
  self.coverup_selected = false

  --Cover up timer and amount of intervals the timer has
  self.timer = nil
  self.countdown_intervals = 0

  -- Vaccination mode is activated when the icon on the timer
  -- is clicked - used to determine what the cursor should look like
  self.vaccination_mode_active = false

  -- For Cheat - Show the contagious icon even before the epidemic is revealed?
  self.cheat_always_show_mood = false

  -- Number of times an infected patients has successfully infected another
  self.total_infections = 0
  -- Number of times any infected patient has tried to infected another - successful or not
  self.attempted_infections = 0

  local level_config = self.world.map.level_config
  -- How often is the epidemic disease passed on? Represents a percentage
  -- spread_factor% of the time a disease is passed on to a suitable target
  self.spread_factor = level_config.gbv.ContagiousSpreadFactor or 25
  -- How many people still infected and not cure causes the player to take a reputation hit as well as a fine
  -- has no effect if more than evacuation_minimum - hospital is evacuated anyway
  self.reputation_loss_minimum = level_config.gbv.EpidemicRepLossMinimum or 5
  -- How many people need to still be infected and not cure to cause the
  -- inspector to evacuate the hospital
  self.evacuation_minimum = level_config.gbv.EpidemicEvacMinimum or 10

  -- The health inspector who reveals the result of the epidemic
  self.inspector = nil

  self:addContagiousPatient(contagious_patient)
  -- Mark all the patients currently in the hospital as passed reception - for compatibility
  self:markPatientsAsPassedReception()
end

--[[ The epidemic tick - currently the same rate as the hospital's tick but
not necessary dependent on it - could potentially be reduced for performance.]]
function Epidemic:tick()
  self:infectOtherPatients()
  self:checkIfReadyToReveal()
  self:showAppropriateAdviceMessages()
  self:tryAnnounceInspector()
  self:markedPatientsCallForVaccination()
  self:checkInfectedLeftHospital()
  self:checkNoInfectedPatients()
  self:checkPatientsForRemoval()
end

--[[ Adds a new patient to the epidemic who is actively contagious: infected but
  not vaccinated or cured]]
function Epidemic:addContagiousPatient(patient)
  patient.infected = true
  patient:updateDynamicInfo()
  self.infected_patients[#self.infected_patients + 1] = patient
  if self.coverup_selected or self.cheat_always_show_mood then
    patient:setInfectedStatus()
  end
end

--[[ Goes through all infected patients checking if there are any other patients
 in adjacent squares that can be infected, and if so infects them turning
 them into an infected patient too. ]]
function Epidemic:infectOtherPatients()
  --[[ Can an infected patient infect another patient - taking into account
  spread factor as defined in the configuration. Patients must be both in the
  corridors or in the same room - don't infect through walls.
  @param infector (Patient) already infected patient who want to infect
  @param victim (Patient) target to possibly infect
  @return true if patient can infect other, false otherwise (boolean) ]]
  local function canInfectOther(infector, victim)
    -- Check is patient-Infector is not infectious.
    if infector.cured or infector.vaccinated then return false end

    -- Don't allow infection outside the hospital grounds
    -- Also check both patients to prevent infecting through outer walls
    local ppx, ppy = infector.tile_x, infector.tile_y
    if ppx and ppy and not self.hospital:isInHospital(ppx, ppy) then return false end
    local opx, opy = victim.tile_x, victim.tile_y
    if opx and opy and not self.hospital:isInHospital(opx, opy) then return false end

    -- 'victim' is already infected or is going home.
    if victim.infected or victim.cured or victim.vaccinated then return false end
    -- Don't infect victim if it alredy under another attempt to be infected
    if victim.under_infection_attempt then return false end
    -- Don't infect emergencies.
    if victim.is_emergency then return false end

    -- If the victim patient has a different disease OR the victim patient's
    -- disease cannot be changed.
    if infector.disease ~= victim.disease and
        (not victim.disease.contagious or victim.diagnosed) then return false end

    -- Only infect if both are in the same room.
    return infector:getRoom() == victim:getRoom()
  end

  local function infect_other(infector, victim)
    if infector.disease ~= victim.disease then
      victim:changeDisease(infector.disease)
    end
    self:addContagiousPatient(victim)
    self.total_infections = self.total_infections + 1
  end

  -- Scale the chance of spreading the disease infecting spread_factor%
  -- of patients results in too large an epidemic typically so infect
  -- spread_factor/spread_scale_factor patients.
  -- This scale factor is purely for balance purposes, the larger the
  -- value the less spreading the epidemics will be, all relative to spread_factor.
  -- Must be > 0.
  local spread_scale_factor = 200

  -- Go through all infected patients making the check if they can infect
  -- and making any patient they can infect contagious too.
  local entity_map = self.world.entity_map
  if entity_map then
    for _, infector in ipairs(self.infected_patients) do
      local adjacent_patients =
      entity_map:getPatientsInAdjacentSquares(infector.tile_x, infector.tile_y)
      for _, potential_victim in ipairs(adjacent_patients) do
        if canInfectOther(infector, potential_victim) then
          potential_victim.under_infection_attempt = true
          self.attempted_infections = self.attempted_infections + 1
          if (self.total_infections / self.attempted_infections) <
              (self.spread_factor / spread_scale_factor) then
            infect_other(infector, potential_victim)
          end
        end
      end
    end
  end

end

--[[ The epidemic is ready to be revealed to the player if any infected patient
 is fully diagnosed. N.B. because multiple epidemics are queued to become
 the "active" one, being ready to reveal does NOT guarantee an epidemic
 WILL be revealed to the player and may even terminate before they are even
 aware it existed. ]]
function Epidemic:checkIfReadyToReveal()
  if self.ready_to_reveal then return end

  for _, infected_patient in ipairs(self.infected_patients) do
    if infected_patient.diagnosed then
      self.ready_to_reveal = true
      break
    end
  end
end

--[[ Show the player the have an epidemic - send a fax
 This happens when the epidemic is chosen to the be
 the "active" epidemic out of all the queued ones.]]
function Epidemic:revealEpidemic()
  assert(self.ready_to_reveal)
  self.revealed = true
  self:sendInitialFax()
  self:announceStartOfEpidemic()
end

--[[ Plays the announcement for the start of the epidemic ]]
function Epidemic:announceStartOfEpidemic()
  local announcements = {"EPID001.wav", "EPID002.wav", "EPID003.wav", "EPID004.wav"}
  if self.hospital:isPlayerHospital() then
    self.world.ui:playAnnouncement(announcements[math.random(1, #announcements)], AnnouncementPriority.Critical)
  end
end


--[[ Plays the announcement for the end of the epidemic ]]
function Epidemic:announceEndOfEpidemic()
  local announcements = {"EPID005.wav", "EPID006.wav", "EPID007.wav", "EPID008.wav"}
  if self.hospital:isPlayerHospital() then
    self.world.ui:playAnnouncement(announcements[math.random(1, #announcements)], AnnouncementPriority.Critical)
  end
end

--[[ Check for conditions that one of the infected and not cured
patient leaved the hospital. This discover epidemic to public instantly.
So cover up must end earlier than the length of the timer.]]
function Epidemic:checkInfectedLeftHospital()
  if not self:_isCoverUpActive() then return end

  -- Check whether a patient has left.
  for _, infected_patient in ipairs(self.infected_patients) do
    local px, py = infected_patient.tile_x, infected_patient.tile_y
    -- If leaving and no longer in the hospital.
    if infected_patient.going_home and not infected_patient.cured and
        px and py and not self.hospital:isInHospital(px,py) then
      -- Patient escaped from the hospital, discovery is inevitable.
      self:finishCoverUp()
      return
    end
  end
end

--[[ Check for conditions that no any uncured infected patients
left in hospital. If so then cover up must end earlier than the
length of the timer.]]
function Epidemic:checkNoInfectedPatients()
  if not self:_isCoverUpActive() then return end

  if self:countInfectedPatients() == 0 then
    self:finishCoverUp()
  end
end

--[[Remove any patients which were already on their way out or died before the
epidemic was started to be fair on the players so they don't instantly fail.
Additionally if any patients die during an epidemic we also remove them,
otherwise a player may never win the epidemic in such a case.]]
function Epidemic:checkPatientsForRemoval()
  for i = #self.infected_patients, 1, -1 do
    local infected_patient = self.infected_patients[i]
    if (not self.coverup_selected and infected_patient.going_home) or
        infected_patient.dead or infected_patient.tile_x == nil then
      table.remove(self.infected_patients,i)
    end
  end
end

--[[ Toggle the vaccination mode changes how the cursor interacts with
 the hospital. Toggled by pressing the button on the watch
(@see UIWatch:UIWatch) ]]
function Epidemic:toggleVaccinationMode()
  self.vaccination_mode_active = not self.vaccination_mode_active
  self:_updateVaccinationCursor()
end

--[[ Turn off vaccination cursor mode ]]
function Epidemic:turnOffVaccinationMode()
  self.vaccination_mode_active = false
  self:_updateVaccinationCursor()
end

--[[ Update how the cursor interacts with the hospital. ]]
function Epidemic:_updateVaccinationCursor()
  local cursor = self.vaccination_mode_active and "epidemic_hover" or "default"
  self.world.ui:setCursor(self.world.ui.app.gfx:loadMainCursor(cursor))
end

--[[ Show a patient is able to be vaccinated, this is shown to the player by
 changing the icon, once a player has been marked for vaccination they may
 possibly become a vaccination candidate. Marking is done by clicking
 the player and can only happen during a cover up. ]]
function Epidemic:markForVaccination(patient)
  if patient.infected and not patient.vaccinated and
      not patient.marked_for_vaccination then
    patient:setToReadyForVaccinationStatus()
    patient.hospital:playSound("vaccin.wav")
  end
end

--[[ Counts the number of patients that have been infected that are still
-- infected
-- @return infected_count (Integer) the number of patients still infected.]]
function Epidemic:countInfectedPatients()
  local infected_count = 0
  for _, patient in pairs(self.infected_patients) do
    if patient.infected and not patient.cured then
      infected_count = infected_count + 1
    end
  end
  return infected_count
end

--[[ Sends the initial fax to the player when the epidemic is revealed.]]
function Epidemic:sendInitialFax()
  local num_infected = self:countInfectedPatients()
  --Save it in a global variable so we can apply the fine in the declare function
  self.declare_fine = self:calculateInfectedFine(num_infected)

  local message = {
    {text = _S.fax.epidemic.disease_name:format(self.disease.name)},
    {text = _S.fax.epidemic.declare_explanation_fine:format(self.declare_fine)},
    {text = _S.fax.epidemic.cover_up_explanation_1},
    {text = _S.fax.epidemic.cover_up_explanation_2},
    choices = {
      {text = _S.fax.epidemic.choices.declare, choice = "declare_epidemic"},
      {text = _S.fax.epidemic.choices.cover_up, choice = "cover_up_epidemic"},
    },
  }
  self.world.ui.bottom_panel:queueMessage("epidemy", message, self, 24*20,2)
end

--[[ Calculate the fine for having a given number of infected patients
--Used to determine the initial declaration fine as the cover up fine.
--@param infected_count (Integer) number of patients still infected
--@return fine (Integer) the fine amount ]]
function Epidemic:calculateInfectedFine(infected_count)
  local level_config = self.world.map.level_config
  local fine_per_infected = level_config.gbv.EpidemicFine or 2000
  return math.max(2000, infected_count * fine_per_infected)
end

--[[ Gets the amount of reputation to add/remove from the player
 based on a given fine. Reputation gain/loss isn't specified
 in the configs so we use a percentage of the fine as a base
 value with extra being gained/lost for specific circumstances.
 @param fine_amount (Integer) amount the player will be fined
 @return reputation hit (Integer) reputation to be deducted relative to fine]]
local function getBaseReputationFromFine(fine_amount)
  return math.round(fine_amount / 100)
end

--[[ When the player chooses to declare the epidemic instead of trying
 to cover up it from the initial faxes - ends the epidemic immediately
 after applying fine.]]
function Epidemic:resolveDeclaration()
  self:clearAllInfectedPatients()

  --No fax for declaration just apply fines and rep hit
  self.hospital:spendMoney(self.declare_fine, _S.transactions.epidemy_fine)
  local reputation_hit = getBaseReputationFromFine(self.declare_fine)
  self.hospital.reputation = self.hospital.reputation - reputation_hit
  self.hospital.epidemic = nil
end

--[[ Remove all infected patients by vaccinating from the hospital and clear
 any epidemic-specific icons from their heads.]]
function Epidemic:clearAllInfectedPatients()
  for _, infected_patient in ipairs(self.infected_patients) do
    -- Remove any vaccination calls still open
    infected_patient:removeVaccinationCandidateStatus()
    self.world.dispatcher:dropFromQueue(infected_patient)
    infected_patient.vaccinated = true
    infected_patient:removeAnyEpidemicStatus()
  end
end


--[[ When the player chooses to begin the cover up over declaring from the
 initial fax (@see sendInitialFax) ]]
function Epidemic:startCoverUp()
  self.timer = UIWatch(self.world.ui, "epidemic")
  self.countdown_intervals = self.timer.open_timer
  self.world.ui:addWindow(self.timer)
  -- last chance clean up as entities might have ticked and changed state
  self:checkPatientsForRemoval()
  self.coverup_selected = true
  --Set the mood icon for all infected patients
  for _, infected_patient in ipairs(self.infected_patients) do
    infected_patient:updateDynamicInfo()
    infected_patient:setInfectedStatus()
  end
end

--[[ Ends the cover up epidemic stage ]]
function Epidemic:finishCoverUp()
  if not self.inspector then
    self:spawnInspector()
  end

  self.timer:close()

  -- Turn vaccination mode off if enabled
  self:turnOffVaccinationMode()
end

--[[ Inspector had arrived at reception desk. Check if
any infected still in hospital and determine final verdict.]]
function Epidemic:handleInspectorArrival()
  local still_infected = self:countInfectedPatients()
  self:determineFaxAndFines(still_infected)
  self:clearAllInfectedPatients()
  self:applyOutcome()
end

--[[ Epidemic timer time is up ]]
function Epidemic:coverUpTimeIsUp()
  self:finishCoverUp()
end

--[[ Calculates the contents of the fax and the appropriate fines based on the
result of a cover up, results are stored globally to the class to be applied later.
 @param still_infected (Integer) the number of patients still infected]]
function Epidemic:determineFaxAndFines(still_infected)

  -- Losing text
  local fail_text_1 = _S.fax.epidemic_result.failed.part_1_name:format(self.disease.name)
  local fail_text_2 = _S.fax.epidemic_result.failed.part_2
  local close_option = {text = _S.fax.epidemic_result.close_text, choice = "close"}

  -- Losing fine (if epidemic is "lost")
  self.coverup_fine = self:calculateInfectedFine(still_infected)

  if still_infected == 0 then
    -- Compensation fine (if epidemic is "won")
    local level_config = self.world.map.level_config
    local compensation_low_value = level_config.gbv.EpidemicCompLo or 1000
    local compensation_high_value = level_config.gbv.EpidemicCompHi or 5000
    self.compensation = math.random(compensation_low_value,compensation_high_value)

    self.cover_up_result_fax = {
      {text = _S.fax.epidemic_result.succeeded.part_1_name:format(self.disease.name)},
      {text = _S.fax.epidemic_result.succeeded.part_2},
      {text = _S.fax.epidemic_result.compensation_amount:format(self.compensation)},
      choices = {close_option}
    }
  elseif still_infected < self.reputation_loss_minimum and still_infected < self.evacuation_minimum then
    self.cover_up_result_fax = {
      {text = fail_text_1},
      {text = fail_text_2},
      {text = _S.fax.epidemic_result.fine_amount:format(self.coverup_fine)},
      choices = {close_option}
    }
  elseif still_infected >= self.reputation_loss_minimum and still_infected < self.evacuation_minimum then
    self.cover_up_result_fax = {
      {text = fail_text_1},
      {text = fail_text_2},
      {text = _S.fax.epidemic_result.rep_loss_fine_amount:format(self.coverup_fine)},
      choices = {close_option}
    }
  else
    self.will_be_evacuated = true
    self.cover_up_result_fax = {
      {text = fail_text_1},
      {text = fail_text_2},
      {text = _S.fax.epidemic_result.hospital_evacuated},
      choices = {close_option}
    }
  end
end

--[[ Apply the compensation or fines where appropriate to the player as
determined when the cover up was completed (@see finishCoverUp) ]]
function Epidemic:applyOutcome()
  -- If there is no compensation to apply the epidemic has been failed
  if self.compensation == 0 then
    if self.will_be_evacuated then
      self.reputation_hit = math.round(self.hospital.reputation * (1/3))
      self:evacuateHospital()
    else
      self.reputation_hit = getBaseReputationFromFine(self.coverup_fine)
    end
    -- Apply fine and reputation hit
    self.hospital:spendMoney(self.coverup_fine,_S.transactions.epidemy_coverup_fine)
    self.hospital.reputation = self.hospital.reputation - self.reputation_hit
  else
    self.hospital:receiveMoney(self.compensation, _S.transactions.compensation)
  end
  -- Finally send the fax confirming the outcome
  self:sendResultFax()
  --Remove epidemic from hospital so another epidemic may be assigned
  self.hospital.epidemic = nil
end

--[[ For compatibility. Mark all the current patients who are in the hospital
--but not in the reception queues as being "passed reception" used to decide
--who is evacuated @see evacuateHospital. For new patients they are marked
--as they leave the reception desks.]]
function Epidemic:markPatientsAsPassedReception()
  local queuing_patients = {}
  for _, desk in ipairs(self.hospital:findReceptionDesks()) do
    for _, patient in ipairs(desk.queue) do
      -- Use patient as map key to speed up lookup
      queuing_patients[patient] = true
    end
  end

  for _, patient in ipairs(self.hospital.patients) do
    -- Patient is not queuing for reception
    local px, py = patient.tile_x, patient.tile_y
    if px and py and self.hospital:isInHospital(px,py) and queuing_patients[patient] == nil then
      patient.has_passed_reception = true
    end
  end
end

--[[ Forces evacuation of the hospital - it makes ALL patients leave and storm out. ]]
function Epidemic:evacuateHospital()
  for _, patient in ipairs(self.hospital.patients) do
    if patient.has_passed_reception and not patient.going_home then
      patient:goHome("evacuated")
    end
  end
end

--[[ Send the results of the cover up to the player - will be a
success/compensation or fail/fines + reputation hit]]
function Epidemic:sendResultFax()
  self.world.ui.bottom_panel:queueMessage("report", self.cover_up_result_fax, nil, 24*20, 1)
  self:announceEndOfEpidemic()
end

--[[ Spawns the inspector who will walk to the reception desk. ]]
function Epidemic:spawnInspector()
  self.world.ui.adviser:say(_A.information.epidemic_health_inspector)
  local inspector = self.world:newEntity("Inspector", 2, 2)
  self.inspector = inspector
  inspector:setType("Inspector")

  local spawn_point = self.world.spawn_points[math.random(1, #self.world.spawn_points)]
  inspector:setNextAction(SpawnAction("spawn", spawn_point))
  inspector:setHospital(self.hospital)
  inspector:queueAction(SeekReceptionAction())
end

--[[ Private function to check if a inspector already spawned.
@return (boolean) true if spawned already, false if not]]
function Epidemic:_inspectorSpawned()
  return self.inspector ~= nil
end

--[[ Private function to check if a cover up is in progress
@return (boolean) true if cover up in progress, false if not]]
function Epidemic:_isCoverUpActive()
  return self.coverup_selected and not self:_inspectorSpawned()
end

--[[ Is the patient "still" either idle queuing or sitting on a bench
  Typically this is used to determine if a patient can be vaccinated
  @param patient (Patient) the patient we wish to determine if they are static.]]
local function is_static(patient)
  local action = patient:getCurrentAction()
  return action.name == "queue" or action.name == "idle" or action.name == "seek_room" or
      (action.name == "use_object" and action.object.object_type.id == "bench")
end

--[[ During a cover up every patient marked for vaccination (clicked)
 creates a call to be vaccinated by a nurse - patients must also be static
 (seated or standing queuing) ]]
function Epidemic:markedPatientsCallForVaccination()
  for _, infected_patient in ipairs(self.infected_patients) do
    if infected_patient.marked_for_vaccination and
        not infected_patient.reserved_for and is_static(infected_patient) then
      self.world.dispatcher:callNurseForVaccination(infected_patient)
    end
  end
end

--[[ In response to a vaccination call by the vaccination candidate
  (@see makeVaccinationCandidateCallForNurse) perform the vaccination
  actions or deal with call if unable to vaccinate.
  @param patient (Patient) the patient who make the original call
  @param nurse (Nurse) the nurse attempting to vaccinate the patient]]
function Epidemic:createVaccinationActions(patient,nurse)
  patient.reserved_for = nurse
  -- Check square is reachable first
  local x,y = self:getBestVaccinationTile(nurse,patient)
  -- If unreachable patient keep the call open for now
  if not x or not y then
    nurse:setCallCompleted()
    patient.reserved_for = nil
    nurse:setNextAction(MeanderAction())
    patient:removeVaccinationCandidateStatus()
  else
    -- Give selected patient the cursor with the arrow once they are next
    -- in line for vaccination i.e. call assigned
    patient:giveVaccinationCandidateStatus()
    local level_config = self.world.map.level_config
    local fee = level_config.gbv.VacCost or 50
    nurse:setDynamicInfoText(_S.dynamic_info.staff.actions.vaccine)
    nurse:setNextAction(WalkAction(x, y):setMustHappen(true):enableWalkingToVaccinate())
    nurse:queueAction(VaccinateAction(patient, fee))
  end
end


--[[Find the best tile to stand on to vaccinate a patient
 @param nurse (Nurse) the nurse performing the vaccination
 @param patient (Patient) the patient to be vaccinated
 @return best_x,best_y (Integer,nil) the best tiles to vaccinate from.]]
function Epidemic:getBestVaccinationTile(nurse, patient)
  local px, py = patient.tile_x, patient.tile_y
  -- If the patient is using a bench the best tile to use is
  -- directly in front of them
  local action = patient:getCurrentAction()
  if action.name == "use_object" then
    local object_in_use = action.object
    if object_in_use.object_type.id == "bench" then
      local direction = object_in_use.direction
      if direction == "north" then
        return px, py - 1

      elseif direction == "south" then
        return px, py + 1

      elseif direction == "east" then
        return px + 1, py

      elseif direction == "west" then
        return px - 1, py
      end
    end
  end

  -- General usage tile finder, used in the other cases
  -- when the patient isn't sitting on a bench

  -- Location of the nurse
  local nx, ny = nurse.tile_x, nurse.tile_y

  local best_x, best_y = nil
  local shortest_distance = nil
  local free_tiles = self.world.entity_map:getAdjacentFreeTiles(px, py)

  for _, coord in ipairs(free_tiles) do
    local x = coord['x']
    local y = coord['y']

    local distance = self.world:getPathDistance(nx, ny, x, y)
    -- If the tile is reachable for the nurse
    if distance then
      -- If the tile is closer then it's a better choice
      if not shortest_distance or distance < shortest_distance then
        shortest_distance = distance
        best_x, best_y = x, y
      end
    end
  end
  return best_x, best_y
end

--[[When the nurse is interrupted unreserve the patient and unassign the call.
  @param nurse (Nurse) the nurse whose vaccination actions we are interrupting]]
function Epidemic:interruptVaccinationActions(nurse)
  assert(nurse.humanoid_class == "Nurse")
  local call = nurse.on_call
  if call then
    local patient = call.object
    if patient and patient.vaccination_candidate and not patient.vaccinated then
      patient:removeVaccinationCandidateStatus()
    end
    call.object.reserved_for = nil
    call.assigned = nil
    nurse.on_call = nil
  end
end

--[[ Make the advisor show appropriate messages under certain
  conditions of the epidemic.]]
function Epidemic:showAppropriateAdviceMessages()
  if not self:_isCoverUpActive() then return end

  if self.countdown_intervals then
    if not self.has_said_hurry_up and self:countInfectedPatients() > 0 and
        -- If only 1/4 of the countdown_intervals remaining on the timer
        self.timer.open_timer == math.floor(self.countdown_intervals * 1 / 4) then
      self.world.ui.adviser:say(_A.epidemic.hurry_up)
      self.has_said_hurry_up = true

    -- Wait until at least 1/4 of the countdown_intervals has expired before giving
    -- this warning so it doesn't happen straight away
    elseif self.timer.open_timer <= math.floor(self.countdown_intervals * 3 / 4) and
        not self.has_said_serious and self:countInfectedPatients() > 10 then
      self.world.ui.adviser:say(_A.epidemic.serious_warning)
      self.has_said_serious = true
    end
  end
end

--[[ Are no infected patients, cured or still infected in the hospital?
@returns true if so, false otherwise. (boolean) ]]
function Epidemic:hasNoInfectedPatients()
  return #self.infected_patients == 0
end

function Epidemic:tryAnnounceInspector()
  if not self.coverup_selected then return end
  if not self:_inspectorSpawned() then return end

  local inspector = self.inspector
  if not inspector.has_been_announced and
    self.hospital:isInHospital(inspector.tile_x, inspector.tile_y) then
    inspector:announce()
    inspector.has_been_announced = true
  end
end

--[[ For Cheat - Cancel the epidemic. ]]
function Epidemic:cancelEpidemic()
  -- Remove init epidemic fax
  self.world.ui.bottom_panel:removeMessage(self)
  -- Turn vaccination mode off if enabled
  self:turnOffVaccinationMode()
  -- Remove epidemic timer
  if self.timer ~= nil then
    self.timer:close()
  end
  -- Send inspector home if spawned
  if self.inspector ~= nil then
    self.inspector:goHome()
  end
  -- Clear epidemic patients
  self:clearAllInfectedPatients()
  self.infected_patients = {}
end

function Epidemic:afterLoad(old, new)
  if old < 106 then
    self.level_config = nil
  end
  if old < 212 then
    self.coverup_selected = self.coverup_in_progress
    self.coverup_in_progress = nil
  end
end
