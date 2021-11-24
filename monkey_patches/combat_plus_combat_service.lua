local Point3 = _radiant.csg.Point3
local rng = _radiant.math.get_default_rng()
local CombatService = require 'stonehearth.services.server.combat.combat_service'
local CombatPlusCombatService = class()

local get_player_id = radiant.entities.get_player_id
local COMBAT_DIE = stonehearth.constants.combat.COMBAT_DIE
local DEFAULT_MUSCLE_PROFICIENCY = stonehearth.constants.combat.DEFAULT_MUSCLE_PROFICIENCY
local DEFAULT_TARGET_DIFFICULTY = stonehearth.constants.combat.DEFAULT_TARGET_DIFFICULTY
local DODGE_COOLDOWN_BUFF = stonehearth.constants.combat.DODGE_COOLDOWN_BUFF
local DEFAULT_TARGET_AWARENESS = stonehearth.constants.combat.DEFAULT_TARGET_AWARENESS
local MAX_CRITICAL_DMG_MULTIPLIER = stonehearth.constants.combat.MAX_CRITICAL_DMG_MULTIPLIER
local MIN_CRITICAL_DMG_MULTIPLIER = stonehearth.constants.combat.MIN_CRITICAL_DMG_MULTIPLIER
local RNG_DMG_WIGGLE = stonehearth.constants.combat.RNG_DMG_WIGGLE

local DEFAULT_CRITICAL_CHANCE = stonehearth.constants.attribute_effects.DEFAULT_CRITICAL_CHANCE
local ATTACK_BONUS_FRACTION = stonehearth.constants.attribute_effects.ATTACK_BONUS_FRACTION
local SPEED_DODGE_THRESHOLD = stonehearth.constants.attribute_effects.SPEED_DODGE_THRESHOLD
local AWARENESS_DODGE_MULTIPLIER = stonehearth.constants.attribute_effects.AWARENESS_DODGE_MULTIPLIER
local SPEED_DODGE_MULTIPLIER = stonehearth.constants.attribute_effects.SPEED_DODGE_MULTIPLIER
local ATTRIBUTE_DAMAGE_BASE = stonehearth.constants.attribute_effects.ATTRIBUTE_DAMAGE_BASE
local ATTRIBUTE_DAMAGE_MULTIPLIER = stonehearth.constants.attribute_effects.ATTRIBUTE_DAMAGE_MULTIPLIER

function CombatPlusCombatService:_attack_check(attacker, target, attack_info, weapon_data)
   local attacker_attributes = attacker:get_component('stonehearth:attributes')
   local target_attributes = target:get_component('stonehearth:attributes')
   -- If there are no attacker attributes or no target attributes, something is wrong and they should just miss the attack.
   if not attacker_attributes or not target_attributes then
      return 'miss'
   end

   -- If there's no weapon nor attack data, something is wrong and they should just miss the attack.
   if not weapon_data or not attack_info then
      return 'miss'
   end
   
   -- If the target has no free will (for example, a door) it's always a hit.
   if not target:get_component('mob'):get_has_free_will() then
      return 'hit'
   end
   
   -- Attack: Step #1 - Find out the skill proficiency behind the attack. Ability specific proficiencies will override weapon proficiencies. For example, a sword with a healing spell can use Intellect for the spell and Muscle for the regular attack. If no proficiency is listed, the default is Muscle (majority of the weapons in the game are common melee weapons)
   local attack_proficiency_attribute = attacker_attributes:get_attribute('muscle', DEFAULT_MUSCLE_PROFICIENCY)
   if attack_info.proficiency_attribute then
      attack_proficiency_attribute = attacker_attributes:get_attribute(attack_info.proficiency_attribute)
   elseif weapon_data.proficiency_attribute then
      attack_proficiency_attribute = attacker_attributes:get_attribute(weapon_data.proficiency_attribute)
   end

   -- Attack: Step #2 - Determine if there's any custom modifier for the attack (from weapon or ability); Again, abilities have priority over weapons - For example, a specific "aimed shot" skill could have a higher chance to hit than the regular shots. If no specific modifiers are found, uses default value (1)
   local attack_modifier = attack_info.modifier or weapon_data.modifier or 1

   -- Attack: Step #3 - Determine if the character/entity performing the attack has a multiplier modifier or additive modifier from their own abilities - for example, provided by a buff, a magical effect, tonic, etc; Use default values if nothing is found (1 for the multiplier, 0 for additive)
   local multiplicative_attack_modifier = attacker_attributes:get_attribute('multiplicative_attack_modifier', 1)
   local additive_attack_modifier = attacker_attributes:get_attribute('additive_attack_modifier', 0)

   -- Attack: Step #4 - Finally, we determine the total attack bonus, rounded.
   local attack_bonus = radiant.math.round(((attack_proficiency_attribute * attack_modifier * multiplicative_attack_modifier) * ATTACK_BONUS_FRACTION) + additive_attack_modifier)

   -- ATTACK ROLL CALCULATION (We use a "combat die" for randomization. Combat die default is 20 because WHY NOT? D&D feelings)
   local attack_roll = rng:get_int(1, COMBAT_DIE) + attack_bonus

   -- Target Difficulty: Step #1 - Now it's time to determine the "difficulty" to hit the target. There's a "target difficulty" attribute defined by the target's base value (arbritary, based on their size) + a small influence from the target's dexterity. We want that value.
   local target_difficulty = target_attributes:get_attribute('target_difficulty', DEFAULT_TARGET_DIFFICULTY)

   -- Target Difficulty: Step #2 - Like for the attack, we'll now check if the target has an additive and multiplicative target difficulty values. If not, default is 0 and 1, respectively. We'll straight up multiply and then sum it up - and then round it.
   target_difficulty =  radiant.math.round((target_difficulty * target_attributes:get_attribute('multiplicative_target_difficulty', 1)) + target_attributes:get_attribute('additive_target_difficulty', 0))

   -- ATTACK ROLL x TARGET DIFFICULTY (now we face off the 'attack_roll' against the 'target_difficulty' and we'll see who comes on top! If the attack roll fails to beat the target difficulty, it's a miss and it's over. If the attack roll beats the difficulty, then we'll have a dodge chance for the target and finally a critical hit chance for the attacker!)
   if attack_roll >= target_difficulty then
      
      -- Dodge: Step #1 - The first thing is to check if the target has the debuff that prevents them from dodging OR if they're immobilized or severely hindered (speed <= 20 by default). Both of these cases will prevent a target from dodging.
      if target_attributes:get_attribute('speed') >= SPEED_DODGE_THRESHOLD and not target:add_component('stonehearth:buffs'):has_buff(DODGE_COOLDOWN_BUFF) then
         
         -- Dodge: Step #2 - Check passed, we now collect the necessary values we need to attempt a dodge! These are the 'speed' and the 'awareness' of the target. If the target has no value for awareness, default value will be used. If they have no value for speed, they're not mobile anyway and wouldn't get past the first dodge check, so there are no defaults for that.
         local target_awareness = target_attributes:get_attribute('awareness', DEFAULT_TARGET_AWARENESS)
         local target_speed = target_attributes:get_attribute('speed')

         -- Dodge: Step #3 - Now, just like before for attacks and difficulty, we check for dodge modifiers that the target might have (from buffs, spells, effects, etc...) Defaults are 1 and 0. 
         local multiplicative_dodge_modifier = target_attributes:get_attribute('multiplicative_dodge_modifier', 1)
         local additive_dodge_modifier = target_attributes:get_attribute('additive_dodge_modifier', 0)

         -- Dodge: Step #4 - And finally we define a value for their dodge bonus. The dodge bonus will be used on a roll that will then be matched against the initial attack roll.
         local dodge_bonus = radiant.math.round(((target_awareness * multiplicative_dodge_modifier) * AWARENESS_DODGE_MULTIPLIER + additive_dodge_modifier) * (target_speed * SPEED_DODGE_MULTIPLIER))

         -- DODGE ROLL CALCULATION (Combat die is used once more)
         local dodge_roll = rng:get_int(1, COMBAT_DIE) + dodge_bonus

         -- ATTACK ROLL x DODGE_ROLL (As explained before, we now compare the attack and the dodge rolls. If Dodge is the same or higher, the target dodges. If the attack wins, we move on to the hit calculations)
         if attack_roll < dodge_roll and target and target:is_valid() then
            radiant.entities.add_buff(target, DODGE_COOLDOWN_BUFF)
            return 'dodge'
         end
      end
      
      -- Critical: Step #1 - Determine the critical chance of the attack. That's a flat percentage value determined by the attacker's dexterity. If they have no Critical Chance attribute/value, they'll use the default value. The maximum value is 1 because it represents 100% of chance.
      local critical_chance = math.min(1, attacker_attributes:get_attribute('critical_chance', DEFAULT_CRITICAL_CHANCE))

      -- Critical: Step #2 - Generate a real number between 0 and 1 and compare it to the critical chance attribute, which is also a real number between 0 and 1, representing percentages. If the critical chance is higher than the generated number, than it is a critical hit. Otherwise it is a normal hit.
      if rng:get_real(0,1) <= critical_chance then
         return 'critical'
      else
         return 'hit'
      end
   else
      return 'miss'
   end
end

function CombatPlusCombatService:calculate_ranged_damage(attacker, target, attack_info, is_critical)
   return self:_calculate_damage(attacker, target, attack_info, 'base_ranged_damage', is_critical)
end

function CombatPlusCombatService:calculate_melee_damage(attacker, target, attack_info, is_critical)
   return self:_calculate_damage(attacker, target, attack_info, 'base_damage', is_critical)
end

function CombatPlusCombatService:_calculate_damage(attacker, target, attack_info, base_damage_name, is_critical)
   local weapon = stonehearth.combat:get_main_weapon(attacker)

   if not weapon or not weapon:is_valid() then
      return 0
   end

   local weapon_data = radiant.entities.get_entity_data(weapon, 'stonehearth:combat:weapon_data')
   local base_damage = weapon_data[base_damage_name]

   local total_damage = base_damage
   local attributes_component = attacker:get_component('stonehearth:attributes')
   if not attributes_component then
      return total_damage
   end
   local additive_dmg_modifier = attributes_component:get_attribute('additive_dmg_modifier')
   local multiplicative_dmg_modifier = attributes_component:get_attribute('multiplicative_dmg_modifier')

   -- Combat+ Changes
   -- Step #1 - We want the attribute that affects damage to customizable - the proficiency attribute used in the hit calculation. Default is muscle.
   local damage_bonus_attribute = attributes_component:get_attribute('muscle', DEFAULT_MUSCLE_PROFICIENCY)
   if attack_info.proficiency_attribute then
      damage_bonus_attribute = attributes_component:get_attribute(attack_info.proficiency_attribute)
   elseif weapon_data.proficiency_attribute then
      damage_bonus_attribute = attributes_component:get_attribute(weapon_data.proficiency_attribute)
   end

   -- Step #2 - We now calculate the overall effect of the attribute on the damage.
   if damage_bonus_attribute then
      local attribute_dmg_modifier = ATTRIBUTE_DAMAGE_BASE + (damage_bonus_attribute * ATTRIBUTE_DAMAGE_MULTIPLIER)
      additive_dmg_modifier = additive_dmg_modifier + attribute_dmg_modifier
   end

   -- End of Combat+ changes here!

   if multiplicative_dmg_modifier then
      local dmg_to_add = base_damage * multiplicative_dmg_modifier
      total_damage = dmg_to_add + total_damage
   end
   if additive_dmg_modifier then
      total_damage = total_damage + additive_dmg_modifier
   end

   -- Extra Combat+ changes!
   -- We want to add support for damage multipliers on weapons too!
   if weapon_data.damage_multiplier then
      total_damage = total_damage * weapon_data.damage_multiplier
   end

   -- End of Combat+ changes here!

   if attack_info.damage_multiplier then
      total_damage = total_damage * attack_info.damage_multiplier
   end

   -- More Combat+ changes!
   -- First, let's randomize damage a little!
   total_damage = rng:get_int(total_damage * (1 - RNG_DMG_WIGGLE), total_damage * (1 + RNG_DMG_WIGGLE))

   -- Finally, we need to add the critical damage to the calculation! Critical damage can be brutal, with the default value being a real number between 2 and 3 - but different weapons or attacks can have customized multipliers.
   if is_critical then
      local max_critical_dmg = attack_info.max_critical_dmg or weapon_data.max_critical_dmg or MAX_CRITICAL_DMG_MULTIPLIER
      local min_critical_dmg = attack_info.min_critical_dmg or weapon_data.min_critical_dmg or MIN_CRITICAL_DMG_MULTIPLIER
      local critical_damage_multiplier = rng:get_real(min_critical_dmg, max_critical_dmg)

      total_damage = total_damage * critical_damage_multiplier
   end
   -- Extra Combat+ changes!

   --Get the damage reduction from armor
   local total_armor = self:calculate_total_armor(target)

   -- Reduce armor if attacker has armor reduction attributes
   local multiplicative_target_armor_modifier = attributes_component:get_attribute('multiplicative_target_armor_modifier', 1)
   local additive_target_armor_modifier = attributes_component:get_attribute('additive_target_armor_modifier', 0)

   if attack_info.target_armor_multiplier then
      multiplicative_target_armor_modifier = multiplicative_target_armor_modifier * attack_info.target_armor_multiplier
   end

   total_armor = total_armor * multiplicative_target_armor_modifier + additive_target_armor_modifier

   local damage = total_damage - total_armor
   damage = radiant.math.round(damage)

   if attack_info.minimum_damage and damage <= attack_info.minimum_damage then
      damage = attack_info.minimum_damage
   elseif damage < 1 then
      -- if attack will do less than 1 damage, then (Combat+ change) make it 1 - because it's a hit!
      damage = 1
   end

   return damage
end

-- Support for cooldown images (courtesy of BrunoSupremo)
function CombatPlusCombatService:start_cooldown(entity, action_info)
   local combat_state = self:get_combat_state(entity)
   if not combat_state then
      return
   end
   combat_state:start_cooldown(action_info.name, action_info.cooldown)

	if action_info.image then
      local bubble_type = action_info.bubble_type or stonehearth.constants.thought_bubble.effects.INDICATOR
		self:thought_bubble(entity, action_info.image, bubble_type)
	end

   if action_info.shared_cooldown_name then
      combat_state:start_cooldown(action_info.shared_cooldown_name, action_info.shared_cooldown)
   end
end

function CombatPlusCombatService:thought_bubble(entity, image, bubble_type)
	entity:add_component('stonehearth:thought_bubble')  
	:add_bubble(bubble_type,
		stonehearth.constants.thought_bubble.priorities.HUNGER+1,
		image, nil, '5m')
end

return CombatPlusCombatService