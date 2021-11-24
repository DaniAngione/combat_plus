local DurationBasedOnAttribute = class()

function DurationBasedOnAttribute:on_buff_added(entity, buff)
   if buff._sv._dynamic_timer then
      return
   end

   local json = buff:get_json()
   self._tuning = json.script_info

   if not self._tuning then
      return
   end

   if not self._tuning.value_per_step or not self._tuning.base_duration or not self._tuning.reduction_per_step or not self._tuning.min_duration then
      return
   end

   if not entity:add_component('stonehearth:attributes') and not entity:get_component('stonehearth:attributes'):get_attribute(self._tuning.attribute) then
      return
   end

   local attribute = entity:get_component('stonehearth:attributes'):get_attribute(self._tuning.attribute)
   local steps = math.floor(attribute / self._tuning.value_per_step)
   local base_duration = stonehearth.calendar:parse_duration(self._tuning.base_duration)
   local reduction_per_step = stonehearth.calendar:parse_duration(self._tuning.reduction_per_step)
   local total_reduction = steps * reduction_per_step
   local min_duration = stonehearth.calendar:parse_duration(self._tuning.min_duration)

   local duration = math.max(min_duration, (base_duration - total_reduction))

   local destroy_fn = function()
      self:destroy()
   end

   buff._sv._dynamic_timer = stonehearth.calendar:set_timer('Buff Dynamic Duration', duration, destroy_fn)
end

function DurationBasedOnAttribute:on_buff_removed(entity, buff)
   if buff._sv._dynamic_timer then
      buff._sv._dynamic_timer:destroy()
      buff._sv._dynamic_timer = nil
   end
end

return DurationBasedOnAttribute
