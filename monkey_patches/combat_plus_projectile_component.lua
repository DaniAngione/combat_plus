local CombatPlusProjectileComponent = class()

function CombatPlusProjectileComponent:set_target_offset(offset)
   -- assert(offset.x == 0 and offset.z == 0, 'not implemented')
   self._target_offset = offset
end

return CombatPlusProjectileComponent
