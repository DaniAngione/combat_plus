local rng = _radiant.math.get_default_rng()
local log = radiant.log.create_logger('combat')

local DefendMelee = radiant.class()

DefendMelee.name = 'defend melee'
DefendMelee.does = 'stonehearth:combat:defend'
DefendMelee.args = {}
DefendMelee.priority = 0

function DefendMelee:__init(entity)
end

function DefendMelee:start_thinking(ai, entity, args)
   self._defense_scheduled = false
   self._ai = ai
   self._entity = entity
   self._entity_string = tostring(entity)

   -- refetch every start_thinking as the set of actions may have changed
   self._defense_types = stonehearth.combat:get_combat_actions(entity, 'stonehearth:combat:melee_defenses')

   -- TODO: refactor all this assault checking and defense scheduling code so that we can reuse it for ranged/spell/etc defense
   local assault_events = stonehearth.combat:get_assault_events(entity)

   for _, assault_context in pairs(assault_events) do
      self:_on_assault(assault_context)
      if self._defense_scheduled then
         return
      end
   end

   self:_add_assault_listener()
end

function DefendMelee:stop_thinking(ai, entity, args)
   self:_destroy_assault_listener()
   self:_destroy_defense_timer()
end

function DefendMelee:destroy()
   self:_destroy_assault_listener()
   self:_destroy_defense_timer()
end

function DefendMelee:_add_assault_listener()
   assert(self._assault_listener == nil)
   log:spam('%s adding assault trace', self._entity_string)
   self._assault_listener = radiant.events.listen(self._entity, 'stonehearth:combat:assault', self, self._on_assault)
end

function DefendMelee:_destroy_assault_listener()
   if self._assault_listener then
      log:spam('%s destroying assault trace', self._entity_string)
      self._assault_listener:destroy()
      self._assault_listener = nil
   end
end

function DefendMelee:_destroy_defense_timer()
   if self._defense_timer then
      log:spam('%s destroying timer', self._entity_string)
      self._defense_timer:destroy()
      self._defense_timer = nil
   end
end

function DefendMelee:_on_assault(assault_context)
   if not self._entity:is_valid() then
      log:error('assault_listener should have been destroyed in stop_thinking')
      return
   end
   if self._defense_scheduled == true then
      return
   end
   if assault_context.attack_method ~= 'melee' then
      return
   end

   local defend_info = stonehearth.combat:choose_defense_action(self._entity, self._defense_types, assault_context.impact_time)
   if defend_info then
      self:_destroy_assault_listener()
      self:_schedule_defense(assault_context, defend_info)
   end
end

function DefendMelee:_schedule_defense(assault_context, defend_info)
   local buffer_time = 200
   local defend_start_time = assault_context.impact_time - defend_info.time_to_impact
   local defend_start_delay = defend_start_time - radiant.gamestate.now()

   assert(self._defense_scheduled == false)
   self._assault_context = assault_context
   self._defend_info = defend_info

   if defend_start_delay <= buffer_time then
      log:spam('%s skipping timer and calling set_think_output', self._entity_string)
      self._ai:set_think_output()
   else
      log:spam('%s creating timer to schedule defense', self._entity_string)
      -- allow other actions to run until we need to start defending
      -- buffer time ensures that we have enough time to get to run before starting the effect
      assert(self._defense_timer == nil)
      self._defense_timer = stonehearth.combat:set_timer("DefendMelee defend", defend_start_delay - buffer_time,
         function()
            self:_on_defense_timer_fired()
         end
      )
   end

   self._defense_scheduled = true
end

function DefendMelee:_on_defense_timer_fired()
   if not self._entity:is_valid() then
      log:error('defense_timer should have been removed in stop_thinking')
      return
   end

   if self._assault_context.assault_active then
      log:spam('%s timer triggered and calling set_think_output', self._entity_string)
      self._ai:set_think_output()
   end
end

function DefendMelee:run(ai, entity, args)
   -- make sure the assault is still incoming
   if not self._assault_context.assault_active then
      log:info('assault on %s was cancelled', entity)
      ai:abort('assault was cancelled')
   end

   -- make sure we still have time to defend
   local defend_start_delay = self:_get_defend_start_delay(self._assault_context, self._defend_info)

   if defend_start_delay < 0 then
      log:warning('%s DefendMelee could not run in time', entity)
      ai:abort('DefendMelee could not run in time')
   end

   stonehearth.combat:start_cooldown(entity, self._defend_info)

   -- roll if defense action was successful
   if not self:_roll_success(entity, self._defend_info) then
      return
   end

   stonehearth.combat:begin_defense(self._assault_context)

   radiant.entities.turn_to_face(entity, self._assault_context.attacker)

   ai:execute('stonehearth:run_effect', {
      effect = self._defend_info.effect,
      delay = defend_start_delay
   })

   self._effect = radiant.effects.run_effect(
      entity, 'combat_plus:effects:hit_sparks:block_effect', defend_start_delay
   )

   stonehearth.combat:end_defense(self._assault_context)
   self._assault_context = nil
end

function DefendMelee:stop(ai, entity, args)
   if self._assault_context then
      stonehearth.combat:end_defense(self._assault_context)
      self._assault_context = nil
   end

   self._ai = nil
   self._entity = nil
end

function DefendMelee:_get_defend_start_delay(assault_context, defend_info)
   local defend_start_time = assault_context.impact_time - defend_info.time_to_impact
   local defend_start_delay = defend_start_time - radiant.gamestate.now()
   return defend_start_delay
end

function DefendMelee:_roll_success(entity, defend_info)
   local chance_of_success = defend_info.chance_of_success or 1.00
   if chance_of_success < 1 and defend_info.defense_attribute then
      chance_of_success = chance_of_success + radiant.entities.get_attribute(entity, defend_info.defense_attribute, 0)
   end

   local result = rng:get_real(0, 1) < chance_of_success
   return result
end

return DefendMelee
