return function()
   local repatches = {
      combat_plus_job_component = 'stonehearth.components.job.job_component',
      --combat_plus_projectile_component = 'stonehearth.components.projectile.projectile_component',
   }
   for from, into in pairs(repatches) do
      local monkey_see = require('monkey_patches.' .. from)
      local monkey_do = radiant.mods.require(into)
      radiant.log.write_('stonehearth_ace', 0, 'ACE server monkey-patching sources \'' .. from .. '\' => \'' .. into .. '\' for Combat+ Mod')
      radiant.mixin(monkey_do, monkey_see)
   end
end