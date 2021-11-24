local CombatPlusJobComponent = class()

-- compatible with ACE
function CombatPlusJobComponent:level_up(skip_visual_effects)
   --Change all the attributes to the new level
   --Should the general HP increase (class independent) be reflected as a permanent buff or a quiet stat increase?
   local attributes_component = self._entity:get_component('stonehearth:attributes')
   local curr_level = attributes_component:get_attribute('total_level')
   self._sv.total_level = curr_level + 1
   attributes_component:set_attribute('total_level', self._sv.total_level)

   --Add to the total job levels statistics
   local stats_comp = self._entity:get_component('stonehearth_ace:statistics')
   if stats_comp then
      stats_comp:set_stat('totals', 'levels', self._sv.total_level)
   end

   --Add all the universal level dependent buffs/bonuses, etc

   self:_call_job('level_up')
   local job_name = self._job_json.display_name

   local new_level = self:_call_job('get_job_level') or 1
   self._sv.curr_job_level = new_level
   local class_perk_descriptions = self:_apply_perk_for_level(new_level)
   local has_class_perks = false
   if #class_perk_descriptions > 0 then
      has_class_perks = true
   end

   self:_set_custom_description(self:_get_current_job_title(self._job_json))

   local player_id = radiant.entities.get_player_id(self._entity)
   local name = radiant.entities.get_display_name(self._entity)
   local title = self._default_level_announcement

   local has_race_perks = false
   local race_perk_descriptions = self:_add_race_perks()
   if race_perk_descriptions and #race_perk_descriptions > 0 then
      has_race_perks = true
   end

   -- Combat+ addition
   local max_health_adjustment = attributes_component:get_attribute('max_health_adjustment')
   -- end

   if not skip_visual_effects then
      --post the bulletin
      local level_bulletin = stonehearth.bulletin_board:post_bulletin(player_id)
         :set_ui_view('StonehearthLevelUpBulletinDialog')
         :set_callback_instance(self)
         :set_type('level_up')
         :set_data({
            title = title,
            char_name = name,
            zoom_to_entity = self._entity,
            has_class_perks = has_class_perks,
            class_perks = class_perk_descriptions,
            has_race_perks = has_race_perks,
            race_perks = race_perk_descriptions
         })
         :set_active_duration('1h')
         :add_i18n_data('entity_display_name', radiant.entities.get_display_name(self._entity))
         :add_i18n_data('entity_custom_name', radiant.entities.get_custom_name(self._entity))
         :add_i18n_data('entity_custom_data', radiant.entities.get_custom_data(self._entity))
         :add_i18n_data('job_name', job_name)
         :add_i18n_data('level_number', new_level)
         :add_i18n_data('max_health_adjustment', max_health_adjustment)
   end

   --Trigger an event so people can extend the class system
   radiant.events.trigger_async(self._entity, 'stonehearth:level_up', {
      level = new_level,
      job_uri = self._sv.job_uri,
      job_name = self._sv.curr_job_name })

   --Inform job controllers
   if self:get_job_info() then
      self:get_job_info():promote_member(self._entity)
   end

   if not self:is_trainable() then
      self:_remove_training_toggle()
   end

   if not skip_visual_effects then
      radiant.effects.run_effect(self._entity, 'stonehearth:effects:level_up')
   end

   if new_level > 0 then
      radiant.entities.add_thought(self._entity, 'stonehearth:thoughts:job:gained_a_level')
   end

   self._sv.xp_to_next_lv = self:_calculate_xp_to_next_lv()
   self.__saved_variables:mark_changed()
end

function CombatPlusJobComponent:promote_to(job_uri, options)
	assert(self._sv.allowed_jobs == nil or self._sv.allowed_jobs[job_uri])

   local is_npc = stonehearth.player:is_npc(self._entity)
   local talisman_entity = options and options.talisman

   local old_job_json = self._job_json

   self._sv.job_json_path = self:get_job_description_path(job_uri)
   self._job_json = radiant.resources.load_json(self._sv.job_json_path, true)

   if self._job_json then
      self:_on_job_json_changed()
      self:demote(old_job_json, options and options.dont_drop_talisman)

      self._sv.job_uri = job_uri

      --Strangely, doesn't exist yet when this is called in init, creates duplicate component!
      local attributes_component = self._entity:get_component('stonehearth:attributes')
      self._sv.total_level = attributes_component:get_attribute('total_level')

      -- equip your abilities item
      self:_equip_abilities(self._job_json)

      -- equip your equipment, unless you're an npc, in which case the game is responsible for manually
      -- adding the proper equipment
      if not is_npc then
         self:_equip_equipment(self._job_json, talisman_entity)
      end

      self:reset_to_default_combat_stance()

      local first_time_job = false
      --Create the job controller, if we don't yet have one
      if not self._sv.job_controllers[self._sv.job_uri] then
         --create the controller
         radiant.assert(self._job_json.controller, 'no controller specified for job %s', self._sv.job_uri)
         self._sv.job_controllers[self._sv.job_uri] =
            radiant.create_controller(self._job_json.controller, self._entity)
         first_time_job = true
      end
      self._sv.curr_job_controller = self._sv.job_controllers[self._sv.job_uri]
      self:_call_job('promote', self._sv.job_json_path, {talisman = talisman_entity})

      self._sv.curr_job_level = self:_call_job('get_job_level') or 1
      self:_set_custom_description(self:_get_current_job_title(self._job_json))

      --Whenever you get a new job, dump all the xp that you've accured so far to your next level
      self._sv.xp_to_next_lv = self:_calculate_xp_to_next_lv()
      self._sv.current_level_exp = math.min(self._sv.xp_to_next_lv and (self._sv.xp_to_next_lv - 1) or 0, self:_call_job('get_current_level_exp') or 0)

      --Add all existing perks, if any
      local class_perk_descriptions = self:_apply_existing_perks()

      --The old work order configuration is no longer relevant.
      self._entity:add_component('stonehearth:work_order'):clear_work_order_statuses()
      self:_update_job_work_order()

      --Add self to task groups
      if self._job_json.task_groups then
         self:_add_to_task_groups(self._job_json.task_groups)
      end

      --Add self to job_info_controllers
      if self:get_job_info() then
         self:get_job_info():add_member(self._entity)
      end

      --Log in journal, if possible
      local activity_name = self._job_json.promotion_activity_name
      if activity_name then
         radiant.events.trigger_async(stonehearth.personality, 'stonehearth:journal_event',
                             {entity = self._entity, description = activity_name})
      end

      --Post bulletin
      local attributes_component = self._entity:get_component('stonehearth:attributes')

      --Add all the universal level dependent buffs/bonuses, etc
      local job_name = self._job_json.display_name
      local has_class_perks = false
      if #class_perk_descriptions > 0 then
         has_class_perks = true
      end

      local player_id = radiant.entities.get_player_id(self._entity)
      local name = radiant.entities.get_display_name(self._entity)
      local title = self._default_promote_announcement

      -- Combat+ addition
      local max_health_adjustment = attributes_component:get_attribute('max_health_adjustment')
      -- end

      if (not options or not options.skip_visual_effects) and has_class_perks and first_time_job then
         --post the bulletin
         local level_bulletin = stonehearth.bulletin_board:post_bulletin(player_id)
            :set_ui_view('StonehearthPromoteBulletinDialog')
            :set_callback_instance(self)
            :set_data({
               title = title,
               char_name = name,
               zoom_to_entity = self._entity,
               has_class_perks = has_class_perks,
               class_perks = class_perk_descriptions
            })
            :set_active_duration('1h')
            :add_i18n_data('entity_display_name', radiant.entities.get_display_name(self._entity))
            :add_i18n_data('entity_custom_name', radiant.entities.get_custom_name(self._entity))
            :add_i18n_data('entity_custom_data', radiant.entities.get_custom_data(self._entity))
            :add_i18n_data('job_name', job_name)
            :add_i18n_data('level_number', self._sv.curr_job_level)
            :add_i18n_data('max_health_adjustment', max_health_adjustment)
      end

      -- so good!  keep this one, lose the top one.  too much "collusion" between components =)
      radiant.events.trigger(self._entity, 'stonehearth:job_changed', { entity = self._entity })
      self.__saved_variables:mark_changed()
   end

	-- add the training toggle command if not max level
	if self:is_trainable() then
		self:_add_training_toggle()
   end
   
   if self:has_multiple_equipment_preferences() then
      self:_add_equipment_preferences_toggle()
   end

   self:_register_entity_types()

   self._sv.current_talisman_uri = talisman_entity and talisman_entity:get_uri()

	--radiant.events.trigger(self._entity, 'stonehearth_ace:on_promote', { job_uri = job_uri, options = options })
end

return CombatPlusJobComponent