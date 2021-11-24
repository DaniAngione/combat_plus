combat_plus = {}

local service_creation_order = {}

local monkey_patches = {
   combat_plus_combat_service = 'stonehearth.services.server.combat.combat_service',
   combat_plus_job_component = 'stonehearth.components.job.job_component',
   combat_plus_projectile_component = 'stonehearth.components.projectile.projectile_component'
}

local function monkey_patching()
   for from, into in pairs(monkey_patches) do
      local monkey_see = require('monkey_patches.' .. from)
      local monkey_do = radiant.mods.require(into)
      radiant.log.write_('combat_plus', 0, 'Combat+ Mod server monkey-patching sources \'' .. from .. '\' => \'' .. into .. '\'')
      radiant.mixin(monkey_do, monkey_see)
   end
end

local function create_service(name)
   local path = string.format('services.server.%s.%s_service', name, name)
   local service = require(path)()
	
   local saved_variables = combat_plus._sv[name]
   if not saved_variables then
      saved_variables = radiant.create_datastore()
      combat_plus._sv[name] = saved_variables
   end

   service.__saved_variables = saved_variables
   service._sv = saved_variables:get_data()
   saved_variables:set_controller(service)
   saved_variables:set_controller_name('combat_plus:' .. name)
   service:initialize()
   combat_plus[name] = service
end

function combat_plus:_on_init()
   combat_plus._sv = combat_plus.__saved_variables:get_data()

   for _, name in ipairs(service_creation_order) do
      create_service(name)
   end

   radiant.events.trigger_async(radiant, 'combat_plus:server:init')
   radiant.log.write_('combat_plus', 0, 'Combat+ Mod server initialized')
end

function combat_plus:_on_required_loaded()
	monkey_patching()
   
   radiant.events.trigger_async(radiant, 'combat_plus:server:required_loaded')
end

radiant.events.listen(combat_plus, 'radiant:init', combat_plus, combat_plus._on_init)
radiant.events.listen(radiant, 'radiant:required_loaded', combat_plus, combat_plus._on_required_loaded)

return combat_plus
