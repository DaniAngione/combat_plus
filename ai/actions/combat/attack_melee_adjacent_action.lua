local AssaultContext = require 'stonehearth.services.server.combat.assault_context'
local BatteryContext = require 'stonehearth.services.server.combat.battery_context'
local Entity = _radiant.om.Entity
local log = radiant.log.create_logger('combat')

local AttackMeleeAdjacent = radiant.class()

AttackMeleeAdjacent.name = 'attack melee adjacent'
AttackMeleeAdjacent.does = 'stonehearth:combat:attack_melee_adjacent'
AttackMeleeAdjacent.args = {
   target = Entity,
   face_target = {   -- whether to face target when attacking
      type = 'boolean',
      default = true,
   }
}
AttackMeleeAdjacent.priority = 0

function AttackMeleeAdjacent:start_thinking(ai, entity, args)
   local weapon = stonehearth.combat:get_main_weapon(entity)

   if not weapon or not weapon:is_valid() then
      log:warning('%s has nothing to attack with', entity)
      return
   end

   -- refetch every start_thinking as the set of actions may have changed
   self._attack_types = stonehearth.combat:get_combat_actions(entity, 'stonehearth:combat:melee_attacks')

   if not next(self._attack_types) then
      log:warning('%s has no melee attacks', entity)
      return
   end

   self:_choose_attack_action(ai, entity, args)
end

function AttackMeleeAdjacent:_choose_attack_action(ai, entity, args)
   -- probably should pass target in as well
   self._attack_info = stonehearth.combat:choose_attack_action(entity, self._attack_types)

   if self._attack_info then
      ai:set_think_output()
      return true
   end

   -- choose_attack_action might have complex logic, so just wait 1 second and try again
   -- instead of trying to guess which coolodowns to track
   self._think_timer = stonehearth.combat:set_timer("AttackMeleeAdjacent waiting for cooldown", 1000, function()
         self._think_timer = nil
         self:_choose_attack_action(ai, entity, args)
      end)
end

function AttackMeleeAdjacent:stop_thinking(ai, entity, args)
   if self._think_timer then
      self._think_timer:destroy()
      self._think_timer = nil
   end

   self._attack_types = nil
end

-- TODO: don't allow melee if vertical distance > 1
function AttackMeleeAdjacent:run(ai, entity, args)
   local target = args.target
   ai:set_status_text_key('stonehearth:ai.actions.status_text.attack_melee_adjacent', { target = target })

   local weapon = stonehearth.combat:get_main_weapon(entity)
   if not weapon or not weapon:is_valid() then
      log:warning('%s no longer has a valid weapon', entity)
      ai:abort('Attacker no longer has a valid weapon')
   end

   local weapon_data = radiant.entities.get_entity_data(weapon, 'stonehearth:combat:weapon_data')
   assert(weapon_data)

   local melee_range_ideal, melee_range_max = stonehearth.combat:get_melee_range(entity, weapon_data, target)
   local distance = radiant.entities.distance_between(entity, target)
   if distance > melee_range_max then
      log:warning('%s unable to get within maximum melee range (%f) of %s', entity, melee_range_max, target)
      ai:abort('Target out of melee range')
      return
   end

   if args.face_target then
      radiant.entities.turn_to_face(entity, target)
   end

   ai:execute('stonehearth:bump_against_entity', { entity = target, distance = melee_range_ideal })

   stonehearth.combat:start_cooldown(entity, self._attack_info)

   -- the target might die when we attack them, so unprotect now!
   ai:unprotect_argument(target)

   local impact_time = radiant.gamestate.now() + self._attack_info.time_to_impact
   self._assault_context = AssaultContext('melee', entity, target, impact_time)
   stonehearth.combat:begin_assault(self._assault_context)

   -- can't ai:execute this. it needs to run in parallel with the attack animation
   local attack_check = stonehearth.combat:_attack_check(entity, target, self._attack_info, weapon_data)

   if attack_check == 'hit' or attack_check == 'critical' then

      local is_critical = nil
      if attack_check == 'critical' then
         is_critical = true
         self._hit_effect = radiant.effects.run_effect(
            target, 'combat_plus:effects:hit_sparks:critical_effect', self._attack_info.time_to_impact
         )
      else
         self._hit_effect = radiant.effects.run_effect(
            target, 'stonehearth:effects:hit_sparks:hit_effect', self._attack_info.time_to_impact
         )
      end

      self._impact_timer = stonehearth.combat:set_timer("AttackMeleeAdjacent do damage", self._attack_info.time_to_impact,
         function ()
            if not entity:is_valid() or not target:is_valid() then
               return
            end

            -- local range = radiant.entities.distance_between(entity, target)
            -- local out_of_range = range > melee_range_max

            -- All attacks now hit even if the target runs out of range
            local out_of_range = false

            if out_of_range or self._assault_context.target_defending then
               self._hit_effect:stop()
               self._hit_effect = nil
            else
               -- TODO: Implement system to collect all damage types and all armor types
               -- and then resolve to compute the final damage type.
               -- TODO: figure out HP progression of enemies, so this system will scale well
               -- For example, if you melee Cthulu what elements should be in play so a high lv footman
               -- will be able to actually make a difference?
               -- For now, will have an additive dmg attribute, a multiplicative dmg attribute
               -- and will apply both to this base damage number
               -- TODO: Albert to implement more robust solution after he works on mining
               local total_damage = stonehearth.combat:calculate_melee_damage(entity, target, self._attack_info, is_critical)
               local target_id = target:get_id()
               local aggro_override = stonehearth.combat:calculate_aggro_override(total_damage, self._attack_info)
               local battery_context = BatteryContext(entity, target, total_damage, aggro_override)

               stonehearth.combat:inflict_debuffs(entity, target, self._attack_info)
               stonehearth.combat:battery(battery_context)

               if self._attack_info.aoe_effect then
                  self:_apply_aoe_damage(entity, target_id, melee_range_max, is_critical)
               end
            end
         end
      )
   elseif attack_check == 'dodge' then
      self._hit_effect = radiant.effects.run_effect(
         target, 'combat_plus:effects:hit_sparks:dodge_effect', self._attack_info.time_to_impact
      )
   else
      self._hit_effect = radiant.effects.run_effect(
         target, 'combat_plus:effects:hit_sparks:miss_effect', self._attack_info.time_to_impact
      )
   end

   ai:execute('stonehearth:run_effect', { effect = self._attack_info.effect })

   stonehearth.combat:end_assault(self._assault_context)
   self._assault_context = nil
end

-- Move this function to combat service
function AttackMeleeAdjacent:_apply_aoe_damage(attacker, original_target_id, melee_range_max, is_critical)
   local aggro_table = attacker:add_component('stonehearth:target_tables')
                                       :get_target_table('aggro')

   if not aggro_table then
      return
   end

   local aoe_target_limit = self._attack_info.aoe_target_limit or 10

   local aoe_range = self._attack_info.aoe_range or melee_range_max
   local num_targets = 0
   local aoe_attack_info = self._attack_info.aoe_effect
   for id, entry in pairs(aggro_table:get_entries()) do
      if id ~= original_target_id then
         -- only apply aoe to targets that aren't the original target
         local target = entry.entity
         if target and target:is_valid() then -- targets can be invalid in the aggro table.
            local distance = radiant.entities.distance_between(attacker, target)
            if distance <= aoe_range then
               local total_damage = stonehearth.combat:calculate_melee_damage(attacker, target, aoe_attack_info, is_critical)
               local aggro_override = stonehearth.combat:calculate_aggro_override(total_damage, aoe_attack_info)
               local battery_context = BatteryContext(attacker, target, total_damage, aggro_override)
               stonehearth.combat:inflict_debuffs(attacker, target, aoe_attack_info)
               stonehearth.combat:battery(battery_context)
               num_targets = num_targets + 1
            end
            if num_targets >= aoe_target_limit then
               break
            end
         end
      end
   end
end

function AttackMeleeAdjacent:stop(ai, entity, args)
   if self._hit_effect then
      if self._assault_context and radiant.gamestate.now() < self._assault_context.impact_time then
         self._hit_effect:stop()
      end
      self._hit_effect = nil
   end

   if self._impact_timer then
      -- cancel the timer if we were pre-empted
      self._impact_timer:destroy()
      self._impact_timer = nil
   end

   if self._assault_context then
      stonehearth.combat:end_assault(self._assault_context)
      self._assault_context = nil
   end

   self._attack_info = nil
end

return AttackMeleeAdjacent
