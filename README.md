
# Black Mesa NPC Spawner Plugin

A comprehensive enemy spawning system for Black Mesa cooperative gameplay that dynamically spawns NPCs around players with advanced portal effects, health-based difficulty adjustment, and intelligent spawn management.

## Features

- **Dynamic NPC Spawning**: Automatically spawns enemies at configurable intervals around players
- **Health-Based Difficulty**: Spawn rates automatically adjust based on team health (spawns less when players are injured)
- **Portal Effects**: NPCs can spawn with dramatic Xen portal effects and sounds
- **Intelligent Spawn Placement**: Advanced validation ensures NPCs spawn in appropriate locations
- **Multiple Spawn Types**: Portal spawns (dramatic/visible) vs Stealth spawns (hidden)
- **NPC Variety**: Supports 15 different Black Mesa enemy types with individual configurations
- **Performance Optimized**: Multi-frame validation and batch processing for smooth gameplay

## Supported NPCs

**Xen Creatures:**
- Alien Slave, Snark, Headcrab, Houndeye, Bullsquid, Alien Grunt, Alien Controller

**Undead:**
- Zombie HEV, Zombie Scientist, Zombie Scientist Torso, Zombie Security, Zombie Grunt

**Human Enemies:**
- Human Grenadier, Human Assassin, Human Grunt

## Core Configuration Variables

### Basic Spawning
| CVar | Default | Description |
|------|---------|-------------|
| `bm_spawner_enabled` | `1` | Enable/disable NPC spawning |
| `bm_spawn_interval` | `30.0` | Seconds between NPC spawns |
| `bm_max_npc_count` | `5` | Maximum number of active NPCs |
| `bm_spawn_max_distance` | `800.0` | Maximum spawn distance from players |
| `bm_spawn_min_distance` | `250.0` | Minimum spawn distance from players |
| `bm_npc_despawn_distance` | `1200.0` | Distance before NPCs are removed |

### Spawn Behavior
| CVar | Default | Description |
|------|---------|-------------|
| `bm_spawn_out_of_sight` | `0` | Force NPCs to spawn hidden from players |
| `bm_spawn_visibility_mode` | `0` | Visibility method: 0=Line of Sight, 1=Field of View |
| `bm_spawn_fov_angle` | `90.0` | FOV angle threshold for spawning |
| `bm_spawn_distance_preference` | `1.0` | Distance preference: 0.0=random, 1.0=prefer closest |
| `bm_spawn_candidates` | `8` | Number of spawn locations evaluated per attempt |
| `bm_max_group_spacing` | `120.0` | Maximum spacing between group members |
| `bm_npc_face_player` | `1` | NPCs face nearest player when spawned |

### Environmental
| CVar | Default | Description |
|------|---------|-------------|
| `bm_water_buffer_distance` | `70.0` | Minimum distance from water for spawning |

## Portal Effects System

### Portal Configuration
| CVar | Default | Description |
|------|---------|-------------|
| `bm_spawn_portal_effect` | `1` | Enable portal effects and sounds |
| `bm_spawn_portal_volume` | `0.8` | Portal sound volume (0.0-1.0) |
| `bm_portal_spawn_in_sight` | `1` | Force portal NPCs to spawn visibly |
| `bm_use_portal_chance` | `1` | Use per-NPC portal probability system |

### Pool-Based Spawn Types
| CVar | Default | Description |
|------|---------|-------------|
| `bm_spawn_use_pools` | `1` | Enable pool-based spawn type control |
| `bm_spawn_portal_weight` | `60.0` | Weight for portal-type spawns |
| `bm_spawn_stealth_weight` | `40.0` | Weight for stealth-type spawns |

## Health-Based Difficulty System

The plugin automatically adjusts spawn intervals based on team health to provide dynamic difficulty scaling.

### Health Adjustment
| CVar | Default | Description |
|------|---------|-------------|
| `bm_health_adjustment_enabled` | `1` | Enable health-based spawn adjustment |
| `bm_health_step1_threshold` | `0.50` | Health ratio for first adjustment step |
| `bm_health_step2_threshold` | `0.25` | Health ratio for second adjustment step |
| `bm_health_step3_threshold` | `0.10` | Health ratio for third adjustment step |
| `bm_health_step1_multiplier` | `1.25` | Spawn interval multiplier for step 1 |
| `bm_health_step2_multiplier` | `1.5` | Spawn interval multiplier for step 2 |
| `bm_health_step3_multiplier` | `1.75` | Spawn interval multiplier for step 3 |

**Example:** If team health drops below 25%, spawn intervals increase by 1.5x (spawns become less frequent).

## Individual NPC Control

Each NPC type can be individually enabled/disabled:

| CVar | Default | NPC Type |
|------|---------|----------|
| `bm_npc_enable_alien_slave` | `1` | Alien Slave |
| `bm_npc_enable_snark` | `1` | Snark |
| `bm_npc_enable_headcrab` | `1` | Headcrab |
| `bm_npc_enable_houndeye` | `1` | Houndeye |
| `bm_npc_enable_bullsquid` | `1` | Bullsquid |
| `bm_npc_enable_alien_grunt` | `0` | Alien Grunt |
| `bm_npc_enable_alien_controller` | `0` | Alien Controller |
| `bm_npc_enable_zombie_hev` | `1` | Zombie HEV |
| `bm_npc_enable_zombie_scientist` | `0` | Zombie Scientist |
| `bm_npc_enable_zombie_scientist_torso` | `0` | Zombie Scientist Torso |
| `bm_npc_enable_zombie_security` | `0` | Zombie Security |
| `bm_npc_enable_zombie_grunt` | `0` | Zombie Grunt |
| `bm_npc_enable_human_grenadier` | `0` | Human Grenadier |
| `bm_npc_enable_human_assassin` | `0` | Human Assassin |
| `bm_npc_enable_human_grunt` | `0` | Human Grunt |

## Admin Commands

| Command | Permission | Description |
|---------|------------|-------------|
| `sm_spawner_status` | Generic | Show current spawner status and statistics |
| `sm_npc_toggle <classname> [0/1]` | Config | Enable/disable specific NPC types |
| `sm_spawn_pools [enable/disable] [portal_weight] [stealth_weight]` | Config | Configure spawn type distribution |
| `sm_health_adjustment [enable/disable/thresholds/multipliers]` | Config | Configure health-based difficulty |
| `sm_portal_toggle [0/1]` | Config | Toggle portal effects |
| `sm_portal_volume <0.0-1.0>` | Config | Set portal sound volume |
| `sm_portal_sight [0/1]` | Config | Toggle portal in-sight spawning |
| `sm_portal_chance [0/1]` | Config | Toggle per-NPC portal probability |
| `sm_npc_info` | Generic | Display NPC spawn information and probabilities |

## Installation

1. Place the compiled plugin in your `sourcemod/plugins/` directory
2. Restart the server or use `sm plugins load` to load the plugin
3. Configure CVars in your `server.cfg` or through the admin commands
4. Ensure portal sound files are present in the game directory

## Portal Sound Files Required

- `BMS_objects/portal/portal_In_01.wav`
- `BMS_objects/portal/portal_In_02.wav`
- `BMS_objects/portal/portal_In_03.wav`

## Performance Notes

- The plugin uses advanced optimization techniques including staged validation and batch processing
- Recommended maximum NPC count is 5-10 depending on server performance
- Health-based adjustment is event-driven and very lightweight
- Portal effects are GPU-accelerated particle systems

## Version Information

**Plugin Name:** BM NPC Spawner  
**Version:** 3.2.0  
**Authors:** OpenAI ChatGPT + Claude AI

---

*This plugin enhances Black Mesa cooperative gameplay by providing dynamic, intelligent enemy spawning with spectacular portal effects and adaptive difficulty based on player performance.*
