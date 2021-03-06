local AssaultContext = require 'stonehearth.services.server.combat.assault_context'
local BatteryContext = require 'stonehearth.services.server.combat.battery_context'

local Entity = _radiant.om.Entity
local Point3 = _radiant.csg.Point3

local log = radiant.log.create_logger('combat')

-- TODO: Refactor this to share most of the code with AttackRanged.
local SiegeAttackRanged = radiant.class()

SiegeAttackRanged.name = 'siege attack ranged'
SiegeAttackRanged.does = 'stonehearth:combat:attack_ranged'
SiegeAttackRanged.args = {
   target = Entity
}
SiegeAttackRanged.priority = 0
SiegeAttackRanged.weight = 1

-- TODO: prohibit attacking at melee range
function SiegeAttackRanged:start_thinking(ai, entity, args)
   local weapon = stonehearth.combat:get_main_weapon(entity)

   if not weapon or not weapon:is_valid() then
      return
   end

   self._weapon_data = radiant.entities.get_entity_data(weapon, 'stonehearth:combat:weapon_data')

   -- refetch every start_thinking as the set of actions may have changed
   self._attack_types = stonehearth.combat:get_combat_actions(entity, 'stonehearth:combat:ranged_attacks')

   if not next(self._attack_types) then
      -- no ranged attacks
      return
   end

   self:_get_projectile_offsets(self._weapon_data)

   self:_choose_attack_action(ai, entity, args)
end

function SiegeAttackRanged:_choose_attack_action(ai, entity, args)
   -- probably should pass target in as well
   self._attack_info = stonehearth.combat:choose_attack_action(entity, self._attack_types)

   if self._attack_info then
      ai:set_think_output()
      return
   end

   -- choose_attack_action might have complex logic, so just wait 1 second and try again
   -- instead of trying to guess which coolodowns to track
   self._think_timer = stonehearth.combat:set_timer("SiegeAttackRanged waiting for cooldown", 1000, function()
         self._think_timer = nil
         self:_choose_attack_action(ai, entity, args)
      end)
end

function SiegeAttackRanged:stop_thinking(ai, entity, args)
   if self._think_timer then
      self._think_timer:destroy()
      self._think_timer = nil
   end

   self._attack_types = nil
end

function SiegeAttackRanged:run(ai, entity, args)
   local target = args.target
   ai:set_status_text_key('stonehearth:ai.actions.status_text.attack_melee_adjacent', { target = target })

   -- should be get_ranged_weapon
   local weapon = stonehearth.combat:get_main_weapon(entity)
   if not weapon or not weapon:is_valid() then
      log:warning('%s no longer has a valid weapon', entity)
      ai:abort('Attacker no longer has a valid weapon')
   end

   if not stonehearth.combat:in_range_and_has_line_of_sight(entity, args.target, weapon) then
      ai:abort('Target out of ranged weapon range or not in sight')
      return
   end

   -- If this siege weapon has a custom bone transform, turn the bones to face the target instead of the entire entity
   local bone_transform_component = entity:get_component('stonehearth:bone_transform')
   if bone_transform_component then
      bone_transform_component:turn_to_face(target)
   else
      radiant.entities.turn_to_face(entity, target)
   end

   stonehearth.combat:start_cooldown(entity, self._attack_info)

   -- the target might die when we attack them, so unprotect now!
   ai:unprotect_argument(target)

   -- time_to_impact on the attack action is a misnomer for ranged attacks
   -- it's really the time the projectile is launched
   self._shoot_timers = {}
   if self._attack_info.impact_times then
      for _, time in ipairs(self._attack_info.impact_times) do
         self:_add_shoot_timer(entity, target, time)
      end
   else
      self:_add_shoot_timer(entity, target, self._attack_info.time_to_impact)
   end

   ai:execute('stonehearth:run_effect', { effect = self._attack_info.effect })
end

function SiegeAttackRanged:_add_shoot_timer(entity, target, time_to_shoot)
   local shoot_timer = stonehearth.combat:set_timer("SiegeAttackRanged shoot", time_to_shoot, function()
      self:_shoot(entity, target, self._weapon_data)
   end)
   table.insert(self._shoot_timers, shoot_timer)
end

function SiegeAttackRanged:stop(ai, entity, args)
   if self._shoot_timers then
      for _, timer in ipairs(self._shoot_timers) do
         timer:destroy()
      end
      self._shoot_timers = nil
   end

   self._attack_info = nil
end

function SiegeAttackRanged:_shoot(attacker, target, weapon_data)
   if not target:is_valid() then
      return
   end

   local projectile_speed = weapon_data.projectile_speed
   assert(projectile_speed)
   local projectile = self:_create_projectile(attacker, target, projectile_speed, weapon_data.projectile_uri)
   local projectile_component = projectile:add_component('stonehearth:projectile')
   local flight_time = projectile_component:get_estimated_flight_time()
   local impact_time = radiant.gamestate.now() + flight_time

   local assault_context = AssaultContext('melee', attacker, target, impact_time)
   stonehearth.combat:begin_assault(assault_context)

   -- save this because it will live on in the closure after the shot action has completed
   local attack_info = self._attack_info

   local impact_trace
   impact_trace = radiant.events.listen(projectile, 'stonehearth:combat:projectile_impact', function()
         if projectile:is_valid() and target:is_valid() then
            if not assault_context.target_defending then
               radiant.effects.run_effect(target, 'stonehearth:effects:hit_sparks:hit_effect')
               local total_damage = stonehearth.combat:calculate_ranged_damage(attacker, target, attack_info)
               local battery_context = BatteryContext(attacker, target, total_damage)
               stonehearth.combat:inflict_debuffs(attacker, target, attack_info)
               stonehearth.combat:battery(battery_context)
            end
         end

         if assault_context then
            stonehearth.combat:end_assault(assault_context)
            assault_context = nil
         end

         if impact_trace then
            impact_trace:destroy()
            impact_trace = nil
         end
      end)

   local destroy_trace
   destroy_trace = radiant.events.listen(projectile, 'radiant:entity:pre_destroy', function()
         if assault_context then
            stonehearth.combat:end_assault(assault_context)
            assault_context = nil
         end

         if destroy_trace then
            destroy_trace:destroy()
            destroy_trace = nil
         end
      end)
end

function SiegeAttackRanged:_create_projectile(attacker, target, projectile_speed, projectile_uri)
   projectile_uri = projectile_uri or 'stonehearth:weapons:arrow' -- default projectile is an arrow
   local projectile = radiant.entities.create_entity(projectile_uri)
   local projectile_component = projectile:add_component('stonehearth:projectile')
   projectile_component:set_speed(projectile_speed)
   projectile_component:set_target_offset(self._target_offset)
   projectile_component:set_target(target)

   local projectile_origin = self:_get_world_location(self._attacker_offset, attacker)
   radiant.terrain.place_entity_at_exact_location(projectile, projectile_origin)

   projectile_component:start()
   return projectile
end

-- local_to_world not doing the right thing
function SiegeAttackRanged:_get_world_location(point, entity)
   local mob = entity:add_component('mob')
   local facing = mob:get_facing()
   local entity_location = mob:get_world_location()

   local offset = radiant.math.rotate_about_y_axis(point, facing)
   local world_location = entity_location + offset
   return world_location
end

function SiegeAttackRanged:_get_projectile_offsets(weapon_data)
   self._attacker_offset = Point3(0, 0, 0)
   self._target_offset = Point3(0, 0, 0)

   if not weapon_data then
      return
   end

   local projectile_start_offset = weapon_data.projectile_start_offset
   local projectile_end_offset = weapon_data.projectile_end_offset
   -- Get start and end offsets from weapon data if provided
   if projectile_start_offset then
      self._attacker_offset = Point3(projectile_start_offset.x,
                                     projectile_start_offset.y,
                                     projectile_start_offset.z)
   end
   if projectile_end_offset then
      self._target_offset = Point3(projectile_end_offset.x,
                                     projectile_end_offset.y,
                                     projectile_end_offset.z)
   end
end

return SiegeAttackRanged
