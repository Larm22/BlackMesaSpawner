#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_NAME "BM NPC Spawner"
#define PLUGIN_VERSION "3.2.0"
#define MAX_SPAWN_ATTEMPTS 10
#define MAX_TRACKING_ATTEMPTS 5

// Constants for magic numbers
#define NPC_HEIGHT_OFFSET 10.0
#define GROUND_TRACE_DISTANCE 1000.0
#define NPC_TRACKING_RANGE 64.0
#define NPC_EYE_LEVEL_OFFSET 32.0
#define TRACKING_DELAY 0.3
#define TRACKING_RETRY_DELAY 0.5
#define MAKER_CLEANUP_DELAY 0.5
#define DELAYED_START_TIME 10.0
#define NPC_HULL_WIDTH 35.0
#define NPC_HULL_HEIGHT 72.0
#define CLEARANCE_CHECK_HEIGHT 100.0
#define MIN_GROUND_CLEARANCE 16.0
#define LARGE_NPC_HULL_WIDTH 64.0
#define LARGE_NPC_HULL_HEIGHT 96.0
#define SAFETY_CLEARANCE_MULTIPLIER 1.12
#define RADIAL_CLEARANCE_CHECKS 3
#define MIN_DISTANCE_RATIO 0.3
#define GROUP_SPAWN_RADIUS 150.0
#define MIN_GROUP_SPACING 70.0
#define NPC_DESPAWN_DISTANCE 2000.0
#define NPC_CLEANUP_INTERVAL 5.0
#define PLAYER_CACHE_UPDATE_INTERVAL 2.0
#define MAX_DESPAWN_CHECKS_PER_FRAME 1
#define MAX_CLEARANCE_CHECKS_PER_FRAME 1
#define DEATH_STATE_CHECK_INTERVAL 3.0
#define FAST_DISTANCE_CHECK_THRESHOLD 2000.0
#define MAX_SURFACE_ANGLE_DEGREES 25.0  // Maximum slope angle for NPC spawning
#define MIN_SURFACE_NORMAL_Z 0.906  
#define SURFACE_CHECK_RADIUS 48.0           // Radius to check around spawn point
#define SURFACE_CHECK_POINTS 8              // Number of points to check in circle
#define MAX_SURFACE_ANGLE_VARIANCE 15.0     // Maximum allowed angle difference between points
#define MIN_VALID_SURFACE_POINTS 6          // Minimum points that must be valid for acce

// Expanded spawn area constants
#define EXPANDED_SPAWN_HEIGHT_OFFSET 80.0

// New constants for enhanced spawn system
#define VALIDATION_FRAMES 3
#define VALIDATION_FRAME_DELAY 0.1
#define MAX_HULL_CHECK_POINTS 8

#define TERRAIN_CONNECTIVITY_OFFSET 50.0
#define GEOMETRY_CHECK_SAFETY_MARGIN 2.0

// CRITICAL STABILITY FIX CONSTANTS
#define SPAWN_LOCK_TIMEOUT 30.0  // Maximum time spawn lock can be held
#define VALIDATION_QUEUE_MAX_SIZE 10  // Maximum pending validations
#define VALIDATION_QUEUE_CLEANUP_INTERVAL 15.0  // Clean stale validations
#define ENTITY_REFERENCE_CHECK_INTERVAL 2.0  // Check entity validity

// ================================================================================
// HANDLE CLEANUP HELPER FUNCTIONS
// ================================================================================

// Helper function to safely close trace handles with null checking
void SafeCloseTrace(Handle &trace)
{
    if (trace != INVALID_HANDLE)
    {
        CloseHandle(trace);
        trace = INVALID_HANDLE;
    }
}

// Helper function to safely close and nullify any handle
void SafeCloseHandle(Handle &handle)
{
    if (handle != INVALID_HANDLE)
    {
        CloseHandle(handle);
        handle = INVALID_HANDLE;
    }
}

// Helper function to safely kill timers
void SafeKillTimer(Handle &timer)
{
    if (timer != INVALID_HANDLE)
    {
        KillTimer(timer);
        timer = INVALID_HANDLE;
    }
}

// CRITICAL STABILITY FIX: Enhanced entity validation
bool IsValidGameEntity(int ent)
{
    if (ent <= 0 || ent > GetMaxEntities())
        return false;
    
    if (!IsValidEdict(ent))
        return false;
    
    // Additional validity check - ensure entity is not being destroyed
    return IsValidEntity(ent);
}

// CRITICAL STABILITY FIX: Safe entity reference validation
bool IsValidEntityReference(int entRef)
{
    if (entRef == INVALID_ENT_REFERENCE)
        return false;
    
    int entity = EntRefToEntIndex(entRef);
    return IsValidGameEntity(entity);
}

Handle g_SpawnTimer = INVALID_HANDLE;
Handle g_CleanupTimer = INVALID_HANDLE;
Handle g_PlayerCacheTimer = INVALID_HANDLE;
Handle g_DeathStateTimer = INVALID_HANDLE;
Handle g_ValidationTimer = INVALID_HANDLE; // FIXED: Global handle instead of static
// CRITICAL STABILITY FIX: New timers for stability
Handle g_SpawnLockTimer = INVALID_HANDLE;
Handle g_ValidationCleanupTimer = INVALID_HANDLE;
Handle g_EntityValidationTimer = INVALID_HANDLE;

bool g_bSpawnerEnabled = true;
float g_GracePeriodStartTime = 0.0;

// Global spawn lock to prevent multiple groups spawning per interval
bool g_bSpawnLocked = false;
// CRITICAL STABILITY FIX: Track when spawn lock was set
float g_SpawnLockTime = 0.0;

// RACE CONDITION FIX: Array operation lock to prevent timer conflicts
bool g_bArrayOperationLock = false;

// Simple death state tracking
bool g_bAllPlayersDead = false;

// Player position cache for performance
float g_PlayerPositions[MAXPLAYERS + 1][3];
bool g_PlayerValid[MAXPLAYERS + 1];
bool g_PlayerAlive[MAXPLAYERS + 1];
int g_ValidPlayerCount = 0;
int g_ValidPlayers[MAXPLAYERS + 1];

// Batch processing for despawn checks
int g_DespawnCheckIndex = 0;

// Health-based spawn interval adjustment globals
float g_CurrentHealthMultiplier = 1.0;
int g_MaxTeamHealth = 0; // Cached max possible health
float g_OriginalSpawnInterval = 30.0; // Store admin's original setting
bool g_bHealthSystemAdjusting = false; // Flag to prevent feedback loops
float g_LastHealthCheck = 0.0; // Debouncing for event-driven health checks

// Multi-frame validation system
enum struct PendingSpawn
{
    float position[3];
    int npcIndex;
    int groupSize;
    int validationFrame;
    int validationCount;
    int playerClient;
    float creationTime;  // CRITICAL STABILITY FIX: Track creation time
}

ArrayList g_PendingSpawns;
int g_CurrentValidationFrame = 0;

// NPC tracking data for despawning
enum struct NPCTrackingData
{
    int entityRef;
    float lastPlayerDistance;
    float lastValidationTime;  // CRITICAL STABILITY FIX: Track last validation
}

ArrayList g_NPCTrackingList;
ArrayList g_SpawnedNPCs;
ArrayList g_TrackingDataPacks;

const int NPC_COUNT = 15;

// NPC Configuration Structure
enum struct NPCConfig
{
    char classname[32];
    float weight;
    int minGroupSize;
    int maxGroupSize;
    float groupSpacing;
    char groupType[32];
    float hullWidth;
    float hullHeight;
    bool enabled;
    bool forceOutOfSight;    // Always spawn hidden, regardless of global visibility setting
    bool allowPortalSpawn;   // Can use portal effects (subject to global portal toggle)
    float portalChance;      // OPTION 5: Probability (0.0-1.0) of spawning as portal vs stealth
}

NPCConfig g_NPCConfigs[NPC_COUNT];

void InitializeNPCConfigs()
{
    // Alien Slave - can form small groups, Xen origin = high portal chance
    strcopy(g_NPCConfigs[0].classname, sizeof(g_NPCConfigs[].classname), "npc_alien_slave");
    g_NPCConfigs[0].weight = 13.0;
    g_NPCConfigs[0].minGroupSize = 1;
    g_NPCConfigs[0].maxGroupSize = 3;
    g_NPCConfigs[0].groupSpacing = 60.0;
    strcopy(g_NPCConfigs[0].groupType, sizeof(g_NPCConfigs[].groupType), "alien_basic");
    g_NPCConfigs[0].hullWidth = 40.0;
    g_NPCConfigs[0].hullHeight = 80.0;
    g_NPCConfigs[0].enabled = true;
    g_NPCConfigs[0].forceOutOfSight = false;
    g_NPCConfigs[0].allowPortalSpawn = true;
    g_NPCConfigs[0].portalChance = 0.8;  

    // Snark - pack hunters, Xen origin = high portal chance
    strcopy(g_NPCConfigs[1].classname, sizeof(g_NPCConfigs[].classname), "npc_snark");
    g_NPCConfigs[1].weight = 5.0;
    g_NPCConfigs[1].minGroupSize = 2;
    g_NPCConfigs[1].maxGroupSize = 3;
    g_NPCConfigs[1].groupSpacing = 40.0;
    strcopy(g_NPCConfigs[1].groupType, sizeof(g_NPCConfigs[].groupType), "snark_pack");
    g_NPCConfigs[1].hullWidth = 24.0;
    g_NPCConfigs[1].hullHeight = 32.0;
    g_NPCConfigs[1].enabled = true;
    g_NPCConfigs[1].forceOutOfSight = false;
    g_NPCConfigs[1].allowPortalSpawn = true;
    g_NPCConfigs[1].portalChance = 0.9;  

    // Headcrab - can swarm, Xen origin = mixed behavior for variety
    strcopy(g_NPCConfigs[2].classname, sizeof(g_NPCConfigs[].classname), "npc_headcrab");
    g_NPCConfigs[2].weight = 20.0;
    g_NPCConfigs[2].minGroupSize = 1;
    g_NPCConfigs[2].maxGroupSize = 3;
    g_NPCConfigs[2].groupSpacing = 50.0;
    strcopy(g_NPCConfigs[2].groupType, sizeof(g_NPCConfigs[].groupType), "headcrab_swarm");
    g_NPCConfigs[2].hullWidth = 28.0;
    g_NPCConfigs[2].hullHeight = 36.0;
    g_NPCConfigs[2].enabled = true;
    g_NPCConfigs[2].forceOutOfSight = false;
    g_NPCConfigs[2].allowPortalSpawn = true;
    g_NPCConfigs[2].portalChance = 0.6;  

    // Houndeye - pack animals, Xen origin = high portal chance
    strcopy(g_NPCConfigs[3].classname, sizeof(g_NPCConfigs[].classname), "npc_houndeye");
    g_NPCConfigs[3].weight = 18.0;
    g_NPCConfigs[3].minGroupSize = 1;
    g_NPCConfigs[3].maxGroupSize = 3;
    g_NPCConfigs[3].groupSpacing = 70.0;
    strcopy(g_NPCConfigs[3].groupType, sizeof(g_NPCConfigs[].groupType), "houndeye_pack");
    g_NPCConfigs[3].hullWidth = 48.0;
    g_NPCConfigs[3].hullHeight = 64.0;
    g_NPCConfigs[3].enabled = true;
    g_NPCConfigs[3].forceOutOfSight = false;
    g_NPCConfigs[3].allowPortalSpawn = true;
    g_NPCConfigs[3].portalChance = 0.8; 

    // Bullsquid - solitary, Xen origin = mixed for unpredictability
    strcopy(g_NPCConfigs[4].classname, sizeof(g_NPCConfigs[].classname), "npc_bullsquid");
    g_NPCConfigs[4].weight = 17.0;
    g_NPCConfigs[4].minGroupSize = 1;
    g_NPCConfigs[4].maxGroupSize = 1;
    g_NPCConfigs[4].groupSpacing = 0.0;
    strcopy(g_NPCConfigs[4].groupType, sizeof(g_NPCConfigs[].groupType), "solo");
    g_NPCConfigs[4].hullWidth = 72.0;
    g_NPCConfigs[4].hullHeight = 84.0;
    g_NPCConfigs[4].enabled = true;
    g_NPCConfigs[4].forceOutOfSight = false;
    g_NPCConfigs[4].allowPortalSpawn = true;
    g_NPCConfigs[4].portalChance = 0.5;  

    // Alien Grunt - military units, Xen origin = high portal chance
    strcopy(g_NPCConfigs[5].classname, sizeof(g_NPCConfigs[].classname), "npc_alien_grunt");
    g_NPCConfigs[5].weight = 10.0;
    g_NPCConfigs[5].minGroupSize = 1;
    g_NPCConfigs[5].maxGroupSize = 2;
    g_NPCConfigs[5].groupSpacing = 100.0;
    strcopy(g_NPCConfigs[5].groupType, sizeof(g_NPCConfigs[].groupType), "alien_military");
    g_NPCConfigs[5].hullWidth = 72.0;
    g_NPCConfigs[5].hullHeight = 108.0;
    g_NPCConfigs[5].enabled = true;
    g_NPCConfigs[5].forceOutOfSight = false;
    g_NPCConfigs[5].allowPortalSpawn = true;
    g_NPCConfigs[5].portalChance = 0.65;

    // Alien Controller - solitary, Xen origin = very high portal chance
    strcopy(g_NPCConfigs[6].classname, sizeof(g_NPCConfigs[].classname), "npc_alien_controller");
    g_NPCConfigs[6].weight = 6.0;
    g_NPCConfigs[6].minGroupSize = 1;
    g_NPCConfigs[6].maxGroupSize = 1;
    g_NPCConfigs[6].groupSpacing = 0.0;
    strcopy(g_NPCConfigs[6].groupType, sizeof(g_NPCConfigs[].groupType), "solo");
    g_NPCConfigs[6].hullWidth = 48.0;
    g_NPCConfigs[6].hullHeight = 80.0;
    g_NPCConfigs[6].enabled = true;
    g_NPCConfigs[6].forceOutOfSight = false;
    g_NPCConfigs[6].allowPortalSpawn = true;
    g_NPCConfigs[6].portalChance = 0.7;  

    // Zombie HEV - reanimated human, low portal chance (mostly stealth)
    strcopy(g_NPCConfigs[7].classname, sizeof(g_NPCConfigs[].classname), "npc_zombie_hev");
    g_NPCConfigs[7].weight = 8.0;
    g_NPCConfigs[7].minGroupSize = 1;
    g_NPCConfigs[7].maxGroupSize = 1;
    g_NPCConfigs[7].groupSpacing = 0.0;
    strcopy(g_NPCConfigs[7].groupType, sizeof(g_NPCConfigs[].groupType), "zombie");
    g_NPCConfigs[7].hullWidth = 44.0;
    g_NPCConfigs[7].hullHeight = 84.0;
    g_NPCConfigs[7].enabled = true;
    g_NPCConfigs[7].forceOutOfSight = true;
    g_NPCConfigs[7].allowPortalSpawn = false;
    g_NPCConfigs[7].portalChance = 0.2;  

    // Zombie Scientist - reanimated human, low portal chance (mostly stealth)
    strcopy(g_NPCConfigs[8].classname, sizeof(g_NPCConfigs[].classname), "npc_zombie_scientist");
    g_NPCConfigs[8].weight = 21.0;
    g_NPCConfigs[8].minGroupSize = 1;
    g_NPCConfigs[8].maxGroupSize = 2;
    g_NPCConfigs[8].groupSpacing = 55.0;
    strcopy(g_NPCConfigs[8].groupType, sizeof(g_NPCConfigs[].groupType), "zombie_horde");
    g_NPCConfigs[8].hullWidth = 42.0;
    g_NPCConfigs[8].hullHeight = 82.0;
    g_NPCConfigs[8].enabled = true;
    g_NPCConfigs[8].forceOutOfSight = true;
    g_NPCConfigs[8].allowPortalSpawn = false;
    g_NPCConfigs[8].portalChance = 0.0;

    // Zombie Scientist Torso - reanimated human, very low portal chance
    strcopy(g_NPCConfigs[9].classname, sizeof(g_NPCConfigs[].classname), "npc_zombie_scientist_torso");
    g_NPCConfigs[9].weight = 8.0;
    g_NPCConfigs[9].minGroupSize = 1;
    g_NPCConfigs[9].maxGroupSize = 1;
    g_NPCConfigs[9].groupSpacing = 0.0;
    strcopy(g_NPCConfigs[9].groupType, sizeof(g_NPCConfigs[].groupType), "zombie_swarm");
    g_NPCConfigs[9].hullWidth = 36.0;
    g_NPCConfigs[9].hullHeight = 48.0;
    g_NPCConfigs[9].enabled = true;
    g_NPCConfigs[9].forceOutOfSight = true;
    g_NPCConfigs[9].allowPortalSpawn = false;
    g_NPCConfigs[9].portalChance = 0.0;  

    // Zombie Security - reanimated human, low portal chance
    strcopy(g_NPCConfigs[10].classname, sizeof(g_NPCConfigs[].classname), "npc_zombie_security");
    g_NPCConfigs[10].weight = 15.0;
    g_NPCConfigs[10].minGroupSize = 1;
    g_NPCConfigs[10].maxGroupSize = 2;
    g_NPCConfigs[10].groupSpacing = 65.0;
    strcopy(g_NPCConfigs[10].groupType, sizeof(g_NPCConfigs[].groupType), "zombie_horde");
    g_NPCConfigs[10].hullWidth = 46.0;
    g_NPCConfigs[10].hullHeight = 86.0;
    g_NPCConfigs[10].enabled = true;
    g_NPCConfigs[10].forceOutOfSight = true;
    g_NPCConfigs[10].allowPortalSpawn = false;
    g_NPCConfigs[10].portalChance = 0.0;  

    // Zombie Grunt - reanimated military, low portal chance
    strcopy(g_NPCConfigs[11].classname, sizeof(g_NPCConfigs[].classname), "npc_zombie_grunt");
    g_NPCConfigs[11].weight = 18.0;
    g_NPCConfigs[11].minGroupSize = 1;
    g_NPCConfigs[11].maxGroupSize = 3;
    g_NPCConfigs[11].groupSpacing = 70.0;
    strcopy(g_NPCConfigs[11].groupType, sizeof(g_NPCConfigs[].groupType), "zombie_military");
    g_NPCConfigs[11].hullWidth = 48.0;
    g_NPCConfigs[11].hullHeight = 88.0;
    g_NPCConfigs[11].enabled = true;
    g_NPCConfigs[11].forceOutOfSight = true;
    g_NPCConfigs[11].allowPortalSpawn = false;
    g_NPCConfigs[11].portalChance = 0.0;

    // Human Grenadier - tactical military, mixed portal chance
    strcopy(g_NPCConfigs[12].classname, sizeof(g_NPCConfigs[].classname), "npc_human_grenadier");
    g_NPCConfigs[12].weight = 15.0;
    g_NPCConfigs[12].minGroupSize = 1;
    g_NPCConfigs[12].maxGroupSize = 1;
    g_NPCConfigs[12].groupSpacing = 0.0;
    strcopy(g_NPCConfigs[12].groupType, sizeof(g_NPCConfigs[].groupType), "human_military");
    g_NPCConfigs[12].hullWidth = 44.0;
    g_NPCConfigs[12].hullHeight = 84.0;
    g_NPCConfigs[12].enabled = true;
    g_NPCConfigs[12].forceOutOfSight = true;
    g_NPCConfigs[12].allowPortalSpawn = false;
    g_NPCConfigs[12].portalChance = 0.0;  

    // Human Assassin - elite stealth unit, very low portal chance
    strcopy(g_NPCConfigs[13].classname, sizeof(g_NPCConfigs[].classname), "npc_human_assassin");
    g_NPCConfigs[13].weight = 8.0;
    g_NPCConfigs[13].minGroupSize = 1;
    g_NPCConfigs[13].maxGroupSize = 1;
    g_NPCConfigs[13].groupSpacing = 0.0;
    strcopy(g_NPCConfigs[13].groupType, sizeof(g_NPCConfigs[].groupType), "human_elite");
    g_NPCConfigs[13].hullWidth = 40.0;
    g_NPCConfigs[13].hullHeight = 82.0;
    g_NPCConfigs[13].enabled = true;
    g_NPCConfigs[13].forceOutOfSight = true;
    g_NPCConfigs[13].allowPortalSpawn = false;
    g_NPCConfigs[13].portalChance = 0.0; 

    // Human Grunt - standard military, balanced portal chance
    strcopy(g_NPCConfigs[14].classname, sizeof(g_NPCConfigs[].classname), "npc_human_grunt");
    g_NPCConfigs[14].weight = 20.0;
    g_NPCConfigs[14].minGroupSize = 2;
    g_NPCConfigs[14].maxGroupSize = 4;
    g_NPCConfigs[14].groupSpacing = 75.0;
    strcopy(g_NPCConfigs[14].groupType, sizeof(g_NPCConfigs[].groupType), "human_military");
    g_NPCConfigs[14].hullWidth = 42.0;
    g_NPCConfigs[14].hullHeight = 84.0;
    g_NPCConfigs[14].enabled = true;
    g_NPCConfigs[14].forceOutOfSight = true;
    g_NPCConfigs[14].allowPortalSpawn = false;
    g_NPCConfigs[14].portalChance = 0.0;  
}

// ================================================================================
// RACE CONDITION FIX: Array Operation Protection
// ================================================================================

// Protected array operations to prevent timer race conditions
bool BeginArrayOperation()
{
    if (g_bArrayOperationLock)
    {
        PrintToServer("[BM] Array operation already in progress - deferring");
        return false;
    }
    g_bArrayOperationLock = true;
    return true;
}

void EndArrayOperation()
{
    g_bArrayOperationLock = false;
}

// Protected wrapper for adding spawned NPCs
bool SafeAddSpawnedNPC(int entityRef)
{
    if (g_SpawnedNPCs == null) return false;
    
    // Check if already exists to prevent duplicates
    if (g_SpawnedNPCs.FindValue(entityRef) != -1)
        return false;
    
    g_SpawnedNPCs.Push(entityRef);
    return true;
}

// Protected wrapper for removing spawned NPCs
bool SafeRemoveSpawnedNPC(int entityRef)
{
    if (g_SpawnedNPCs == null) return false;
    
    int index = g_SpawnedNPCs.FindValue(entityRef);
    if (index == -1) return false;
    
    g_SpawnedNPCs.Erase(index);
    return true;
}

ConVar gCvar_SpawnInterval;
ConVar gCvar_MaxSpawnDistance;
ConVar gCvar_MinSpawnDistance;
ConVar gCvar_SpawnerEnabled;
ConVar gCvar_VisibilityCheck;
ConVar gCvar_MaxNPCCount;
ConVar gCvar_MaxGroupSpacing;
ConVar gCvar_NPCDespawnDistance;
ConVar gCvar_VisibilityMode;
ConVar gCvar_FOVAngle;
ConVar gCvar_WaterBufferDistance;
ConVar gCvar_SpawnDistancePreference;
ConVar gCvar_SpawnCandidates;
ConVar gCvar_NPCFacePlayer;

// Portal effect ConVars (from teleport plugin)
ConVar gCvar_PortalEffect;
ConVar gCvar_PortalSoundVolume;
ConVar gCvar_PortalSpawnInSight;  // OPTION 1: Portal visibility toggle
ConVar gCvar_UsePortalChance;     // OPTION 5: Enable per-NPC portal probability

// Pool-based spawn system ConVars (OPTION A: Controls spawn type distribution)
// When enabled, pool system determines whether the next spawn should be "portal type" or "stealth type"
// then filters NPCs based on capability (portalChance > 0.0 for portal, < 1.0 for stealth)
// This ensures ~50/50 portal/stealth distribution while allowing NPCs to appear in either role
ConVar gCvar_PortalNPCWeight;
ConVar gCvar_StealthNPCWeight;
ConVar gCvar_UsePoolSpawning;

// Health-based spawn interval adjustment ConVars
ConVar gCvar_HealthAdjustmentEnabled;
ConVar gCvar_HealthStep1Threshold;   // e.g., 80% of max team health
ConVar gCvar_HealthStep2Threshold;   // e.g., 60% of max team health  
ConVar gCvar_HealthStep3Threshold;   // e.g., 40% of max team health
ConVar gCvar_HealthStep1Multiplier;  // e.g., 1.2x interval
ConVar gCvar_HealthStep2Multiplier;  // e.g., 1.5x interval
ConVar gCvar_HealthStep3Multiplier;  // e.g., 2.0x interval

// NPC enable ConVars
ConVar gCvar_EnableAlienSlave;
ConVar gCvar_EnableSnark;
ConVar gCvar_EnableHeadcrab;
ConVar gCvar_EnableHoundeye;
ConVar gCvar_EnableBullsquid;
ConVar gCvar_EnableAlienGrunt;
ConVar gCvar_EnableAlienController;
ConVar gCvar_EnableZombieHEV;
ConVar gCvar_EnableZombieScientist;
ConVar gCvar_EnableZombieScientistTorso;
ConVar gCvar_EnableZombieSecurity;
ConVar gCvar_EnableZombieGrunt;
ConVar gCvar_EnableHumanGrenadier;
ConVar gCvar_EnableHumanAssassin;
ConVar gCvar_EnableHumanGrunt;

public Plugin myinfo = {
    name = PLUGIN_NAME,
    author = "OpenAI ChatGPT + Claude AI",
    description = "Spawns extra enemies for coop with health-based interval adjustment",
    version = PLUGIN_VERSION
};

public void OnPluginStart()
{
    InitializeNPCConfigs();
    
    gCvar_SpawnInterval = CreateConVar("bm_spawn_interval", "30.0", "Seconds between NPC spawns", FCVAR_NOTIFY, true, 5.0, true, 300.0);
    gCvar_MaxSpawnDistance = CreateConVar("bm_spawn_max_distance", "800.0", "Maximum spawn distance from player", FCVAR_NOTIFY, true, 100.0, true, 2000.0);
    gCvar_MinSpawnDistance = CreateConVar("bm_spawn_min_distance", "250.0", "Minimum spawn distance from player", FCVAR_NOTIFY, true, 50.0, true, 1000.0);
    gCvar_SpawnerEnabled = CreateConVar("bm_spawner_enabled", "1", "Enable/disable NPC spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_VisibilityCheck = CreateConVar("bm_spawn_out_of_sight", "0", "Spawn NPCs out of sight of players", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_MaxNPCCount = CreateConVar("bm_max_npc_count", "5", "Maximum number of active NPCs spawned by this plugin", FCVAR_NOTIFY, true, 1.0, true, 50.0);
    gCvar_MaxGroupSpacing = CreateConVar("bm_max_group_spacing", "120.0", "Maximum spacing between group members", FCVAR_NOTIFY, true, 30.0, true, 300.0);
    gCvar_NPCDespawnDistance = CreateConVar("bm_npc_despawn_distance", "1200.0", "Distance from players before NPCs are considered for despawning", FCVAR_NOTIFY, true, 500.0, true, 5000.0);
    gCvar_VisibilityMode = CreateConVar("bm_spawn_visibility_mode", "0", "Visibility check method: 0=Line of Sight, 1=Field of View", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_FOVAngle = CreateConVar("bm_spawn_fov_angle", "90.0", "FOV angle threshold for spawning (degrees)", FCVAR_NOTIFY, true, 45.0, true, 180.0);
    gCvar_WaterBufferDistance = CreateConVar("bm_water_buffer_distance", "70.0", "Minimum distance from water for NPC spawning", FCVAR_NOTIFY, true, 0.0, true, 500.0);
    gCvar_SpawnDistancePreference = CreateConVar("bm_spawn_distance_preference", "1.0", "Distance preference: 0.0=random, 1.0=prefer closest", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_SpawnCandidates = CreateConVar("bm_spawn_candidates", "8", "Number of spawn candidates to evaluate", FCVAR_NOTIFY, true, 1.0, true, 10.0);
    gCvar_NPCFacePlayer = CreateConVar("bm_npc_face_player", "1", "NPCs face nearest player when spawned", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    
    // Portal effect ConVars
    gCvar_PortalEffect = CreateConVar("bm_spawn_portal_effect", "1", "Enable/disable portal effects on NPC spawn", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_PortalSoundVolume = CreateConVar("bm_spawn_portal_volume", "0.8", "Volume level for portal spawn sound effects (0.0-1.0)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_PortalSpawnInSight = CreateConVar("bm_portal_spawn_in_sight", "1", "Force portal NPCs to spawn in line of sight of players", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_UsePortalChance = CreateConVar("bm_use_portal_chance", "1", "Use per-NPC portal probability instead of pool-based spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    
    // Pool-based spawn system ConVars (Controls spawn type intent)
    gCvar_UsePoolSpawning = CreateConVar("bm_spawn_use_pools", "1", "Enable pool-based spawn type control (portal vs stealth intent)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_PortalNPCWeight = CreateConVar("bm_spawn_portal_weight", "60.0", "Weight for portal-type spawn attempts", FCVAR_NOTIFY, true, 0.0, true, 1000.0);
    gCvar_StealthNPCWeight = CreateConVar("bm_spawn_stealth_weight", "40.0", "Weight for stealth-type spawn attempts", FCVAR_NOTIFY, true, 0.0, true, 1000.0);
    
    // Health-based spawn interval adjustment ConVars
    gCvar_HealthAdjustmentEnabled = CreateConVar("bm_health_adjustment_enabled", "1", "Enable health-based spawn interval adjustment", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_HealthStep1Threshold = CreateConVar("bm_health_step1_threshold", "0.50", "Team health ratio threshold for step 1 interval increase", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_HealthStep2Threshold = CreateConVar("bm_health_step2_threshold", "0.25", "Team health ratio threshold for step 2 interval increase", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_HealthStep3Threshold = CreateConVar("bm_health_step3_threshold", "0.10", "Team health ratio threshold for step 3 interval increase", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_HealthStep1Multiplier = CreateConVar("bm_health_step1_multiplier", "1.25", "Spawn interval multiplier when team health below step 1 threshold", FCVAR_NOTIFY, true, 1.0, true, 5.0);
    gCvar_HealthStep2Multiplier = CreateConVar("bm_health_step2_multiplier", "1.5", "Spawn interval multiplier when team health below step 2 threshold", FCVAR_NOTIFY, true, 1.0, true, 5.0);
    gCvar_HealthStep3Multiplier = CreateConVar("bm_health_step3_multiplier", "1.75", "Spawn interval multiplier when team health below step 3 threshold", FCVAR_NOTIFY, true, 1.0, true, 5.0);
    
    // NPC enable ConVars
    gCvar_EnableAlienSlave = CreateConVar("bm_npc_enable_alien_slave", "1", "Enable/disable Alien Slave spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableSnark = CreateConVar("bm_npc_enable_snark", "1", "Enable/disable Snark spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableHeadcrab = CreateConVar("bm_npc_enable_headcrab", "1", "Enable/disable Headcrab spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableHoundeye = CreateConVar("bm_npc_enable_houndeye", "1", "Enable/disable Houndeye spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableBullsquid = CreateConVar("bm_npc_enable_bullsquid", "1", "Enable/disable Bullsquid spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableAlienGrunt = CreateConVar("bm_npc_enable_alien_grunt", "0", "Enable/disable Alien Grunt spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableAlienController = CreateConVar("bm_npc_enable_alien_controller", "0", "Enable/disable Alien Controller spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableZombieHEV = CreateConVar("bm_npc_enable_zombie_hev", "1", "Enable/disable Zombie HEV spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableZombieScientist = CreateConVar("bm_npc_enable_zombie_scientist", "0", "Enable/disable Zombie Scientist spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableZombieScientistTorso = CreateConVar("bm_npc_enable_zombie_scientist_torso", "0", "Enable/disable Zombie Scientist Torso spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableZombieSecurity = CreateConVar("bm_npc_enable_zombie_security", "0", "Enable/disable Zombie Security spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableZombieGrunt = CreateConVar("bm_npc_enable_zombie_grunt", "0", "Enable/disable Zombie Grunt spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableHumanGrenadier = CreateConVar("bm_npc_enable_human_grenadier", "0", "Enable/disable Human Grenadier spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableHumanAssassin = CreateConVar("bm_npc_enable_human_assassin", "0", "Enable/disable Human Assassin spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvar_EnableHumanGrunt = CreateConVar("bm_npc_enable_human_grunt", "0", "Enable/disable Human Grunt spawning", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // Hook ConVar changes
    gCvar_SpawnerEnabled.AddChangeHook(OnSpawnerEnabledChanged);
    gCvar_MaxSpawnDistance.AddChangeHook(OnDistanceConVarChanged);
    gCvar_MinSpawnDistance.AddChangeHook(OnDistanceConVarChanged);
    gCvar_SpawnInterval.AddChangeHook(OnSpawnIntervalChanged);
    gCvar_HealthAdjustmentEnabled.AddChangeHook(OnHealthAdjustmentEnabledChanged);
    gCvar_EnableAlienSlave.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableSnark.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableHeadcrab.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableHoundeye.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableBullsquid.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableAlienGrunt.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableAlienController.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableZombieHEV.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableZombieScientist.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableZombieScientistTorso.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableZombieSecurity.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableZombieGrunt.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableHumanGrenadier.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableHumanAssassin.AddChangeHook(OnNPCEnabledChanged);
    gCvar_EnableHumanGrunt.AddChangeHook(OnNPCEnabledChanged);
    
    RegAdminCmd("sm_spawner_status", Command_SpawnerStatus, ADMFLAG_GENERIC, "Show spawner status");
    RegAdminCmd("sm_npc_toggle", Command_ToggleNPC, ADMFLAG_CONFIG, "Enable/disable specific NPC spawning");
    RegAdminCmd("sm_spawn_pools", Command_SpawnPools, ADMFLAG_CONFIG, "Configure pool-based spawning weights");
    RegAdminCmd("sm_health_adjustment", Command_HealthAdjustment, ADMFLAG_CONFIG, "Configure health-based spawn interval adjustment");
    
    // Register portal effect commands
    RegisterPortalCommands();

    // Hook player events for event-driven health monitoring
    HookEvent("player_spawn", OnPlayerHealthEvent);
    HookEvent("player_death", OnPlayerHealthEvent);
    HookEvent("player_hurt", OnPlayerHealthEvent);
    HookEvent("player_connect", OnPlayerHealthEvent);
    HookEvent("player_disconnect", OnPlayerHealthEvent);

    g_SpawnedNPCs = new ArrayList();
    g_TrackingDataPacks = new ArrayList();
    g_NPCTrackingList = new ArrayList(sizeof(NPCTrackingData));
    g_PendingSpawns = new ArrayList(sizeof(PendingSpawn));
    
    StartSpawnerTimer();
    StartNPCCleanupTimer();
    StartPlayerCacheTimer();
    StartDeathStateMonitoring();
    
    // CRITICAL STABILITY FIX: Start new stability timers
    StartStabilityTimers();

    PrintToServer("[BM] Enemy Spawner with Portal Effects, Portal Chance System, Pool Spawn Type Control, Portal In-Sight Spawning, Global Spawn Lock, Event-Driven Health-Based Interval Adjustment, and Critical Stability Fixes loaded. Version %s", PLUGIN_VERSION);
    PrintToServer("[BM] Event-driven health monitoring will activate once players join");
}

// ================================================================================
// EVENT-DRIVEN HEALTH-BASED SPAWN INTERVAL ADJUSTMENT FUNCTIONS
// ================================================================================

// Event-driven health monitoring - triggers when player health actually changes
public void OnPlayerHealthEvent(Event event, const char[] name, bool dontBroadcast)
{
    // Debouncing: Only check health once every 3 seconds regardless of events
    float currentTime = GetGameTime();
    if (currentTime - g_LastHealthCheck < 3.0)
        return;
    
    g_LastHealthCheck = currentTime;
    
    // Use existing health calculation and adjustment logic
    CheckAndAdjustHealthBasedInterval();
}

// Core health checking and interval adjustment logic
void CheckAndAdjustHealthBasedInterval()
{
    if (!gCvar_HealthAdjustmentEnabled.BoolValue)
        return;
    
    // Calculate current team health and multiplier
    int teamHealth = CalculateTeamHealthPool();
    float healthMultiplier = GetHealthBasedMultiplier(teamHealth, g_MaxTeamHealth);
    g_CurrentHealthMultiplier = healthMultiplier;
    
    // Calculate adjusted interval based on original admin setting
    float adjustedInterval = g_OriginalSpawnInterval * healthMultiplier;
    float currentInterval = gCvar_SpawnInterval.FloatValue;
    
    // Only update if there's a meaningful difference (prevents constant updates)
    if (FloatAbs(adjustedInterval - currentInterval) > 0.5)
    {
        // SET FLAG to prevent feedback loop
        g_bHealthSystemAdjusting = true;
        
        gCvar_SpawnInterval.SetFloat(adjustedInterval);
        
        // CLEAR FLAG after change
        g_bHealthSystemAdjusting = false;
        
        if (healthMultiplier > 1.05)
        {
            PrintToServer("[BM] Health event triggered: Spawn interval adjusted to %.1fs (%.1fx multiplier, team health: %d/%d)", 
                         adjustedInterval, healthMultiplier, teamHealth, g_MaxTeamHealth);
        }
        else if (healthMultiplier <= 1.05 && currentInterval > g_OriginalSpawnInterval + 0.5)
        {
            PrintToServer("[BM] Health improved: Spawn interval restored to %.1fs (team health: %d/%d)", 
                         adjustedInterval, teamHealth, g_MaxTeamHealth);
        }
    }
}

// Called when health adjustment is enabled/disabled
void OnHealthAdjustmentToggled(bool enabled)
{
    if (enabled)
    {
        // Store current interval as original
        g_OriginalSpawnInterval = gCvar_SpawnInterval.FloatValue;
        PrintToServer("[BM] Health adjustment enabled - base interval: %.1fs", g_OriginalSpawnInterval);
        
        // Trigger immediate health check to apply current health state
        CheckAndAdjustHealthBasedInterval();
    }
    else
    {
        // Restore original interval and reset multiplier
        g_bHealthSystemAdjusting = true; // Prevent feedback loop
        gCvar_SpawnInterval.SetFloat(g_OriginalSpawnInterval);
        g_bHealthSystemAdjusting = false;
        
        g_CurrentHealthMultiplier = 1.0;
        PrintToServer("[BM] Health adjustment disabled - interval restored to %.1fs", g_OriginalSpawnInterval);
    }
}

// Called when admin manually changes spawn interval
void OnSpawnIntervalManuallyChanged()
{
    // If health adjustment is disabled, update our stored original value
    if (!gCvar_HealthAdjustmentEnabled.BoolValue)
    {
        g_OriginalSpawnInterval = gCvar_SpawnInterval.FloatValue;
        PrintToServer("[BM] Spawn interval manually changed to %.1fs", g_OriginalSpawnInterval);
    }
    // If enabled, store as new base but let health system continue to adjust from it
    else
    {
        g_OriginalSpawnInterval = gCvar_SpawnInterval.FloatValue;
        PrintToServer("[BM] New base spawn interval: %.1fs (health system will adjust from this)", g_OriginalSpawnInterval);
    }
}

// Calculate total team health pool
int CalculateTeamHealthPool()
{
    int totalHealth = 0;
    int playerCount = 0;
    
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && IsPlayerAlive(client))
        {
            totalHealth += GetClientHealth(client);
            playerCount++;
        }
    }
    
    // If no players are connected/alive, treat as full health scenario
    if (playerCount == 0)
    {
        g_MaxTeamHealth = 100; // Dummy value representing "perfect health"
        return 100; // Return full health
    }
    
    g_MaxTeamHealth = playerCount * 100; // Assuming 100 max HP per player
    return totalHealth;
}

// Get health-based spawn interval multiplier using stepped system
float GetHealthBasedMultiplier(int currentHealth, int maxHealth)
{
    if (!gCvar_HealthAdjustmentEnabled.BoolValue)
        return 1.0;
    
    // Explicitly handle no players scenario as perfect health
    if (maxHealth == 0 || currentHealth == 0)
    {
        return 1.0; // Treat as full health (normal spawn intervals)
    }
    
    float healthRatio = float(currentHealth) / float(maxHealth);
    
    if (healthRatio <= gCvar_HealthStep3Threshold.FloatValue)
        return gCvar_HealthStep3Multiplier.FloatValue;
    else if (healthRatio <= gCvar_HealthStep2Threshold.FloatValue)
        return gCvar_HealthStep2Multiplier.FloatValue;
    else if (healthRatio <= gCvar_HealthStep1Threshold.FloatValue)
        return gCvar_HealthStep1Multiplier.FloatValue;
    
    return 1.0; // Normal interval
}

// Health adjustment admin command
public Action Command_HealthAdjustment(int client, int args)
{
    if (args == 0)
    {
        // Show current status
        bool enabled = gCvar_HealthAdjustmentEnabled.BoolValue;
        ReplyToCommand(client, "[BM] Health-Based Spawn Interval Adjustment: %s", enabled ? "ENABLED" : "DISABLED");
        
        if (enabled)
        {
            int teamHealth = CalculateTeamHealthPool();
            
            ReplyToCommand(client, "[BM] Current Team Health: %d/%d (%.1f%%)", 
                teamHealth, g_MaxTeamHealth, g_MaxTeamHealth > 0 ? (float(teamHealth) / float(g_MaxTeamHealth)) * 100.0 : 0.0);
            ReplyToCommand(client, "[BM] Current Spawn Interval Multiplier: %.1fx", g_CurrentHealthMultiplier);
            ReplyToCommand(client, "[BM] Base Spawn Interval: %.1fs", g_OriginalSpawnInterval);
            ReplyToCommand(client, "[BM] Current Spawn Interval: %.1fs", gCvar_SpawnInterval.FloatValue);
            ReplyToCommand(client, "[BM] Health Thresholds:");
            ReplyToCommand(client, "  Step 1: %.0f%% = %.1fx multiplier", 
                gCvar_HealthStep1Threshold.FloatValue * 100.0, gCvar_HealthStep1Multiplier.FloatValue);
            ReplyToCommand(client, "  Step 2: %.0f%% = %.1fx multiplier", 
                gCvar_HealthStep2Threshold.FloatValue * 100.0, gCvar_HealthStep2Multiplier.FloatValue);
            ReplyToCommand(client, "  Step 3: %.0f%% = %.1fx multiplier", 
                gCvar_HealthStep3Threshold.FloatValue * 100.0, gCvar_HealthStep3Multiplier.FloatValue);
        }
        
        ReplyToCommand(client, "[BM] Usage:");
        ReplyToCommand(client, "  sm_health_adjustment enable/disable - Toggle feature");
        ReplyToCommand(client, "  sm_health_adjustment thresholds <step1> <step2> <step3> - Set health thresholds (0.0-1.0)");
        ReplyToCommand(client, "  sm_health_adjustment multipliers <mult1> <mult2> <mult3> - Set interval multipliers");
        
        return Plugin_Handled;
    }
    
    char arg1[32];
    GetCmdArg(1, arg1, sizeof(arg1));
    
    if (StrEqual(arg1, "enable", false) || StrEqual(arg1, "on", false))
    {
        gCvar_HealthAdjustmentEnabled.SetBool(true);
        ReplyToCommand(client, "[BM] Health-based spawn interval adjustment ENABLED");
        ReplyToCommand(client, "[BM] Spawn intervals will automatically adjust when players take damage or heal");
    }
    else if (StrEqual(arg1, "disable", false) || StrEqual(arg1, "off", false))
    {
        gCvar_HealthAdjustmentEnabled.SetBool(false);
        ReplyToCommand(client, "[BM] Health-based spawn interval adjustment DISABLED");
    }
    else if (StrEqual(arg1, "thresholds", false) && args == 4)
    {
        char arg2[16], arg3[16], arg4[16];
        GetCmdArg(2, arg2, sizeof(arg2));
        GetCmdArg(3, arg3, sizeof(arg3));
        GetCmdArg(4, arg4, sizeof(arg4));
        
        float step1 = StringToFloat(arg2);
        float step2 = StringToFloat(arg3);
        float step3 = StringToFloat(arg4);
        
        if (step1 < 0.0 || step1 > 1.0 || step2 < 0.0 || step2 > 1.0 || step3 < 0.0 || step3 > 1.0)
        {
            ReplyToCommand(client, "[BM] Thresholds must be between 0.0 and 1.0");
            return Plugin_Handled;
        }
        
        if (step1 <= step2 || step2 <= step3)
        {
            ReplyToCommand(client, "[BM] Thresholds must be in descending order (step1 > step2 > step3)");
            return Plugin_Handled;
        }
        
        gCvar_HealthStep1Threshold.SetFloat(step1);
        gCvar_HealthStep2Threshold.SetFloat(step2);
        gCvar_HealthStep3Threshold.SetFloat(step3);
        
        ReplyToCommand(client, "[BM] Health thresholds updated:");
        ReplyToCommand(client, "  Step 1: %.0f%%, Step 2: %.0f%%, Step 3: %.0f%%", 
            step1 * 100.0, step2 * 100.0, step3 * 100.0);
    }
    else if (StrEqual(arg1, "multipliers", false) && args == 4)
    {
        char arg2[16], arg3[16], arg4[16];
        GetCmdArg(2, arg2, sizeof(arg2));
        GetCmdArg(3, arg3, sizeof(arg3));
        GetCmdArg(4, arg4, sizeof(arg4));
        
        float mult1 = StringToFloat(arg2);
        float mult2 = StringToFloat(arg3);
        float mult3 = StringToFloat(arg4);
        
        if (mult1 < 1.0 || mult2 < 1.0 || mult3 < 1.0)
        {
            ReplyToCommand(client, "[BM] Multipliers must be >= 1.0");
            return Plugin_Handled;
        }
        
        gCvar_HealthStep1Multiplier.SetFloat(mult1);
        gCvar_HealthStep2Multiplier.SetFloat(mult2);
        gCvar_HealthStep3Multiplier.SetFloat(mult3);
        
        ReplyToCommand(client, "[BM] Interval multipliers updated:");
        ReplyToCommand(client, "  Step 1: %.1fx, Step 2: %.1fx, Step 3: %.1fx", mult1, mult2, mult3);
    }
    else
    {
        ReplyToCommand(client, "[BM] Invalid usage. Use: enable/disable, thresholds <s1> <s2> <s3>, or multipliers <m1> <m2> <m3>");
    }
    
    return Plugin_Handled;
}

// CRITICAL STABILITY FIX: Start stability monitoring timers
void StartStabilityTimers()
{
    // Spawn lock timeout timer
    if (g_SpawnLockTimer != INVALID_HANDLE)
    {
        SafeKillTimer(g_SpawnLockTimer);
    }
    
    g_SpawnLockTimer = CreateTimer(5.0, Timer_CheckSpawnLockTimeout, _, TIMER_REPEAT);
    if (g_SpawnLockTimer == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create spawn lock timeout timer");
    }
    
    // Validation queue cleanup timer
    if (g_ValidationCleanupTimer != INVALID_HANDLE)
    {
        SafeKillTimer(g_ValidationCleanupTimer);
    }
    
    g_ValidationCleanupTimer = CreateTimer(VALIDATION_QUEUE_CLEANUP_INTERVAL, Timer_CleanupValidationQueue, _, TIMER_REPEAT);
    if (g_ValidationCleanupTimer == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create validation cleanup timer");
    }
    
    // Entity reference validation timer
    if (g_EntityValidationTimer != INVALID_HANDLE)
    {
        SafeKillTimer(g_EntityValidationTimer);
    }
    
    g_EntityValidationTimer = CreateTimer(ENTITY_REFERENCE_CHECK_INTERVAL, Timer_ValidateEntityReferences, _, TIMER_REPEAT);
    if (g_EntityValidationTimer == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create entity validation timer");
    }
}

// CRITICAL STABILITY FIX: Spawn lock timeout checker
public Action Timer_CheckSpawnLockTimeout(Handle timer)
{
    if (g_bSpawnLocked)
    {
        float currentTime = GetGameTime();
        float lockDuration = currentTime - g_SpawnLockTime;
        
        if (lockDuration > SPAWN_LOCK_TIMEOUT)
        {
            PrintToServer("[BM] CRITICAL: Spawn lock timeout detected (%.1fs), forcing release", lockDuration);
            ForceReleaseSpawnLock();
        }
    }
    
    return Plugin_Continue;
}

// CRITICAL STABILITY FIX: Force release stuck spawn lock
void ForceReleaseSpawnLock()
{
    g_bSpawnLocked = false;
    g_SpawnLockTime = 0.0;
    
    // Clear any stale validation queue entries
    if (g_PendingSpawns != null)
    {
        int cleared = g_PendingSpawns.Length;
        g_PendingSpawns.Clear();
        if (cleared > 0)
        {
            PrintToServer("[BM] Cleared %d stale validation entries during lock timeout", cleared);
        }
    }
    
    // Resume spawner if it should be running
    TryResumeSpawner();
    
    PrintToServer("[BM] Spawn lock forcibly released - system recovered");
}

// CRITICAL STABILITY FIX: Validation queue cleanup with race condition protection
public Action Timer_CleanupValidationQueue(Handle timer)
{
    if (g_PendingSpawns == null || g_PendingSpawns.Length == 0)
        return Plugin_Continue;
    
    // RACE CONDITION FIX: Check if another timer is modifying arrays
    if (!BeginArrayOperation())
    {
        PrintToServer("[BM] Validation cleanup deferred - arrays in use");
        return Plugin_Continue; // Skip this cycle, try again next time
    }
    
    float currentTime = GetGameTime();
    int removedCount = 0;
    
    // Check from end to beginning to avoid index issues
    for (int i = g_PendingSpawns.Length - 1; i >= 0; i--)
    {
        PendingSpawn spawn;
        g_PendingSpawns.GetArray(i, spawn, sizeof(spawn));
        
        bool shouldRemove = false;
        
        // Remove if too old
        if (currentTime - spawn.creationTime > SPAWN_LOCK_TIMEOUT)
        {
            shouldRemove = true;
            PrintToServer("[BM] Removing stale validation entry (age: %.1fs)", currentTime - spawn.creationTime);
        }
        // Remove if player is no longer valid
        else if (!IsClientInGame(spawn.playerClient) || !IsPlayerAlive(spawn.playerClient))
        {
            shouldRemove = true;
            PrintToServer("[BM] Removing validation entry - player no longer valid");
        }
        
        if (shouldRemove)
        {
            g_PendingSpawns.Erase(i);
            removedCount++;
        }
    }
    
    // If we removed entries and queue is now empty, release spawn lock
    if (removedCount > 0 && g_PendingSpawns.Length == 0 && g_bSpawnLocked)
    {
        PrintToServer("[BM] Validation queue cleared (%d removed), releasing spawn lock", removedCount);
        g_bSpawnLocked = false;
        g_SpawnLockTime = 0.0;
        // TryResumeSpawner() will be called after releasing array lock
    }
    
    // Warn if queue is getting too large
    if (g_PendingSpawns.Length > VALIDATION_QUEUE_MAX_SIZE)
    {
        PrintToServer("[BM] WARNING: Validation queue size (%d) exceeds maximum (%d)", 
            g_PendingSpawns.Length, VALIDATION_QUEUE_MAX_SIZE);
        
        // Emergency cleanup - remove oldest entries
        while (g_PendingSpawns.Length > VALIDATION_QUEUE_MAX_SIZE)
        {
            g_PendingSpawns.Erase(0);
            removedCount++;
        }
        PrintToServer("[BM] Emergency queue cleanup: removed %d oldest entries", removedCount);
    }
    
    EndArrayOperation(); // RACE CONDITION FIX: Release array lock
    
    // Try to resume spawner after releasing lock (safer)
    if (removedCount > 0)
    {
        TryResumeSpawner();
    }
    
    return Plugin_Continue;
}

// CRITICAL STABILITY FIX: Entity reference validation with race condition protection
public Action Timer_ValidateEntityReferences(Handle timer)
{
    // RACE CONDITION FIX: Check if another timer is modifying arrays
    if (!BeginArrayOperation())
    {
        PrintToServer("[BM] Entity validation deferred - arrays in use");
        return Plugin_Continue; // Skip this cycle, try again next time
    }
    
    int invalidCount = 0;
    
    // Validate spawned NPCs list
    if (g_SpawnedNPCs != null)
    {
        for (int i = g_SpawnedNPCs.Length - 1; i >= 0; i--)
        {
            int ref = g_SpawnedNPCs.Get(i);
            
            // ENTITY REFERENCE TIMING FIX: Atomic check-and-use pattern
            int entity = EntRefToEntIndex(ref);
            if (entity == INVALID_ENT_REFERENCE || !IsValidGameEntity(entity))
            {
                g_SpawnedNPCs.Erase(i);
                invalidCount++;
            }
        }
    }
    
    // Validate NPC tracking list
    if (g_NPCTrackingList != null)
    {
        float currentTime = GetGameTime();
        
        for (int i = g_NPCTrackingList.Length - 1; i >= 0; i--)
        {
            NPCTrackingData npcData;
            g_NPCTrackingList.GetArray(i, npcData, sizeof(npcData));
            
            // ENTITY REFERENCE TIMING FIX: Atomic check-and-use pattern
            int entity = EntRefToEntIndex(npcData.entityRef);
            if (entity == INVALID_ENT_REFERENCE || !IsValidGameEntity(entity))
            {
                g_NPCTrackingList.Erase(i);
                invalidCount++;
            }
            else
            {
                // Update validation time (entity is confirmed valid)
                npcData.lastValidationTime = currentTime;
                g_NPCTrackingList.SetArray(i, npcData, sizeof(npcData));
            }
        }
    }
    
    EndArrayOperation(); // RACE CONDITION FIX: Release array lock
    
    if (invalidCount > 0)
    {
        PrintToServer("[BM] Entity validation: removed %d invalid references", invalidCount);
        
        // Try to resume spawner if we freed up slots (safer after releasing lock)
        TryResumeSpawner();
    }
    
    return Plugin_Continue;
}

// CRITICAL STABILITY FIX: Enhanced SetSpawnLock with timeout tracking
void SetSpawnLock(const char[] reason)
{
    if (!g_bSpawnLocked)
    {
        g_bSpawnLocked = true;
        g_SpawnLockTime = GetGameTime();
        PrintToServer("[BM] Spawn lock SET: %s (time: %.1f)", reason, g_SpawnLockTime);
    }
}

// CRITICAL STABILITY FIX: Enhanced ReleaseSpawnLock with validation
void ReleaseSpawnLock(const char[] reason)
{
    if (g_bSpawnLocked)
    {
        float lockDuration = GetGameTime() - g_SpawnLockTime;
        g_bSpawnLocked = false;
        g_SpawnLockTime = 0.0;
        PrintToServer("[BM] Spawn lock RELEASED: %s (held for %.1fs)", reason, lockDuration);
    }
}

// FIXED: OnMapStart with comprehensive cleanup
public void OnMapStart()
{
    // Kill ALL timers before resetting handles
    SafeKillTimer(g_SpawnTimer);
    SafeKillTimer(g_CleanupTimer);
    SafeKillTimer(g_PlayerCacheTimer);
    SafeKillTimer(g_DeathStateTimer);
    SafeKillTimer(g_SpawnLockTimer);
    SafeKillTimer(g_ValidationCleanupTimer);
    SafeKillTimer(g_EntityValidationTimer);
    SafeKillTimer(g_ValidationTimer); // FIXED: Clean up validation timer
    
    // Reset death state and spawn lock
    g_bAllPlayersDead = false;
    g_bSpawnLocked = false;
    g_SpawnLockTime = 0.0;
    
    // RACE CONDITION FIX: Reset array operation lock
    g_bArrayOperationLock = false;
    
    // Reset health adjustment globals
    g_CurrentHealthMultiplier = 1.0;
    g_MaxTeamHealth = 0;
    g_OriginalSpawnInterval = gCvar_SpawnInterval.FloatValue; // Reset to current cvar value
    g_bHealthSystemAdjusting = false; // Reset flag
    g_LastHealthCheck = 0.0; // Reset debouncing
    
    CleanupSpawnedNPCs();
    CleanupTrackingDataPacks();
    
    // Clear all arrays with null checks
    if (g_SpawnedNPCs != null)
        g_SpawnedNPCs.Clear();
    if (g_TrackingDataPacks != null)
        g_TrackingDataPacks.Clear();
    if (g_NPCTrackingList != null)
        g_NPCTrackingList.Clear();
    if (g_PendingSpawns != null)
        g_PendingSpawns.Clear();
    
    // Reset other state
    g_ValidPlayerCount = 0;
    g_DespawnCheckIndex = 0;
    g_CurrentValidationFrame = 0;
    
    // Precache all 3 portal sound files with error checking
    bool soundsOk = true;
    soundsOk &= PrecacheSound("BMS_objects/portal/portal_In_01.wav", true);
    soundsOk &= PrecacheSound("BMS_objects/portal/portal_In_02.wav", true);
    soundsOk &= PrecacheSound("BMS_objects/portal/portal_In_03.wav", true);
    
    if (soundsOk)
    {
        PrintToServer("[BM] Portal sound files precached (3 variations)");
    }
    else
    {
        LogError("[BM] Failed to precache one or more portal sound files");
    }
    
    // Use timer for delayed start to avoid race conditions
    Handle delayTimer = CreateTimer(DELAYED_START_TIME, DelayedStartSpawnerTimer, _);
    if (delayTimer == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create delayed start timer");
        // Fallback: start immediately (no health monitoring timer to start)
        ValidateConVarSettings();
        StartSpawnerTimer();
        StartNPCCleanupTimer();
        StartPlayerCacheTimer();
        StartDeathStateMonitoring();
        StartValidationTimer();
        StartStabilityTimers();
        // Health monitoring is now event-driven - no timer to start
    }
}

// Portal effect function (adapted from teleport plugin)
void CreateSpawnPortalEffect(float position[3])
{
    if (!gCvar_PortalEffect.BoolValue)
    {
        return; // Portal effects disabled
    }
    
    PrintToServer("[BM] Creating portal effect at spawn position: %.1f, %.1f, %.1f", position[0], position[1], position[2]);
    
    // Create the particle system entity
    int particle = CreateEntityByName("info_particle_system");
    if (particle == -1)
    {
        LogError("Failed to create particle system entity for spawn portal");
        return;
    }
    
    // Set the particle system name to xen_portal_med
    DispatchKeyValue(particle, "effect_name", "xen_portal_med");
    
    // Set position
    TeleportEntity(particle, position, NULL_VECTOR, NULL_VECTOR);
    
    // Spawn the entity
    DispatchSpawn(particle);
    
    // Activate the particle effect
    ActivateEntity(particle);
    AcceptEntityInput(particle, "Start");
    
    // Play random portal sound from the 3 available portal entrance sounds
    float volume = gCvar_PortalSoundVolume.FloatValue;
    if (volume > 0.0)
    {
        // Array of portal sound files (from XenPortal.Sound soundscript)
        char portalSounds[3][64];
        strcopy(portalSounds[0], sizeof(portalSounds[]), "BMS_objects/portal/portal_In_01.wav");
        strcopy(portalSounds[1], sizeof(portalSounds[]), "BMS_objects/portal/portal_In_02.wav");
        strcopy(portalSounds[2], sizeof(portalSounds[]), "BMS_objects/portal/portal_In_03.wav");
        
        // Randomly select one of the 3 portal sounds
        int randomSound = GetRandomInt(0, 2);
        
        // Play the selected portal sound at spawn position
        EmitSoundToAll(portalSounds[randomSound], SOUND_FROM_WORLD, SNDCHAN_AUTO, 100, SND_NOFLAGS, volume, SNDPITCH_NORMAL, -1, position);
        
        PrintToServer("[BM] Playing random portal sound: %s at volume %.2f (100dB)", portalSounds[randomSound], volume);
    }
    else
    {
        PrintToServer("[BM] Portal sound disabled (volume: %.2f)", volume);
    }
    
    // Particle will clean itself up after playing
}

// Enhanced DataPack cleanup with better error recovery
void CleanupDataPack(Handle pack)
{
    if (pack == INVALID_HANDLE) return;
    
    // Remove from tracking array if it exists
    if (g_TrackingDataPacks != null)
    {
        int packIndex = g_TrackingDataPacks.FindValue(pack);
        if (packIndex != -1)
        {
            g_TrackingDataPacks.Erase(packIndex);
        }
    }
    
    // Close the handle
    SafeCloseHandle(pack);
}

// Enhanced comprehensive DataPack cleanup for all tracked packs
void CleanupTrackingDataPacks()
{
    if (g_TrackingDataPacks == null) return;
    
    for (int i = 0; i < g_TrackingDataPacks.Length; i++)
    {
        Handle pack = g_TrackingDataPacks.Get(i);
        SafeCloseHandle(pack);
    }
    g_TrackingDataPacks.Clear();
}

// FIXED: SpawnNPCAtLocation with comprehensive DataPack cleanup
void SpawnNPCAtLocation(float origin[3], int npcIndex = -1, bool playPortalEffect = true)
{
    float spawnPos[3];
    spawnPos[0] = origin[0];
    spawnPos[1] = origin[1];
    spawnPos[2] = origin[2] + NPC_HEIGHT_OFFSET;

    if (npcIndex == -1)
        npcIndex = GetWeightedRandomNPCIndex();
        
    if (npcIndex < 0 || npcIndex >= NPC_COUNT)
    {
        PrintToServer("[BM] Error: Invalid NPC index %d", npcIndex);
        return;
    }
    
    char npcType[32];
    strcopy(npcType, sizeof(npcType), g_NPCConfigs[npcIndex].classname);

    // Create portal effect at spawn location only if requested
    if (playPortalEffect)
    {
        CreateSpawnPortalEffect(origin);
    }

    int maker = CreateEntityByName("npc_maker");
    if (maker == -1)
    {
        PrintToServer("[BM] Failed to create NPC maker entity.");
        return;
    }

    // Standard NPC maker setup with error handling
    if (!DispatchKeyValue(maker, "NPCType", npcType) ||
        !DispatchKeyValue(maker, "MaxNPCCount", "1") ||
        !DispatchKeyValue(maker, "MaxLiveChildren", "1") ||
        !DispatchKeyValue(maker, "SpawnFrequency", "1"))
    {
        PrintToServer("[BM] Failed to set basic NPC maker properties.");
        AcceptEntityInput(maker, "Kill");
        return;
    }

    // Standard spawning only
    DispatchKeyValue(maker, "spawnflags", "1280");  // Just Start On

    TeleportEntity(maker, spawnPos, NULL_VECTOR, NULL_VECTOR);
    
    if (!DispatchSpawn(maker))
    {
        PrintToServer("[BM] Failed to spawn NPC maker.");
        AcceptEntityInput(maker, "Kill");
        return;
    }
    
    ActivateEntity(maker);
    AcceptEntityInput(maker, "SpawnNPC");

    // FIXED: Enhanced DataPack handle management with complete error recovery
    Handle pack = CreateDataPack();
    if (pack == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create DataPack for NPC tracking");
        // Cleanup maker entity and exit
        int ref = EntIndexToEntRef(maker);
        Handle cleanupTimer = CreateTimer(MAKER_CLEANUP_DELAY, Timer_RemoveEntity, ref);
        if (cleanupTimer == INVALID_HANDLE)
        {
            LogError("[BM] Failed to create cleanup timer, killing maker immediately");
            AcceptEntityInput(maker, "Kill");
        }
        return;
    }
    
    // Populate DataPack
    WritePackFloat(pack, spawnPos[0]);
    WritePackFloat(pack, spawnPos[1]);
    WritePackFloat(pack, spawnPos[2]);
    WritePackString(pack, npcType);
    WritePackCell(pack, 0); // attempts counter
    ResetPack(pack);
    
    // Ensure TrackingDataPacks array exists before adding
    if (g_TrackingDataPacks == null)
    {
        LogError("[BM] TrackingDataPacks array is null, cannot track NPC");
        SafeCloseHandle(pack);
        int ref = EntIndexToEntRef(maker);
        Handle cleanupTimer = CreateTimer(MAKER_CLEANUP_DELAY, Timer_RemoveEntity, ref);
        if (cleanupTimer == INVALID_HANDLE)
        {
            LogError("[BM] Failed to create cleanup timer, killing maker immediately");
            AcceptEntityInput(maker, "Kill");
        }
        return;
    }
    
    // Add pack to tracking array BEFORE creating timer
    g_TrackingDataPacks.Push(pack);

    // Create tracking timer with enhanced error handling
    Handle trackingTimer = CreateTimer(TRACKING_DELAY, Timer_TrackSpawnedNPC, pack);
    if (trackingTimer == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create tracking timer for NPC");
        // Remove pack from array and close it
        int packIndex = g_TrackingDataPacks.FindValue(pack);
        if (packIndex != -1)
        {
            g_TrackingDataPacks.Erase(packIndex);
        }
        SafeCloseHandle(pack);
        
        // Still try to cleanup the maker
        int ref = EntIndexToEntRef(maker);
        Handle cleanupTimer = CreateTimer(MAKER_CLEANUP_DELAY, Timer_RemoveEntity, ref);
        if (cleanupTimer == INVALID_HANDLE)
        {
            LogError("[BM] Failed to create cleanup timer, killing maker immediately");
            AcceptEntityInput(maker, "Kill");
        }
        return;
    }

    // Create maker cleanup timer
    int ref = EntIndexToEntRef(maker);
    Handle cleanupTimer = CreateTimer(MAKER_CLEANUP_DELAY, Timer_RemoveEntity, ref);
    if (cleanupTimer == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create cleanup timer for NPC maker");
        // Immediately clean up the maker since timer failed
        AcceptEntityInput(maker, "Kill");
    }
}

// FIXED: Comprehensive cleanup for plugin end
public void OnPluginEnd()
{
    // Kill all timers first
    SafeKillTimer(g_SpawnTimer);
    SafeKillTimer(g_CleanupTimer);
    SafeKillTimer(g_PlayerCacheTimer);
    SafeKillTimer(g_DeathStateTimer);
    SafeKillTimer(g_SpawnLockTimer);
    SafeKillTimer(g_ValidationCleanupTimer);
    SafeKillTimer(g_EntityValidationTimer);
    SafeKillTimer(g_ValidationTimer); // FIXED: Clean up validation timer
    
    // Clean up spawned NPCs
    CleanupSpawnedNPCs();
    
    // Clean up all DataPacks
    CleanupTrackingDataPacks();
    
    // Delete and nullify all ArrayLists
    if (g_SpawnedNPCs != null)
    {
        delete g_SpawnedNPCs;
        g_SpawnedNPCs = null;
    }
    if (g_TrackingDataPacks != null)
    {
        delete g_TrackingDataPacks;
        g_TrackingDataPacks = null;
    }
    if (g_NPCTrackingList != null)
    {
        delete g_NPCTrackingList;
        g_NPCTrackingList = null;
    }
    if (g_PendingSpawns != null)
    {
        delete g_PendingSpawns;
        g_PendingSpawns = null;
    }
    
    // Reset spawn lock
    g_bSpawnLocked = false;
    g_SpawnLockTime = 0.0;
    
    // RACE CONDITION FIX: Reset array operation lock
    g_bArrayOperationLock = false;
    
    // Reset health adjustment globals
    g_CurrentHealthMultiplier = 1.0;
    g_MaxTeamHealth = 0;
    g_OriginalSpawnInterval = 30.0;
    g_bHealthSystemAdjusting = false;
    g_LastHealthCheck = 0.0;
    
    PrintToServer("[BM] Plugin cleanup completed - all handles closed, all timers killed");
}

// Death state monitoring functions
void StartDeathStateMonitoring()
{
    // Kill existing timer before creating new one
    if (g_DeathStateTimer != INVALID_HANDLE)
    {
        SafeKillTimer(g_DeathStateTimer);
    }
    
    g_DeathStateTimer = CreateTimer(DEATH_STATE_CHECK_INTERVAL, Timer_CheckDeathState, _, TIMER_REPEAT);
    if (g_DeathStateTimer == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create death state timer");
    }
}

public Action Timer_CheckDeathState(Handle timer)
{
    bool anyPlayerAlive = false;
    bool anyPlayerInGame = false;
    
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            anyPlayerInGame = true;
            if (IsPlayerAlive(client))
            {
                anyPlayerAlive = true;
                break;
            }
        }
    }
    
    bool allPlayersDead = anyPlayerInGame && !anyPlayerAlive;
    
    if (allPlayersDead && !g_bAllPlayersDead)
    {
        g_bAllPlayersDead = true;
        for (int client = 1; client <= MaxClients; client++)
        {
            if (IsClientInGame(client))
            {
               // PrintToChat(client, "[BM] All players eliminated - NPCs will be preserved");
            }
        }
    }
    else if (!allPlayersDead && g_bAllPlayersDead)
    {
        g_bAllPlayersDead = false;
        g_GracePeriodStartTime = GetGameTime();
        for (int client = 1; client <= MaxClients; client++)
        {
            if (IsClientInGame(client))
            {
                //PrintToChat(client, "[BM] Grace period active - NPCs preserved for 60 seconds");
            }
        }
    }
    
    return Plugin_Continue;
}

public Action Timer_UpdatePlayerCache(Handle timer)
{
    UpdatePlayerCache();
    return Plugin_Continue;
}

// Continue with Timer_ValidateSpawns with enhanced stability and race condition protection...
public Action Timer_ValidateSpawns(Handle timer)
{
    if (g_PendingSpawns == null || g_PendingSpawns.Length == 0)
        return Plugin_Continue;
    
    // RACE CONDITION FIX: Check if another timer is modifying arrays
    if (!BeginArrayOperation())
    {
        PrintToServer("[BM] Validation timer deferred - arrays in use");
        return Plugin_Continue; // Skip this cycle, try again next time
    }
    
    g_CurrentValidationFrame++;
    float currentTime = GetGameTime();
    
    for (int i = g_PendingSpawns.Length - 1; i >= 0; i--)
    {
        PendingSpawn spawn;
        g_PendingSpawns.GetArray(i, spawn, sizeof(spawn));
        
        // CRITICAL STABILITY FIX: Check if validation entry is too old
        if (currentTime - spawn.creationTime > SPAWN_LOCK_TIMEOUT)
        {
            PrintToServer("[BM] Removing stale validation entry (age: %.1fs)", currentTime - spawn.creationTime);
            g_PendingSpawns.Erase(i);
            continue;
        }
        
        if (!IsClientInGame(spawn.playerClient) || !IsPlayerAlive(spawn.playerClient))
        {
            g_PendingSpawns.Erase(i);
            // If this was the last pending spawn, release the lock
            if (g_PendingSpawns.Length == 0)
            {
                ReleaseSpawnLock("validation queue cleared - player invalid");
            }
            continue;
        }
        
        bool stillHidden = !IsPositionVisibleToAnyPlayer(spawn.position);
        
        if (stillHidden)
        {
            spawn.validationCount++;
        }
        else
        {
            spawn.validationCount = 0;
        }
        
        spawn.validationFrame = g_CurrentValidationFrame;
        g_PendingSpawns.SetArray(i, spawn, sizeof(spawn));
        
        if (spawn.validationCount >= VALIDATION_FRAMES)
        {
            CleanupInvalidNPCReferences();
            if (g_SpawnedNPCs.Length < gCvar_MaxNPCCount.IntValue)
            {
                // For validation spawns, they're always stealth (hidden) by definition
                SpawnNPCGroup(spawn.npcIndex, spawn.position, spawn.groupSize, false);
                PrintToServer("[BM] Validation complete - spawning stealth NPC group");
            }
            else
            {
                PrintToServer("[BM] Validation complete but max NPCs reached - skipping spawn");
            }
            
            g_PendingSpawns.Erase(i);
            
            // CRITICAL STABILITY FIX: Release spawn lock after successful validation spawn
            ReleaseSpawnLock("validation spawn complete");
        }
        else if (g_CurrentValidationFrame - spawn.validationFrame > VALIDATION_FRAMES * 2)
        {
            PrintToServer("[BM] Validation timeout - removing from queue");
            g_PendingSpawns.Erase(i);
            
            // If this was the last pending spawn, release the lock
            if (g_PendingSpawns.Length == 0)
            {
                ReleaseSpawnLock("validation timeout");
            }
        }
    }
    
    EndArrayOperation(); // RACE CONDITION FIX: Release array lock
    return Plugin_Continue;
}

// CRITICAL STABILITY FIX: Enhanced OnEntityDestroyed with proper validation and race condition protection
public void OnEntityDestroyed(int entity)
{
    if (g_SpawnedNPCs == null) return;
    
    // RACE CONDITION FIX: Use array operation lock for safety
    if (!BeginArrayOperation())
    {
        // If we can't get the lock, defer this cleanup
        // The entity validation timer will catch this later
        return;
    }
    
    for (int i = g_SpawnedNPCs.Length - 1; i >= 0; i--)
    {
        int ref = g_SpawnedNPCs.Get(i);
        if (ref == INVALID_ENT_REFERENCE) 
        {
            g_SpawnedNPCs.Erase(i);
            continue;
        }
        
        // ENTITY REFERENCE TIMING FIX: Atomic check-and-use pattern
        int ent = EntRefToEntIndex(ref);
        if (ent == entity)
        {
            g_SpawnedNPCs.Erase(i);
            RemoveFromNPCTracking(ref);
            // TryResumeSpawner() will be called after releasing lock
            break;
        }
        // Also remove invalid entity references found during this scan
        else if (ent == INVALID_ENT_REFERENCE)
        {
            g_SpawnedNPCs.Erase(i);
            RemoveFromNPCTracking(ref);
        }
    }
    
    EndArrayOperation(); // RACE CONDITION FIX: Release array lock
    
    // Try to resume spawner after releasing lock (safer)
    TryResumeSpawner();
}

// FIXED: Enhanced Timer_TrackSpawnedNPC with comprehensive cleanup and retry logic
public Action Timer_TrackSpawnedNPC(Handle timer, Handle pack)
{
    if (pack == INVALID_HANDLE) 
    {
        LogError("[BM] Timer_TrackSpawnedNPC called with invalid DataPack");
        return Plugin_Stop;
    }
    
    // Validate pack is still in our tracking array
    if (g_TrackingDataPacks == null || g_TrackingDataPacks.FindValue(pack) == -1)
    {
        LogError("[BM] DataPack not found in tracking array, likely already cleaned up");
        return Plugin_Stop;
    }
    
    ResetPack(pack);
    float x = ReadPackFloat(pack);
    float y = ReadPackFloat(pack);
    float z = ReadPackFloat(pack);
    char classname[32];
    ReadPackString(pack, classname, sizeof(classname));
    int attempts = ReadPackCell(pack) + 1;
    
    int entity = -1;
    bool found = false;
    
    // Search for the spawned NPC
    while ((entity = FindEntityByClassname(entity, classname)) != -1)
    {
        if (!IsValidGameEntity(entity))
            continue;

        float pos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);

        float distSqr = (x - pos[0]) * (x - pos[0]) + 
                       (y - pos[1]) * (y - pos[1]) + 
                       (z - pos[2]) * (z - pos[2]);
                       
        if (distSqr < NPC_TRACKING_RANGE * NPC_TRACKING_RANGE)
        {
            int ref = EntIndexToEntRef(entity);
            
            // RACE CONDITION FIX: Use safe add function and check for conflicts
            if (!BeginArrayOperation())
            {
                PrintToServer("[BM] NPC tracking deferred - arrays in use");
                // Will retry on next timer cycle
                return Plugin_Stop;
            }
            
            if (g_SpawnedNPCs != null && SafeAddSpawnedNPC(ref))
            {
                AddToNPCTracking(ref);
                found = true;
                EndArrayOperation(); // RACE CONDITION FIX: Release array lock
                break;
            }
            else
            {
                EndArrayOperation(); // RACE CONDITION FIX: Release array lock
                // NPC already exists or arrays are null, continue searching
            }
        }
    }
    
    // If not found and we have attempts left, retry with new timer
    if (!found && attempts < MAX_TRACKING_ATTEMPTS)
    {
        // Update the pack with new attempt count
        ResetPack(pack);
        WritePackFloat(pack, x);
        WritePackFloat(pack, y);
        WritePackFloat(pack, z);
        WritePackString(pack, classname);
        WritePackCell(pack, attempts);
        ResetPack(pack);
        
        // Create retry timer
        Handle retryTimer = CreateTimer(TRACKING_RETRY_DELAY, Timer_TrackSpawnedNPC, pack);
        if (retryTimer == INVALID_HANDLE)
        {
            LogError("[BM] Failed to create retry timer for NPC tracking attempt %d", attempts);
            // Can't retry, clean up the pack
            CleanupDataPack(pack);
        }
        // If timer creation succeeded, the pack stays alive for the retry
        return Plugin_Stop;
    }

    // We're done with this pack (either found the NPC or exhausted retries)
    CleanupDataPack(pack);
    
    if (!found)
    {
        PrintToServer("[BM] Failed to find spawned NPC %s after %d attempts", classname, attempts);
    }
    
    return Plugin_Stop;
}

public Action DelayedStartSpawnerTimer(Handle timer)
{
    ValidateConVarSettings();
    StartSpawnerTimer();
    StartNPCCleanupTimer();
    StartPlayerCacheTimer();
    StartDeathStateMonitoring();
    StartValidationTimer();
    StartStabilityTimers();
    
    // Store original interval for health system
    g_OriginalSpawnInterval = gCvar_SpawnInterval.FloatValue;
    
    PrintToServer("[BM] Event-driven health monitoring is active");
    return Plugin_Stop;
}

// FIXED: StartValidationTimer with proper global handle management
void StartValidationTimer()
{
    // Kill existing timer before creating new one
    if (g_ValidationTimer != INVALID_HANDLE)
    {
        SafeKillTimer(g_ValidationTimer);
    }
    
    g_ValidationTimer = CreateTimer(VALIDATION_FRAME_DELAY, Timer_ValidateSpawns, _, TIMER_REPEAT);
    if (g_ValidationTimer == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create validation timer");
    }
}

void ValidateConVarSettings()
{
    float maxDist = gCvar_MaxSpawnDistance.FloatValue;
    float minDist = gCvar_MinSpawnDistance.FloatValue;
    
    if (minDist >= maxDist)
    {
        PrintToServer("[BM] Warning: Invalid spawn distance settings - auto-correcting");
        float correctedMin = maxDist * MIN_DISTANCE_RATIO;
        gCvar_MinSpawnDistance.SetFloat(correctedMin);
    }
}

// CRITICAL STABILITY FIX: Enhanced TryResumeSpawner with validation
void TryResumeSpawner()
{
    CleanupInvalidNPCReferences();
    
    // Don't resume if spawn lock is held (could be in validation)
    if (g_bSpawnLocked)
    {
        return;
    }
    
    if (g_bSpawnerEnabled && g_SpawnTimer == INVALID_HANDLE && g_SpawnedNPCs.Length < gCvar_MaxNPCCount.IntValue)
    {
        StartSpawnerTimer();
    }
}

// CRITICAL STABILITY FIX: Enhanced CleanupInvalidNPCReferences with better validation
void CleanupInvalidNPCReferences()
{
    if (g_SpawnedNPCs == null) return;
    
    int removedCount = 0;
    
    for (int i = g_SpawnedNPCs.Length - 1; i >= 0; i--)
    {
        int ref = g_SpawnedNPCs.Get(i);
        if (!IsValidEntityReference(ref))
        {
            g_SpawnedNPCs.Erase(i);
            removedCount++;
        }
    }
    
    if (removedCount > 0)
    {
        PrintToServer("[BM] Cleaned up %d invalid NPC references", removedCount);
    }
}

void CleanupSpawnedNPCs()
{
    if (g_SpawnedNPCs == null) return;
    
    for (int i = 0; i < g_SpawnedNPCs.Length; i++)
    {
        int ref = g_SpawnedNPCs.Get(i);
        if (ref == INVALID_ENT_REFERENCE) continue;
        
        int ent = EntRefToEntIndex(ref);
        if (ent != INVALID_ENT_REFERENCE && IsValidGameEntity(ent))
        {
            AcceptEntityInput(ent, "Kill");
        }
    }
    g_SpawnedNPCs.Clear();
}

public void OnSpawnIntervalChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    // Only treat as manual change if health system is NOT adjusting
    if (!g_bHealthSystemAdjusting)
    {
        OnSpawnIntervalManuallyChanged();
    }
    
    // Restart timer with new interval (only if not health-adjusted)
    if (g_bSpawnerEnabled && g_SpawnTimer != INVALID_HANDLE)
    {
        SafeKillTimer(g_SpawnTimer);
        StartSpawnerTimer();
    }
}

public void OnHealthAdjustmentEnabledChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    bool enabled = (newValue[0] == '1');
    OnHealthAdjustmentToggled(enabled);
}

public void OnSpawnerEnabledChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    g_bSpawnerEnabled = (newValue[0] == '1');
    if (g_bSpawnerEnabled)
    {
        StartSpawnerTimer();
        PrintToChatAll("[BM] Xen Spawner ENABLED.");
    }
    else
    {
        StopSpawnerTimer();
        PrintToChatAll("[BM] Xen Spawner DISABLED.");
    }
}

public void OnDistanceConVarChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    ValidateConVarSettings();
}

// Enhanced timer management functions with comprehensive cleanup
void StartSpawnerTimer()
{
    // Kill existing timer before creating new one
    if (g_SpawnTimer != INVALID_HANDLE)
    {
        SafeKillTimer(g_SpawnTimer);
    }
    
    if (g_bSpawnerEnabled)
    {
        float interval = gCvar_SpawnInterval.FloatValue;
        g_SpawnTimer = CreateTimer(interval, Timer_SpawnNPC, _, TIMER_REPEAT);
        if (g_SpawnTimer == INVALID_HANDLE)
        {
            LogError("[BM] Failed to create spawn timer");
        }
    }
}

void StopSpawnerTimer()
{
    if (g_SpawnTimer != INVALID_HANDLE)
    {
        SafeKillTimer(g_SpawnTimer);
    }
}

void StartNPCCleanupTimer()
{
    // Kill existing timer before creating new one
    if (g_CleanupTimer != INVALID_HANDLE)
    {
        SafeKillTimer(g_CleanupTimer);
    }
    
    g_CleanupTimer = CreateTimer(NPC_CLEANUP_INTERVAL, Timer_CheckNPCDespawn, _, TIMER_REPEAT);
    if (g_CleanupTimer == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create cleanup timer");
    }
}

void StartPlayerCacheTimer()
{
    // Kill existing timer before creating new one
    if (g_PlayerCacheTimer != INVALID_HANDLE)
    {
        SafeKillTimer(g_PlayerCacheTimer);
    }
    
    g_PlayerCacheTimer = CreateTimer(PLAYER_CACHE_UPDATE_INTERVAL, Timer_UpdatePlayerCache, _, TIMER_REPEAT);
    if (g_PlayerCacheTimer == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create player cache timer");
    }
    else
    {
        UpdatePlayerCache(); // Initial cache update
    }
}

// CRITICAL STABILITY FIX: Enhanced Timer_CheckNPCDespawn with better entity validation and race condition protection
public Action Timer_CheckNPCDespawn(Handle timer)
{
    if (g_NPCTrackingList == null || g_SpawnedNPCs == null) return Plugin_Continue;
    
    // RACE CONDITION FIX: Check if another timer is modifying arrays
    if (!BeginArrayOperation())
    {
        PrintToServer("[BM] Despawn timer deferred - arrays in use");
        return Plugin_Continue; // Skip this cycle, try again next time
    }
    
    if (g_bAllPlayersDead)
    {
        EndArrayOperation(); // RACE CONDITION FIX: Release array lock
        return Plugin_Continue;
    }
    
    if (g_GracePeriodStartTime > 0.0 && GetGameTime() < g_GracePeriodStartTime + 60.0)
    {
        EndArrayOperation(); // RACE CONDITION FIX: Release array lock
        return Plugin_Continue;
    }

    int totalNPCs = g_NPCTrackingList.Length;
    if (totalNPCs == 0) 
    {
        EndArrayOperation(); // RACE CONDITION FIX: Release array lock
        return Plugin_Continue;
    }
    
    int checksThisFrame = 0;
    float despawnDistance = gCvar_NPCDespawnDistance.FloatValue;
    
    while (checksThisFrame < MAX_DESPAWN_CHECKS_PER_FRAME && g_DespawnCheckIndex < totalNPCs)
    {
        NPCTrackingData npcData;
        g_NPCTrackingList.GetArray(g_DespawnCheckIndex, npcData, sizeof(npcData));
        
        // ENTITY REFERENCE TIMING FIX: Atomic check-and-use pattern
        int entity = EntRefToEntIndex(npcData.entityRef);
        if (entity == INVALID_ENT_REFERENCE || !IsValidGameEntity(entity))
        {
            // Remove invalid entity
            g_NPCTrackingList.Erase(g_DespawnCheckIndex);
            totalNPCs--;
            continue;
        }
        
        // Use 'entity' directly (already validated)
        float npcPos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", npcPos);
        
        float closestDistance = 999999.0;
        
        for (int i = 0; i < g_ValidPlayerCount; i++)
        {
            int client = g_ValidPlayers[i];
            float distance = GetVectorDistance(npcPos, g_PlayerPositions[client]);
            
            if (distance < closestDistance)
            {
                closestDistance = distance;
            }
        }
        
        npcData.lastPlayerDistance = closestDistance;
        npcData.lastValidationTime = GetGameTime();  // CRITICAL STABILITY FIX: Update validation time
        
        bool shouldDespawn = (closestDistance > despawnDistance);
        
        if (shouldDespawn)
        {
            // RACE CONDITION FIX: Use safe removal function
            SafeRemoveSpawnedNPC(npcData.entityRef);
            g_NPCTrackingList.Erase(g_DespawnCheckIndex);
            totalNPCs--;
            
            AcceptEntityInput(entity, "Kill");
            // Note: TryResumeSpawner() will be called after releasing array lock
            
            continue;
        }
        else
        {
            g_NPCTrackingList.SetArray(g_DespawnCheckIndex, npcData, sizeof(npcData));
        }
        
        g_DespawnCheckIndex++;
        checksThisFrame++;
    }
    
    if (g_DespawnCheckIndex >= totalNPCs)
    {
        g_DespawnCheckIndex = 0;
    }
    
    EndArrayOperation(); // RACE CONDITION FIX: Release array lock
    
    // Try to resume spawner after releasing lock (safer)
    TryResumeSpawner();
    
    return Plugin_Continue;
}

// CRITICAL STABILITY FIX: Enhanced AddToNPCTracking with validation
void AddToNPCTracking(int entityRef)
{
    if (g_NPCTrackingList == null) return;
    
    // Validate the entity reference before adding
    if (!IsValidEntityReference(entityRef))
    {
        PrintToServer("[BM] Warning: Attempted to track invalid entity reference");
        return;
    }
    
    NPCTrackingData npcData;
    npcData.entityRef = entityRef;
    npcData.lastPlayerDistance = 0.0;
    npcData.lastValidationTime = GetGameTime();
    
    g_NPCTrackingList.PushArray(npcData, sizeof(npcData));
}

void RemoveFromNPCTracking(int entityRef)
{
    if (g_NPCTrackingList == null) return;
    
    for (int i = g_NPCTrackingList.Length - 1; i >= 0; i--)
    {
        NPCTrackingData npcData;
        g_NPCTrackingList.GetArray(i, npcData, sizeof(npcData));
        
        if (npcData.entityRef == entityRef)
        {
            g_NPCTrackingList.Erase(i);
            break;
        }
    }
}

public Action Command_SpawnerStatus(int client, int args)
{
    // Simple, essential status information
    int activeNPCs = g_SpawnedNPCs != null ? g_SpawnedNPCs.Length : 0;
    int maxNPCs = gCvar_MaxNPCCount.IntValue;
    bool enabled = g_bSpawnerEnabled;
    float interval = gCvar_SpawnInterval.FloatValue;
    
    char status[256];
    Format(status, sizeof(status), "[BM] Spawner: %s | Active NPCs: %d/%d | Interval: %.1fs", 
        enabled ? "ENABLED" : "DISABLED",
        activeNPCs,
        maxNPCs,
        interval);
    
    if (client == 0)
    {
        PrintToServer("%s", status);
    }
    else
    {
        PrintToChat(client, "%s", status);
    }
    
    // Add health-based interval information
    if (gCvar_HealthAdjustmentEnabled.BoolValue)
    {
        int teamHealth = CalculateTeamHealthPool();
        
        char healthStatus[256];
        Format(healthStatus, sizeof(healthStatus), "[BM] Health Multiplier: %.1fx | Team Health: %d/%d (%.1f%%)", 
            g_CurrentHealthMultiplier, 
            teamHealth, 
            g_MaxTeamHealth,
            g_MaxTeamHealth > 0 ? (float(teamHealth) / float(g_MaxTeamHealth)) * 100.0 : 0.0);
        
        if (client == 0)
        {
            PrintToServer("%s", healthStatus);
        }
        else
        {
            PrintToChat(client, "%s", healthStatus);
        }
    }
    
    return Plugin_Handled;
}

// OPTION 5: NPC Information Command
public Action Command_NPCInfo(int client, int args)
{
    bool usePortalChance = gCvar_UsePortalChance.BoolValue;
    bool usePoolSpawning = gCvar_UsePoolSpawning.BoolValue;
    
    ReplyToCommand(client, "[BM] NPC Spawn Information:");
    
    if (usePoolSpawning)
    {
        ReplyToCommand(client, "Pool Spawn Type Control: ENABLED");
        float portalWeight = gCvar_PortalNPCWeight.FloatValue;
        float stealthWeight = gCvar_StealthNPCWeight.FloatValue;
        float total = portalWeight + stealthWeight;
        
        if (total > 0.0)
        {
            float portalPercent = (portalWeight / total) * 100.0;
            ReplyToCommand(client, "Spawn Type Distribution: %.1f%% portal, %.1f%% stealth", portalPercent, 100.0 - portalPercent);
        }
        
        ReplyToCommand(client, "Portal Effects: %s", gCvar_PortalEffect.BoolValue ? "ON" : "OFF");
        ReplyToCommand(client, "");
        ReplyToCommand(client, "NPC Spawn Type Capabilities:");
        
        // Group NPCs by capabilities
        ReplyToCommand(client, "Portal-Capable NPCs (can spawn as portal when selected):");
        for (int i = 0; i < NPC_COUNT; i++)
        {
            if (!g_NPCConfigs[i].enabled) continue;
            if (g_NPCConfigs[i].portalChance <= 0.0) continue;
            
            char npcName[32];
            strcopy(npcName, sizeof(npcName), g_NPCConfigs[i].classname[4]); // Remove "npc_"
            ReplyToCommand(client, "  %s", npcName);
        }
        
        ReplyToCommand(client, "Stealth-Capable NPCs (can spawn as stealth when selected):");
        for (int i = 0; i < NPC_COUNT; i++)
        {
            if (!g_NPCConfigs[i].enabled) continue;
            if (g_NPCConfigs[i].portalChance >= 1.0) continue;
            
            char npcName[32];
            strcopy(npcName, sizeof(npcName), g_NPCConfigs[i].classname[4]); // Remove "npc_"
            ReplyToCommand(client, "  %s", npcName);
        }
    }
    else if (usePortalChance)
    {
        ReplyToCommand(client, "Portal Chance System: ENABLED");
        ReplyToCommand(client, "Pool Spawn Type Control: DISABLED");
        ReplyToCommand(client, "Portal Effects: %s", gCvar_PortalEffect.BoolValue ? "ON" : "OFF");
        ReplyToCommand(client, "");
        ReplyToCommand(client, "Per-NPC Portal Probabilities:");
        
        for (int i = 0; i < NPC_COUNT; i++)
        {
            if (!g_NPCConfigs[i].enabled) continue;
            
            char npcName[32];
            strcopy(npcName, sizeof(npcName), g_NPCConfigs[i].classname[4]); // Remove "npc_"
            
            float portalPercent = g_NPCConfigs[i].portalChance * 100.0;
            float stealthPercent = 100.0 - portalPercent;
            
            ReplyToCommand(client, "  %s: %.0f%% portal, %.0f%% stealth", 
                npcName, portalPercent, stealthPercent);
        }
    }
    else
    {
        ReplyToCommand(client, "Portal Chance System: DISABLED");
        ReplyToCommand(client, "Pool Spawn Type Control: DISABLED");
        ReplyToCommand(client, "Portal Effects: %s", gCvar_PortalEffect.BoolValue ? "ON" : "OFF");
        ReplyToCommand(client, "Portal In-Sight: %s", gCvar_PortalSpawnInSight.BoolValue ? "ON" : "OFF");
        ReplyToCommand(client, "");
        ReplyToCommand(client, "Classic NPC Classification:");
        ReplyToCommand(client, "Portal NPCs (spawn with portal effects when in-sight enabled):");
        
        for (int i = 0; i < NPC_COUNT; i++)
        {
            if (!g_NPCConfigs[i].enabled || !g_NPCConfigs[i].allowPortalSpawn) continue;
            
            char npcName[32];
            strcopy(npcName, sizeof(npcName), g_NPCConfigs[i].classname[4]); // Remove "npc_"
            ReplyToCommand(client, "  %s", npcName);
        }
        
        ReplyToCommand(client, "Stealth NPCs (always spawn hidden):");
        
        for (int i = 0; i < NPC_COUNT; i++)
        {
            if (!g_NPCConfigs[i].enabled || g_NPCConfigs[i].allowPortalSpawn) continue;
            
            char npcName[32];
            strcopy(npcName, sizeof(npcName), g_NPCConfigs[i].classname[4]); // Remove "npc_"
            ReplyToCommand(client, "  %s", npcName);
        }
    }
    
    return Plugin_Handled;
}

// CRITICAL STABILITY FIX: Enhanced Timer_SpawnNPC with Option 2 + 7 retry logic and race condition protection
public Action Timer_SpawnNPC(Handle timer)
{
    if (!g_bSpawnerEnabled) 
    {
        SafeKillTimer(g_SpawnTimer);
        return Plugin_Stop;
    }
    
    // RACE CONDITION FIX: Check if another timer is modifying arrays
    if (!BeginArrayOperation())
    {
        PrintToServer("[BM] Spawn timer deferred - arrays in use");
        return Plugin_Continue; // Skip this cycle, try again next time
    }
    
    // CRITICAL STABILITY FIX: Reset spawn lock at start of each timer cycle with timeout check
    if (g_bSpawnLocked)
    {
        float lockDuration = GetGameTime() - g_SpawnLockTime;
        if (lockDuration > SPAWN_LOCK_TIMEOUT)
        {
            PrintToServer("[BM] Spawn lock timeout in timer cycle, forcing release");
            ForceReleaseSpawnLock();
        }
        else
        {
            // Lock is valid, don't spawn this cycle
            EndArrayOperation(); // RACE CONDITION FIX: Release array lock
            return Plugin_Continue;
        }
    }
    else
    {
        // Ensure lock is properly cleared at start of cycle
        g_bSpawnLocked = false;
        g_SpawnLockTime = 0.0;
    }
    
    CleanupInvalidNPCReferences();
    
    if (g_SpawnedNPCs.Length >= gCvar_MaxNPCCount.IntValue)
    {
        SafeKillTimer(g_SpawnTimer);
        EndArrayOperation(); // RACE CONDITION FIX: Release array lock
        return Plugin_Stop;
    }

    float maxDist = gCvar_MaxSpawnDistance.FloatValue;
    float minDist = gCvar_MinSpawnDistance.FloatValue;
    
    if (minDist >= maxDist)
    {
        PrintToServer("[BM] Error: Invalid distance settings");
        EndArrayOperation(); // RACE CONDITION FIX: Release array lock
        return Plugin_Continue;
    }

    // OPTION 7: Player Rotation Retry - Build list of all valid players
    int validPlayers[MAXPLAYERS + 1];
    int playerCount = 0;
    
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && IsPlayerAlive(client))
        {
            validPlayers[playerCount++] = client;
        }
    }
    
    if (playerCount == 0)
    {
        PrintToServer("[BM] No valid players found for spawning");
        EndArrayOperation(); // RACE CONDITION FIX: Release array lock
        return Plugin_Continue;
    }
    
    // OPTION 7: Try each player in sequence until one succeeds
    bool spawnAttempted = false;
    for (int i = 0; i < playerCount; i++)
    {
        int playerToTry = validPlayers[i];
        
        // Try spawning near this player
        if (AttemptSpawnNearPlayer(playerToTry))
        {
            spawnAttempted = true;
            PrintToServer("[BM] Successfully spawned NPC near player %d", playerToTry);
            break; // Success! Exit the player rotation loop
        }
        else
        {
            PrintToServer("[BM] No valid spawn candidates found near player %d, trying next player", playerToTry);
        }
    }
    
    // OPTION 2: Fixed Short Retry Interval - If all players failed, set short retry
    if (!spawnAttempted)
    {
        PrintToServer("[BM] No valid spawn candidates found near any player (%d players tried)", playerCount);
        
        // Kill current timer and create short retry timer
        SafeKillTimer(g_SpawnTimer);
        
        float retryInterval = 10.0; // Fixed 10 second retry when all players fail
        g_SpawnTimer = CreateTimer(retryInterval, Timer_SpawnNPC_ShortRetry, _, TIMER_FLAG_NO_MAPCHANGE);
        
        if (g_SpawnTimer == INVALID_HANDLE)
        {
            LogError("[BM] Failed to create short retry timer, falling back to normal interval");
            StartSpawnerTimer(); // Fallback to normal timer
        }
        else
        {
            PrintToServer("[BM] All players failed - retrying in %.1f seconds", retryInterval);
        }
    }
    
    EndArrayOperation(); // RACE CONDITION FIX: Release array lock
    return Plugin_Continue;
}

// OPTION 2: Short retry timer callback - tries once then returns to normal interval
public Action Timer_SpawnNPC_ShortRetry(Handle timer)
{
    if (!g_bSpawnerEnabled) 
    {
        SafeKillTimer(g_SpawnTimer);
        return Plugin_Stop;
    }
    
    PrintToServer("[BM] Short retry attempt triggered");
    
    // Kill the short retry timer and restore normal timer regardless of outcome
    SafeKillTimer(g_SpawnTimer);
    StartSpawnerTimer(); // This will create the normal interval timer
    
    // RACE CONDITION FIX: Check if another timer is modifying arrays
    if (!BeginArrayOperation())
    {
        PrintToServer("[BM] Short retry deferred - arrays in use");
        return Plugin_Stop; // Normal timer will continue
    }
    
    // Now attempt the same logic as the main timer
    // CRITICAL STABILITY FIX: Reset spawn lock check
    if (g_bSpawnLocked)
    {
        float lockDuration = GetGameTime() - g_SpawnLockTime;
        if (lockDuration > SPAWN_LOCK_TIMEOUT)
        {
            PrintToServer("[BM] Spawn lock timeout in short retry, forcing release");
            ForceReleaseSpawnLock();
        }
        else
        {
            PrintToServer("[BM] Short retry skipped - spawn lock active");
            EndArrayOperation(); // RACE CONDITION FIX: Release array lock
            return Plugin_Stop; // Normal timer will continue
        }
    }
    
    CleanupInvalidNPCReferences();
    
    if (g_SpawnedNPCs.Length >= gCvar_MaxNPCCount.IntValue)
    {
        PrintToServer("[BM] Short retry skipped - max NPCs reached");
        EndArrayOperation(); // RACE CONDITION FIX: Release array lock
        return Plugin_Stop; // Normal timer will continue
    }

    float maxDist = gCvar_MaxSpawnDistance.FloatValue;
    float minDist = gCvar_MinSpawnDistance.FloatValue;
    
    if (minDist >= maxDist)
    {
        PrintToServer("[BM] Short retry skipped - invalid distance settings");
        EndArrayOperation(); // RACE CONDITION FIX: Release array lock
        return Plugin_Stop;
    }

    // OPTION 7: Same player rotation logic for retry
    int validPlayers[MAXPLAYERS + 1];
    int playerCount = 0;
    
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && IsPlayerAlive(client))
        {
            validPlayers[playerCount++] = client;
        }
    }
    
    if (playerCount == 0)
    {
        PrintToServer("[BM] Short retry - no valid players found");
        EndArrayOperation(); // RACE CONDITION FIX: Release array lock
        return Plugin_Stop;
    }
    
    // Try each player in sequence
    for (int i = 0; i < playerCount; i++)
    {
        int playerToTry = validPlayers[i];
        
        if (AttemptSpawnNearPlayer(playerToTry))
        {
            PrintToServer("[BM] Short retry successful - spawned NPC near player %d", playerToTry);
            break; // Success! 
        }
    }
    
    PrintToServer("[BM] Short retry completed - all %d players attempted", playerCount);
    EndArrayOperation(); // RACE CONDITION FIX: Release array lock
    return Plugin_Stop; // Short retry is complete, normal timer continues
}

// OPTION 7: Extracted spawn attempt logic for reuse
// Returns true if spawn was attempted (regardless of success), false if no valid candidates
bool AttemptSpawnNearPlayer(int client)
{
    if (!g_PlayerValid[client]) 
    {
        return false;
    }
    
    // CRITICAL STABILITY FIX: Enhanced spawn lock check with timeout protection
    if (g_bSpawnLocked)
    {
        float lockDuration = GetGameTime() - g_SpawnLockTime;
        if (lockDuration > SPAWN_LOCK_TIMEOUT)
        {
            PrintToServer("[BM] Spawn lock timeout detected in player attempt, forcing release");
            ForceReleaseSpawnLock();
        }
        else
        {
            return false; // Lock is valid, can't spawn
        }
    }
    
    float playerOrigin[3];
    playerOrigin[0] = g_PlayerPositions[client][0];
    playerOrigin[1] = g_PlayerPositions[client][1];
    playerOrigin[2] = g_PlayerPositions[client][2];

    bool tryOutOfSight = (gCvar_VisibilityCheck.IntValue == 1);
    float maxDist = gCvar_MaxSpawnDistance.FloatValue;
    float minDist = gCvar_MinSpawnDistance.FloatValue;
    
    float distancePreference = gCvar_SpawnDistancePreference.FloatValue;
    int maxCandidates = gCvar_SpawnCandidates.IntValue;
    
    // ARRAY BOUNDS FIX: Clamp maxCandidates to array size to prevent overflow
    int originalMaxCandidates = maxCandidates;
    maxCandidates = (maxCandidates > 10) ? 10 : maxCandidates; // Clamp to array size
    maxCandidates = (maxCandidates < 1) ? 1 : maxCandidates;   // Ensure minimum
    
    if (originalMaxCandidates != maxCandidates)
    {
        PrintToServer("[BM] Spawn candidates clamped from %d to %d (array bounds protection)", 
                     originalMaxCandidates, maxCandidates);
    }
    
    float candidatePositions[10][3];
    float candidateDistances[10];
    int candidateNPCIndices[10];
    bool candidateValid[10];
    int validCandidates = 0;
    
    for (int i = 0; i < 10; i++)
    {
        candidateValid[i] = false;
    }
    
    int totalAttempts = 0;
    int maxTotalAttempts = MAX_SPAWN_ATTEMPTS * maxCandidates;
    
    // INFINITE LOOP FIX: Time-based loop breaking (10ms maximum)
    float loopStartTime = GetGameTime();
    float maxLoopTime = 0.01; // 10 milliseconds maximum
    
    // OPTION A: Declare spawn type variable at function scope
    bool spawnAsPortal = false;
    
    while (validCandidates < maxCandidates && totalAttempts < maxTotalAttempts)
    {
        // INFINITE LOOP FIX: Check time every 10 iterations to avoid constant time checks
        if (totalAttempts % 10 == 0 && totalAttempts > 0)
        {
            if (GetGameTime() - loopStartTime > maxLoopTime)
            {
                PrintToServer("[BM] Spawn search timeout after %.1fms (%d attempts) - player %d", 
                             (GetGameTime() - loopStartTime) * 1000, totalAttempts, client);
                break; // Exit loop, will trigger retry system if all players timeout
            }
        }
        
        float tryPos[3], groundPos[3];
        
        float offsetX = GetRandomFloat(-maxDist, maxDist);
        float offsetY = GetRandomFloat(-maxDist, maxDist);
        
        float distance = SquareRoot(offsetX * offsetX + offsetY * offsetY);
        
        if (distance < minDist || distance > maxDist) 
        { 
            totalAttempts++; 
            continue; 
        }

        tryPos[0] = playerOrigin[0] + offsetX;
        tryPos[1] = playerOrigin[1] + offsetY;
        tryPos[2] = playerOrigin[2] + EXPANDED_SPAWN_HEIGHT_OFFSET;

        // PERFORMANCE FIX: Use staged validation to reduce trace operations
        int npcIndex;
        if (!ValidateSpawnPositionStaged(tryPos, playerOrigin, minDist, maxDist, groundPos, npcIndex))
        {
            totalAttempts++;
            continue;
        }
        
        // OPTION A: Enhanced spawn type logic - Pool determines intent, NPC capabilities filter selection
        bool usePoolSpawning = gCvar_UsePoolSpawning.BoolValue;
        spawnAsPortal = false; // Reset for this candidate
        
        if (usePoolSpawning)
        {
            // OPTION A: Pool system determines spawn type intent
            float portalWeight = gCvar_PortalNPCWeight.FloatValue;
            float stealthWeight = gCvar_StealthNPCWeight.FloatValue;
            float totalWeight = portalWeight + stealthWeight;
            
            if (totalWeight > 0.0)
            {
                float roll = GetRandomFloat(0.0, totalWeight);
                bool spawnIntentPortal = (roll <= portalWeight);
                
                // Re-select NPC based on spawn intent and capability
                int intentBasedNPCIndex = GetWeightedRandomNPCBySpawnType(spawnIntentPortal);
                if (intentBasedNPCIndex >= 0)
                {
                    npcIndex = intentBasedNPCIndex;
                    spawnAsPortal = spawnIntentPortal; // Force spawn type to match pool intent
                }
                else
                {
                    // Fallback: no NPCs capable of intended spawn type
                    PrintToServer("[BM] No NPCs capable of %s spawn, using original selection", spawnIntentPortal ? "portal" : "stealth");
                    // Use original NPC selection and individual portal chance
                    if (gCvar_UsePortalChance.BoolValue)
                    {
                        float individualRoll = GetRandomFloat(0.0, 1.0);
                        spawnAsPortal = (individualRoll <= g_NPCConfigs[npcIndex].portalChance);
                    }
                    else
                    {
                        bool isPortalNPC = g_NPCConfigs[npcIndex].allowPortalSpawn;
                        bool portalInSightEnabled = gCvar_PortalSpawnInSight.BoolValue;
                        spawnAsPortal = (isPortalNPC && portalInSightEnabled);
                    }
                }
            }
            else
            {
                PrintToServer("[BM] Invalid pool weights (total: %.1f), using individual portal chance", totalWeight);
                // Fallback to individual chance system
                if (gCvar_UsePortalChance.BoolValue)
                {
                    float individualRoll = GetRandomFloat(0.0, 1.0);
                    spawnAsPortal = (individualRoll <= g_NPCConfigs[npcIndex].portalChance);
                }
                else
                {
                    bool isPortalNPC = g_NPCConfigs[npcIndex].allowPortalSpawn;
                    bool portalInSightEnabled = gCvar_PortalSpawnInSight.BoolValue;
                    spawnAsPortal = (isPortalNPC && portalInSightEnabled);
                }
            }
        }
        else if (gCvar_UsePortalChance.BoolValue)
        {
            // OPTION 5: Use per-NPC portal probability
            float roll = GetRandomFloat(0.0, 1.0);
            spawnAsPortal = (roll <= g_NPCConfigs[npcIndex].portalChance);
        }
        else
        {
            // OPTION 1: Use original portal classification + in-sight toggle
            bool isPortalNPC = g_NPCConfigs[npcIndex].allowPortalSpawn;
            bool portalInSightEnabled = gCvar_PortalSpawnInSight.BoolValue;
            spawnAsPortal = (isPortalNPC && portalInSightEnabled);
        }
        
        if (spawnAsPortal)
        {
            // This spawn is intended as portal spawn - must be visible
            if (!IsPositionVisibleLOS(groundPos, npcIndex))
            {
                totalAttempts++;
                continue;
            }
        }
        else
        {
            // This spawn is intended as stealth - use existing hidden logic
            bool npcForceOutOfSight = g_NPCConfigs[npcIndex].forceOutOfSight;
            bool needsToBeHidden = tryOutOfSight || npcForceOutOfSight;
            if (needsToBeHidden && IsPositionVisibleLOS(groundPos, npcIndex))
            {
                totalAttempts++;
                continue;
            }
        }

        candidatePositions[validCandidates][0] = groundPos[0];
        candidatePositions[validCandidates][1] = groundPos[1];
        candidatePositions[validCandidates][2] = groundPos[2];
        candidateDistances[validCandidates] = distance;
        candidateNPCIndices[validCandidates] = npcIndex;
        candidateValid[validCandidates] = true;
        validCandidates++;
        
        totalAttempts++;
    }
    
    if (validCandidates == 0) 
    {
        return false; // No valid candidates found for this player
    }
    
    int selectedCandidate = SelectCandidateWithDistancePreference(candidateDistances, candidateValid, validCandidates, distancePreference, minDist, maxDist);
    
    if (selectedCandidate >= 0 && selectedCandidate < validCandidates && candidateValid[selectedCandidate])
    {
        int npcIndex = candidateNPCIndices[selectedCandidate];
        int groupSize = GetRandomInt(g_NPCConfigs[npcIndex].minGroupSize, g_NPCConfigs[npcIndex].maxGroupSize);
        
        int maxNPCs = gCvar_MaxNPCCount.IntValue;
        int currentNPCs = g_SpawnedNPCs.Length;
        
        // Option 2: Intelligent Trimming by NPC Type
        int availableSlots = maxNPCs - currentNPCs;
        int finalGroupSize = groupSize;
        bool canSpawn = false;
        
        if (groupSize <= availableSlots)
        {
            // Full group fits
            canSpawn = true;
            finalGroupSize = groupSize;
        }
        else if (availableSlots > 0)
        {
            // Need to trim group - use intelligent trimming based on NPC behavior
            int trimmedSize = GetIntelligentTrimmedGroupSize(npcIndex, groupSize, availableSlots);
            
            if (trimmedSize > 0)
            {
                canSpawn = true;
                finalGroupSize = trimmedSize;
            }
        }
        
        if (canSpawn)
        {
            // CRITICAL STABILITY FIX: Set spawn lock using new enhanced function
            SetSpawnLock("group spawn initiated");
            
            // OPTION A: Determine final spawn type - use the already-determined spawn type from visibility check
            bool needsValidation = false;
            
            if (spawnAsPortal)
            {
                // Portal spawns don't need validation (they're supposed to be visible)
                needsValidation = false;
            }
            else
            {
                // Stealth spawns may need validation based on global settings
                bool npcForceOutOfSight = g_NPCConfigs[npcIndex].forceOutOfSight;
                needsValidation = tryOutOfSight || npcForceOutOfSight;
            }
            
            if (!needsValidation)
            {
                SpawnNPCGroup(npcIndex, candidatePositions[selectedCandidate], finalGroupSize, spawnAsPortal);
                PrintToServer("[BM] Player %d: Spawning %s NPC group immediately", client, spawnAsPortal ? "portal" : "stealth");
                return true; // Spawn attempted
            }
            else
            {
                // CRITICAL STABILITY FIX: Check validation queue size before adding
                if (g_PendingSpawns.Length >= VALIDATION_QUEUE_MAX_SIZE)
                {
                    ReleaseSpawnLock("validation queue full");
                    return false; // Couldn't spawn due to queue limits
                }
                
                // Use multi-frame validation when visibility requirements are active
                PendingSpawn pendingSpawn;
                pendingSpawn.position[0] = candidatePositions[selectedCandidate][0];
                pendingSpawn.position[1] = candidatePositions[selectedCandidate][1];
                pendingSpawn.position[2] = candidatePositions[selectedCandidate][2];
                pendingSpawn.npcIndex = npcIndex;
                pendingSpawn.groupSize = finalGroupSize; // Use trimmed size
                pendingSpawn.validationFrame = g_CurrentValidationFrame;
                pendingSpawn.validationCount = 1;
                pendingSpawn.playerClient = client;
                pendingSpawn.creationTime = GetGameTime();  // CRITICAL STABILITY FIX: Track creation time
                
                g_PendingSpawns.PushArray(pendingSpawn, sizeof(pendingSpawn));
                PrintToServer("[BM] Player %d: Adding stealth NPC group to validation queue", client);
                return true; // Spawn attempted (validation pending)
            }
        }
    }
    
    return false; // No spawn attempted
}

public Action Timer_RemoveEntity(Handle timer, any ref)
{
    if (ref == INVALID_ENT_REFERENCE) return Plugin_Stop;
    
    int ent = EntRefToEntIndex(ref);
    if (ent != INVALID_ENT_REFERENCE && IsValidGameEntity(ent))
    {
        AcceptEntityInput(ent, "Kill");
    }
    return Plugin_Stop;
}

void UpdatePlayerCache()
{
    g_ValidPlayerCount = 0;
    
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            bool alive = IsPlayerAlive(client);
            g_PlayerAlive[client] = alive;
            
            if (alive)
            {
                GetClientAbsOrigin(client, g_PlayerPositions[client]);
                g_PlayerValid[client] = true;
                g_ValidPlayers[g_ValidPlayerCount++] = client;
            }
            else
            {
                g_PlayerValid[client] = false;
            }
        }
        else
        {
            g_PlayerValid[client] = false;
            g_PlayerAlive[client] = false;
        }
    }
}

int SelectCandidateWithDistancePreference(float distances[10], bool valid[10], int count, float preference, float minDist, float maxDist)
{
    if (count <= 0) return -1;
    if (count == 1) 
    {
        for (int i = 0; i < count; i++)
        {
            if (valid[i]) return i;
        }
        return -1;
    }
    
    if (preference <= 0.0)
    {
        int validIndices[10];
        int validCount = 0;
        
        for (int i = 0; i < count; i++)
        {
            if (valid[i])
            {
                validIndices[validCount] = i;
                validCount++;
            }
        }
        
        if (validCount > 0)
        {
            return validIndices[GetRandomInt(0, validCount - 1)];
        }
        return -1;
    }
    
    // DIVISION BY ZERO FIX: Runtime range adjustment
    float distanceRange = maxDist - minDist;
    if (distanceRange < 10.0) // Less than 10 units difference
    {
        float center = (maxDist + minDist) / 2.0;
        minDist = center - 5.0;
        maxDist = center + 5.0;
        distanceRange = 10.0;
        PrintToServer("[BM] Distance range too small (%.1f), adjusted to %.1f-%.1f", 
                     maxDist - minDist, minDist, maxDist);
    }
    
    float weights[10];
    float totalWeight = 0.0;
    
    for (int i = 0; i < count; i++)
    {
        if (!valid[i]) 
        {
            weights[i] = 0.0;
            continue;
        }
        
        float normalizedDistance = (distances[i] - minDist) / distanceRange;
        
        float weight = 1.0 - (normalizedDistance * preference);
        
        weight = FloatMax(weight, 0.1);
        
        weights[i] = weight;
        totalWeight += weight;
    }
    
    if (totalWeight <= 0.0)
    {
        int validIndices[10];
        int validCount = 0;
        
        for (int i = 0; i < count; i++)
        {
            if (valid[i])
            {
                validIndices[validCount] = i;
                validCount++;
            }
        }
        
        if (validCount > 0)
        {
            return validIndices[GetRandomInt(0, validCount - 1)];
        }
        return -1;
    }
    
    float choice = GetRandomFloat(0.0, totalWeight);
    float cumulative = 0.0;
    
    for (int i = 0; i < count; i++)
    {
        if (!valid[i]) continue;
        
        cumulative += weights[i];
        if (choice <= cumulative)
        {
            return i;
        }
    }
    
    for (int i = count - 1; i >= 0; i--)
    {
        if (valid[i]) return i;
    }
    
    return -1;
}

// Intelligent Group Trimming Function (Option 2)
// Returns appropriate trimmed group size based on NPC behavioral characteristics
// Returns 0 if trimming would be inappropriate for the NPC type
int GetIntelligentTrimmedGroupSize(int npcIndex, int requestedSize, int availableSlots)
{
    if (npcIndex < 0 || npcIndex >= NPC_COUNT || availableSlots <= 0)
        return 0;
    
    char classname[32];
    strcopy(classname, sizeof(classname), g_NPCConfigs[npcIndex].classname);
    int minGroupSize = g_NPCConfigs[npcIndex].minGroupSize;
    
    // Category 1: Pack/Social NPCs - require minimum group behavior
    // These NPCs lose significant effectiveness or behavioral authenticity when alone
    if (StrEqual(classname, "npc_houndeye", false))
    {
        // Houndeyes are pack hunters - their sonic attack is coordinated
        // Minimum 2 for pack behavior, but prefer 3+ if possible
        if (availableSlots >= 2)
        {
            return (availableSlots >= 3) ? 3 : 2;
        }
        return 0; // Single houndeye is not effective
    }
    else if (StrEqual(classname, "npc_snark", false))
    {
        // Snarks are pack hunters - work best in swarms
        // Will accept down to 2, but prefer more
        if (availableSlots >= 2)
        {
            return (availableSlots >= 3) ? 3 : 2;
        }
        return 0; // Single snark is too weak/unnatural
    }
    else if (StrEqual(classname, "npc_headcrab", false))
    {
        // Headcrabs can swarm - work reasonably well in pairs
        // More forgiving than other pack NPCs due to individual capability
        if (availableSlots >= 2)
        {
            return (availableSlots >= 3) ? 3 : 2;
        }
        else if (availableSlots == 1)
        {
            return 1; // Single headcrab is acceptable in some situations
        }
        return 0;
    }
    else if (StrEqual(classname, "npc_alien_slave", false))
    {
        // Alien slaves work in coordinated groups but can function solo
        // Prefer pairs but will accept singles
        if (availableSlots >= 2)
        {
            return (availableSlots >= 3) ? 3 : 2;
        }
        else if (availableSlots == 1)
        {
            return 1; // Single alien slave is viable
        }
        return 0;
    }
    else if (StrEqual(classname, "npc_human_grunt", false))
    {
        // Military units work in squads - need coordination
        // Minimum 2 for squad tactics
        if (availableSlots >= 2)
        {
            return (availableSlots >= 3) ? 3 : 2;
        }
        return 0; // Single grunt loses squad effectiveness
    }
    
    // Category 2: Solo-Capable NPCs - can work effectively alone
    // These NPCs maintain their effectiveness even when spawned individually
    else if (StrEqual(classname, "npc_bullsquid", false) ||
             StrEqual(classname, "npc_alien_controller", false) ||
             StrEqual(classname, "npc_human_grenadier", false) ||
             StrEqual(classname, "npc_human_assassin", false))
    {
        // These are naturally solitary or elite units
        // Can spawn any amount up to available slots
        return (availableSlots >= requestedSize) ? requestedSize : availableSlots;
    }
    else if (StrEqual(classname, "npc_alien_grunt", false))
    {
        // Alien grunts can work solo but are more effective in pairs
        // Flexible - can be trimmed to any size
        if (availableSlots >= 2 && requestedSize >= 2)
        {
            return (availableSlots >= requestedSize) ? requestedSize : 2;
        }
        else if (availableSlots >= 1)
        {
            return 1; // Single alien grunt is still formidable
        }
        return 0;
    }
    
    // Category 3: Undead NPCs - individuals don't coordinate much anyway
    // Zombies are reanimated individuals, so group size is less critical
    else if (StrContains(classname, "zombie", false) != -1)
    {
        // Zombies can spawn in any number - they're individual threats
        // Trim to whatever fits
        return (availableSlots >= requestedSize) ? requestedSize : availableSlots;
    }
    
    // Default fallback: respect minimum group size if possible
    // For any NPCs not explicitly categorized above
    if (availableSlots >= minGroupSize)
    {
        return (availableSlots >= requestedSize) ? requestedSize : availableSlots;
    }
    
    // If we can't meet minimum group size, reject the spawn
    return 0;
}

void SpawnNPCGroup(int npcIndex, float centerPos[3], int groupSize, bool forcePortalEffect = false)
{
    float spacing = FloatMin(g_NPCConfigs[npcIndex].groupSpacing, gCvar_MaxGroupSpacing.FloatValue);
    
    int maxNPCs = gCvar_MaxNPCCount.IntValue;
    int currentNPCs = g_SpawnedNPCs != null ? g_SpawnedNPCs.Length : 0;
    int availableSlots = maxNPCs - currentNPCs;
    
    if (availableSlots <= 0)
    {
        return;
    }
    
    if (groupSize > availableSlots)
    {
        groupSize = availableSlots;
    }
    
    // OPTION 5: Check if this spawn should use portal effects (forced override or original logic)
    bool shouldUsePortal = false;
    
    if (forcePortalEffect)
    {
        // Forced portal effect (from portal chance system)
        shouldUsePortal = gCvar_PortalEffect.BoolValue;
    }
    else
    {
        // Original logic: global toggle AND per-NPC setting
        shouldUsePortal = gCvar_PortalEffect.BoolValue && g_NPCConfigs[npcIndex].allowPortalSpawn;
    }
    
    // Pre-calculate all spawn positions for the group
    float groupPositions[10][3]; // Max reasonable group size
    int validPositions = 0;
    
    // First position is the center position
    groupPositions[validPositions][0] = centerPos[0];
    groupPositions[validPositions][1] = centerPos[1];
    groupPositions[validPositions][2] = centerPos[2];
    validPositions++;
    
    // Find positions for additional group members
    for (int i = 1; i < groupSize && validPositions < 10; i++)
    {
        float groupPos[3];
        if (FindGroupMemberPosition(centerPos, spacing, i, groupPos, npcIndex))
        {
            groupPositions[validPositions][0] = groupPos[0];
            groupPositions[validPositions][1] = groupPos[1];
            groupPositions[validPositions][2] = groupPos[2];
            validPositions++;
        }
    }
    
    // Play portal effect at group center only if this NPC type allows it
    if (shouldUsePortal)
    {
        // Calculate center point of all spawn positions
        float groupCenter[3];
        groupCenter[0] = 0.0;
        groupCenter[1] = 0.0;
        groupCenter[2] = 0.0;
        
        for (int i = 0; i < validPositions; i++)
        {
            groupCenter[0] += groupPositions[i][0];
            groupCenter[1] += groupPositions[i][1];
            groupCenter[2] += groupPositions[i][2];
        }
        
        groupCenter[0] /= float(validPositions);
        groupCenter[1] /= float(validPositions);
        groupCenter[2] /= float(validPositions);
        
        // Play single portal effect at group center
        CreateSpawnPortalEffect(groupCenter);
        PrintToServer("[BM] Portal effect created for %s group at center position", g_NPCConfigs[npcIndex].classname);
    }
    else
    {
        PrintToServer("[BM] Stealth spawn for %s group (no portal effect)", g_NPCConfigs[npcIndex].classname);
    }
    
    // Spawn all NPCs without individual portal effects
    for (int i = 0; i < validPositions; i++)
    {
        currentNPCs = g_SpawnedNPCs != null ? g_SpawnedNPCs.Length : 0;
        if (currentNPCs >= maxNPCs)
        {
            break;
        }
        
        SpawnNPCAtLocation(groupPositions[i], npcIndex, false); // false = no individual portal effect
    }
}

bool FindGroupMemberPosition(float centerPos[3], float spacing, int memberIndex, float outPos[3], int npcIndex = -1)
{
    float maxGroupRadius = GROUP_SPAWN_RADIUS;
    int maxAttempts = 12;
    
    for (int attempt = 0; attempt < maxAttempts; attempt++)
    {
        float angle = (memberIndex * 60.0 + attempt * 30.0) * (3.14159 / 180.0);
        float distance = spacing + (memberIndex * 15.0);
        
        if (distance > maxGroupRadius)
        {
            distance = spacing + GetRandomFloat(0.0, 40.0);
            angle = GetRandomFloat(0.0, 360.0) * (3.14159 / 180.0);
        }
        
        float testPos[3];
        testPos[0] = centerPos[0] + (distance * Cosine(angle));
        testPos[1] = centerPos[1] + (distance * Sine(angle));
        testPos[2] = centerPos[2] + EXPANDED_SPAWN_HEIGHT_OFFSET;
        
        if (!FindGroundBelow(testPos, outPos))
            continue;
            
        if (!HasSufficientClearanceOptimized(outPos, npcIndex))
            continue;
            
        if (!IsValidSpawnSurface(outPos))
            continue;
            
        if (!IsValidGroupPosition(outPos, spacing * 0.8, npcIndex))
            continue;
            
        return true;
    }
    
    return false;
}

bool IsValidSpawnSurface(float origin[3])
{
    if (IsOnMovingPlatform(origin))
    {
        return false;
    }
    
    if (IsOnStairs(origin))
    {
        return false;
    }
    
    return true;
}

bool IsValidGroupPosition(float pos[3], float minSpacing, int npcIndex = -1)
{
    float requiredSpacing = FloatMax(minSpacing, MIN_GROUP_SPACING);
    
    if (npcIndex >= 0 && npcIndex < NPC_COUNT)
    {
        float npcWidth = g_NPCConfigs[npcIndex].hullWidth;
        
        if (StrEqual(g_NPCConfigs[npcIndex].classname, "npc_bullsquid", false) ||
            StrEqual(g_NPCConfigs[npcIndex].classname, "npc_alien_grunt", false))
        {
            requiredSpacing *= 1.4;
        }
        else if (npcWidth >= 56.0)
        {
            requiredSpacing *= 1.2;
        }
        else if (npcWidth <= 28.0)
        {
            requiredSpacing *= 0.8;
        }
    }
    
    for (int i = 0; i < g_SpawnedNPCs.Length; i++)
    {
        int ref = g_SpawnedNPCs.Get(i);
        if (ref == INVALID_ENT_REFERENCE) continue;
        
        int ent = EntRefToEntIndex(ref);
        if (ent == INVALID_ENT_REFERENCE || !IsValidGameEntity(ent)) continue;
        
        float npcPos[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", npcPos);
        
        float distance = GetVectorDistance(pos, npcPos);
        if (distance < requiredSpacing)
        {
            return false;
        }
    }
    
    return true;
}

// FIXED: OnMapEnd with comprehensive cleanup
public void OnMapEnd()
{
    SafeKillTimer(g_SpawnTimer);
    SafeKillTimer(g_CleanupTimer);
    SafeKillTimer(g_PlayerCacheTimer);
    SafeKillTimer(g_DeathStateTimer);
    SafeKillTimer(g_SpawnLockTimer);
    SafeKillTimer(g_ValidationCleanupTimer);
    SafeKillTimer(g_EntityValidationTimer);
    SafeKillTimer(g_ValidationTimer); // FIXED: Clean up validation timer
    
    CleanupSpawnedNPCs();
    CleanupTrackingDataPacks();
}

public void OnConfigsExecuted()
{
    ValidateConVarSettings();
    UpdateNPCEnabledStates();
}

// OPTION A: Select NPC based on spawn type capability and weights
int GetWeightedRandomNPCBySpawnType(bool wantPortalCapable)
{
    float totalWeight = 0.0;
    int enabledNPCs = 0;
    
    // Calculate total weight for NPCs capable of the desired spawn type
    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (!g_NPCConfigs[i].enabled) continue;
        
        bool canDoPortal = (g_NPCConfigs[i].portalChance > 0.0);
        bool canDoStealth = (g_NPCConfigs[i].portalChance < 1.0);
        
        // Check if this NPC can do the desired spawn type
        if ((wantPortalCapable && !canDoPortal) || (!wantPortalCapable && !canDoStealth))
        {
            continue; // Skip NPCs that can't do this spawn type
        }
        
        if (g_NPCConfigs[i].weight < 0.0)
        {
            PrintToServer("[BM] Warning: Negative weight for NPC %d, setting to 0.0", i);
            g_NPCConfigs[i].weight = 0.0;
        }
        totalWeight += g_NPCConfigs[i].weight;
        enabledNPCs++;
    }

    if (totalWeight <= 0.0 || enabledNPCs == 0)
    {
        PrintToServer("[BM] No enabled NPCs capable of %s spawn with positive weight found.", wantPortalCapable ? "portal" : "stealth");
        return -1; // No suitable NPCs found
    }

    float choice = GetRandomFloat(0.0, totalWeight);
    float cumulative = 0.0;

    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (!g_NPCConfigs[i].enabled) continue;
        
        bool canDoPortal = (g_NPCConfigs[i].portalChance > 0.0);
        bool canDoStealth = (g_NPCConfigs[i].portalChance < 1.0);
        
        // Check if this NPC can do the desired spawn type
        if ((wantPortalCapable && !canDoPortal) || (!wantPortalCapable && !canDoStealth))
        {
            continue; // Skip NPCs that can't do this spawn type
        }
        
        cumulative += g_NPCConfigs[i].weight;
        if (choice <= cumulative)
        {
            return i;
        }
    }

    // Fallback: return first enabled NPC capable of desired spawn type
    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (!g_NPCConfigs[i].enabled) continue;
        
        bool canDoPortal = (g_NPCConfigs[i].portalChance > 0.0);
        bool canDoStealth = (g_NPCConfigs[i].portalChance < 1.0);
        
        if ((wantPortalCapable && canDoPortal) || (!wantPortalCapable && canDoStealth))
        {
            return i;
        }
    }
    
    return -1; // No suitable NPC found
}

// Weight-based NPC selection functions
int GetWeightedRandomNPCIndex()
{
    // Use the original all-NPCs selection as fallback
    return GetWeightedRandomNPCFromAllNPCs();
}

int GetWeightedRandomNPCFromAllNPCs()
{
    float totalWeight = 0.0;
    int enabledNPCs = 0;
    
    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (!g_NPCConfigs[i].enabled) continue;
        
        if (g_NPCConfigs[i].weight < 0.0)
        {
            PrintToServer("[BM] Warning: Negative weight for NPC %d, setting to 0.0", i);
            g_NPCConfigs[i].weight = 0.0;
        }
        totalWeight += g_NPCConfigs[i].weight;
        enabledNPCs++;
    }

    if (totalWeight <= 0.0 || enabledNPCs == 0)
    {
        PrintToServer("[BM] Warning: No enabled NPCs with positive weight found.");
        
        for (int i = 0; i < NPC_COUNT; i++)
        {
            if (g_NPCConfigs[i].enabled)
            {
                return i;
            }
        }
        
        PrintToServer("[BM] Critical: No NPCs enabled! Re-enabling Headcrabs as fallback.");
        g_NPCConfigs[2].enabled = true;
        return 2;
    }

    float choice = GetRandomFloat(0.0, totalWeight);
    float cumulative = 0.0;

    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (!g_NPCConfigs[i].enabled) continue;
        
        cumulative += g_NPCConfigs[i].weight;
        if (choice <= cumulative)
        {
            return i;
        }
    }

    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (g_NPCConfigs[i].enabled)
            return i;
    }
    
    return 0;
}

// Utility math functions
float FloatMin(float a, float b)
{
    return (a < b) ? a : b;
}

float FloatMax(float a, float b)
{
    return (a > b) ? a : b;
}

// ================================================================================
// PERFORMANCE FIX: Staged Validation System (Option 2)
// ================================================================================

// Quick position checks that don't require traces
bool QuickPositionCheck(float pos[3], float playerOrigin[3], float minDist, float maxDist)
{
    // Check distance from player (cheap calculation)
    float distance = GetVectorDistance(pos, playerOrigin);
    if (distance < minDist || distance > maxDist)
        return false;
    
    // Basic bounds checking (prevent extreme coordinates)
    if (pos[0] < -16384.0 || pos[0] > 16384.0 ||
        pos[1] < -16384.0 || pos[1] > 16384.0 ||
        pos[2] < -16384.0 || pos[2] > 16384.0)
        return false;
    
    return true;
}

// Quick water check using minimal traces
bool QuickWaterCheck(float pos[3])
{
    // Single center trace for water - much faster than full water validation
    Handle trace = TR_TraceRayFilterEx(pos, pos, CONTENTS_WATER, RayType_EndPoint, TraceEntityFilterWorld, 0);
    if (trace == INVALID_HANDLE)
    {
        return false; // Assume water if can't check (fail safe)
    }
    
    bool inWater = TR_DidHit(trace);
    SafeCloseTrace(trace);
    
    return !inWater; // Return true if NOT in water
}

// Staged validation: cheap checks first, expensive traces only if needed
bool ValidateSpawnPositionStaged(float tryPos[3], float playerOrigin[3], float minDist, float maxDist, float groundPos[3], int &npcIndex)
{
    // STAGE 1: Quick checks (no traces) - eliminates ~60% of bad positions
    if (!QuickPositionCheck(tryPos, playerOrigin, minDist, maxDist))
        return false;
    
    // STAGE 2: NPC selection (cheap) - do this before expensive traces
    npcIndex = GetWeightedRandomNPCIndex();
    if (npcIndex < 0 || npcIndex >= NPC_COUNT)
        return false;
    
    // STAGE 3: Ground trace (1 trace) - eliminates positions with no ground
    if (!FindGroundBelow(tryPos, groundPos))
        return false;
    
    // STAGE 3.5: Surface consistency validation - check surrounding terrain
    if (!IsSurfaceConsistent(tryPos))
    return false;

    // STAGE 4: Quick water check (1 trace) - eliminates obvious water positions
    if (!QuickWaterCheck(groundPos))
        return false;
    
    // STAGE 5: Full clearance validation (~8 traces) - only for positions that passed all other checks
    if (!HasSufficientClearanceOptimized(groundPos, npcIndex))
        return false;
    
    // NEW STAGE 6: Check if spawn point is inside solid geometry (Option B)
if (IsSpawnInsideSolidGeometry(groundPos, npcIndex))
	{
  	  PrintToServer("[BM] Spawn rejected: Inside solid geometry");
 	   return false;
	}

// NEW STAGE 7: Check terrain connectivity (Option D)
if (!IsSpawnOnConnectedTerrain(groundPos, playerOrigin))
	{
   	 PrintToServer("[BM] Spawn rejected: Isolated terrain");
  	  return false;
	}

return true; // All stages passed

}

bool FindGroundBelow(float vecStart[3], float vecOut[3])
{
    float vecEnd[3];
    vecEnd[0] = vecStart[0];
    vecEnd[1] = vecStart[1];
    vecEnd[2] = vecStart[2] - GROUND_TRACE_DISTANCE;

    Handle trace = TR_TraceRayFilterEx(vecStart, vecEnd, MASK_SOLID, RayType_EndPoint, TraceEntityFilterWorld, 0);
    if (trace == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create trace handle in FindGroundBelow");
        return false;
    }
    
    // Use try-finally pattern equivalent for guaranteed cleanup
    bool hitGround = TR_DidHit(trace);
    if (hitGround)
    {
        TR_GetEndPosition(vecOut, trace);
        
        float normal[3];
        TR_GetPlaneNormal(trace, normal);
        
        // ENHANCED SURFACE ANGLE VALIDATION: Reject surfaces steeper than 25 degrees
        if (normal[2] < MIN_SURFACE_NORMAL_Z)
        {
            // Calculate actual angle for logging
            float actualAngle = ArcCosine(normal[2]) * (180.0 / 3.14159);
            PrintToServer("[BM] Surface rejected: %.1f° slope (max: %.1f°) at (%.1f, %.1f, %.1f)", 
                         actualAngle, MAX_SURFACE_ANGLE_DEGREES, vecOut[0], vecOut[1], vecOut[2]);
            hitGround = false;
        }
        else
        {
            vecOut[2] += MIN_GROUND_CLEARANCE;
            
            // Optional: Log successful ground finds with angle info
            float actualAngle = ArcCosine(normal[2]) * (180.0 / 3.14159);
            PrintToServer("[BM] Valid ground found: %.1f° slope at (%.1f, %.1f, %.1f)", 
                         actualAngle, vecOut[0], vecOut[1], vecOut[2]);
        }
    }
    
    // Guaranteed cleanup
    SafeCloseTrace(trace);
    return hitGround;
}

bool IsSurfaceConsistent(float centerPos[3])
{
    float validAngles[SURFACE_CHECK_POINTS];
    int validPointCount = 0;
    float centerAngle = 0.0;
    
    // Get the center point surface angle for reference
    float centerGroundPos[3];
    if (!FindGroundBelow(centerPos, centerGroundPos))
    {
        PrintToServer("[BM] Surface consistency check failed: no center ground found");
        return false;
    }
    
    // Get center surface normal
    float testEnd[3];
    testEnd[0] = centerPos[0];
    testEnd[1] = centerPos[1]; 
    testEnd[2] = centerPos[2] - GROUND_TRACE_DISTANCE;
    
    Handle centerTrace = TR_TraceRayFilterEx(centerPos, testEnd, MASK_SOLID, RayType_EndPoint, TraceEntityFilterWorld, 0);
    if (centerTrace == INVALID_HANDLE)
    {
        PrintToServer("[BM] Surface consistency check failed: center trace failed");
        return false;
    }
    
    if (TR_DidHit(centerTrace))
    {
        float centerNormal[3];
        TR_GetPlaneNormal(centerTrace, centerNormal);
        centerAngle = ArcCosine(centerNormal[2]) * (180.0 / 3.14159);
    }
    else
    {
        SafeCloseTrace(centerTrace);
        PrintToServer("[BM] Surface consistency check failed: center trace missed");
        return false;
    }
    
    SafeCloseTrace(centerTrace);
    
    // Check surface normals at points in a circle around the spawn location
    for (int i = 0; i < SURFACE_CHECK_POINTS; i++)
    {
        float angle = (360.0 / SURFACE_CHECK_POINTS) * i * (3.14159 / 180.0);
        float checkPos[3];
        checkPos[0] = centerPos[0] + (SURFACE_CHECK_RADIUS * Cosine(angle));
        checkPos[1] = centerPos[1] + (SURFACE_CHECK_RADIUS * Sine(angle));
        checkPos[2] = centerPos[2] + 50.0; // Start above ground
        
        float checkEnd[3];
        checkEnd[0] = checkPos[0];
        checkEnd[1] = checkPos[1];
        checkEnd[2] = checkPos[2] - GROUND_TRACE_DISTANCE;
        
        Handle trace = TR_TraceRayFilterEx(checkPos, checkEnd, MASK_SOLID, RayType_EndPoint, TraceEntityFilterWorld, 0);
        if (trace == INVALID_HANDLE)
        {
            continue; // Skip this point if trace fails
        }
        
        if (TR_DidHit(trace))
        {
            float normal[3];
            TR_GetPlaneNormal(trace, normal);
            float surfaceAngle = ArcCosine(normal[2]) * (180.0 / 3.14159);
            
            // Check if this surface is within acceptable angle range
            if (normal[2] >= MIN_SURFACE_NORMAL_Z)
            {
                validAngles[validPointCount] = surfaceAngle;
                validPointCount++;
            }
            else
            {
                PrintToServer("[BM] Surface consistency: Point %d rejected (%.1f° slope)", i, surfaceAngle);
            }
        }
        
        SafeCloseTrace(trace);
    }
    
    // Check if we have enough valid points
    if (validPointCount < MIN_VALID_SURFACE_POINTS)
    {
        PrintToServer("[BM] Surface consistency failed: Only %d/%d valid points (need %d)", 
                     validPointCount, SURFACE_CHECK_POINTS, MIN_VALID_SURFACE_POINTS);
        return false;
    }
    
    // Check angle variance - ensure all points are reasonably similar to center
    float maxVariance = 0.0;
    float minAngle = centerAngle;
    float maxAngle = centerAngle;
    
    for (int i = 0; i < validPointCount; i++)
    {
        float variance = FloatAbs(validAngles[i] - centerAngle);
        if (variance > maxVariance)
        {
            maxVariance = variance;
        }
        
        if (validAngles[i] < minAngle) minAngle = validAngles[i];
        if (validAngles[i] > maxAngle) maxAngle = validAngles[i];
    }
    
    if (maxVariance > MAX_SURFACE_ANGLE_VARIANCE)
    {
        PrintToServer("[BM] Surface consistency failed: Angle variance %.1f° exceeds limit %.1f° (center: %.1f°, range: %.1f°-%.1f°)", 
                     maxVariance, MAX_SURFACE_ANGLE_VARIANCE, centerAngle, minAngle, maxAngle);
        return false;
    }
    
    PrintToServer("[BM] Surface consistency passed: %d valid points, variance %.1f°, center angle %.1f°", 
                 validPointCount, maxVariance, centerAngle);
    return true;
}


// FIXED: HasSufficientClearanceOptimized with comprehensive trace cleanup
bool HasSufficientClearanceOptimized(float origin[3], int npcIndex = -1)
{
    float hullWidth = NPC_HULL_WIDTH;
    float hullHeight = NPC_HULL_HEIGHT;
    float baseSafetyMultiplier = SAFETY_CLEARANCE_MULTIPLIER;
    
    if (npcIndex >= 0 && npcIndex < NPC_COUNT)
    {
        hullWidth = g_NPCConfigs[npcIndex].hullWidth;
        hullHeight = g_NPCConfigs[npcIndex].hullHeight;
        
        if (StrEqual(g_NPCConfigs[npcIndex].classname, "npc_bullsquid", false) ||
            StrEqual(g_NPCConfigs[npcIndex].classname, "npc_alien_grunt", false))
        {
            baseSafetyMultiplier = 1.5;
        }
        else if (hullWidth >= 56.0 || hullHeight >= 80.0)
        {
            baseSafetyMultiplier = 1.35;
        }
        else if (hullWidth <= 28.0 && hullHeight <= 40.0)
        {
            baseSafetyMultiplier = 1.05;
        }
    }
    
    hullWidth *= baseSafetyMultiplier;
    hullHeight *= baseSafetyMultiplier;
    
    // Early water check - this function handles its own traces
    if (IsPositionInWater(origin, hullWidth, hullHeight))
    {
        return false;
    }
    
    // Vertical clearance check with guaranteed cleanup
    float upPos[3];
    upPos[0] = origin[0];
    upPos[1] = origin[1];
    upPos[2] = origin[2] + hullHeight;
    
    Handle trace = TR_TraceRayFilterEx(origin, upPos, MASK_SOLID, RayType_EndPoint, TraceEntityFilterWorld, 0);
    if (trace == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create vertical trace handle in HasSufficientClearanceOptimized");
        return false;
    }
    
    bool quickCheck = !TR_DidHit(trace);
    SafeCloseTrace(trace);
    
    if (!quickCheck) return false;
    
    // Hull trace check with guaranteed cleanup
    float mins[3], maxs[3];
    mins[0] = -hullWidth/2.0;
    mins[1] = -hullWidth/2.0;
    mins[2] = 0.0;
    maxs[0] = hullWidth/2.0;
    maxs[1] = hullWidth/2.0;
    maxs[2] = hullHeight;
    
    trace = TR_TraceHullFilterEx(origin, origin, mins, maxs, MASK_SOLID, TraceEntityFilterSolid, 0);
    if (trace == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create hull trace handle in HasSufficientClearanceOptimized");
        return false;
    }
    
    bool clear = !TR_DidHit(trace);
    SafeCloseTrace(trace);
    
    if (!clear) return false;
    
    // Radial checks with guaranteed cleanup in each iteration
    int numRadialChecks = (hullWidth >= 56.0) ? 6 : 4;
    float checkRadius = hullWidth * 0.4;
    
    for (int i = 0; i < numRadialChecks; i++)
    {
        float angle = (360.0 / numRadialChecks) * i * (3.14159 / 180.0);
        float checkPos[3];
        checkPos[0] = origin[0] + (checkRadius * Cosine(angle));
        checkPos[1] = origin[1] + (checkRadius * Sine(angle));
        checkPos[2] = origin[2];
        
        float radialScale = (hullWidth >= 56.0) ? 0.25 : 0.2;
        float smallMins[3], smallMaxs[3];
        smallMins[0] = -hullWidth * radialScale;
        smallMins[1] = -hullWidth * radialScale;
        smallMins[2] = 0.0;
        smallMaxs[0] = hullWidth * radialScale;
        smallMaxs[1] = hullWidth * radialScale;
        smallMaxs[2] = hullHeight * 0.4;
        
        trace = TR_TraceHullFilterEx(checkPos, checkPos, smallMins, smallMaxs, MASK_SOLID, TraceEntityFilterSolid, 0);
        if (trace == INVALID_HANDLE)
        {
            LogError("[BM] Failed to create radial trace handle %d in HasSufficientClearanceOptimized", i);
            return false; // Fail safe - don't spawn if we can't verify clearance
        }
        
        bool radialClear = !TR_DidHit(trace);
        SafeCloseTrace(trace); // Guaranteed cleanup in loop
        
        if (!radialClear) return false;
    }
    
    return true;
}

bool IsSpawnInsideSolidGeometry(float spawnPos[3], int npcIndex)
{
    if (npcIndex < 0 || npcIndex >= NPC_COUNT)
    {
        LogError("[BM] Invalid NPC index in IsSpawnInsideSolidGeometry: %d", npcIndex);
        return true; // Fail safe - reject invalid spawns
    }
    
    float hullWidth = g_NPCConfigs[npcIndex].hullWidth + GEOMETRY_CHECK_SAFETY_MARGIN;
    float hullHeight = g_NPCConfigs[npcIndex].hullHeight + GEOMETRY_CHECK_SAFETY_MARGIN;
    
    // Define NPC hull dimensions
    float mins[3], maxs[3];
    mins[0] = -hullWidth / 2.0;
    mins[1] = -hullWidth / 2.0;
    mins[2] = 0.0;
    maxs[0] = hullWidth / 2.0;
    maxs[1] = hullWidth / 2.0;
    maxs[2] = hullHeight;
    
    // Test if hull intersects solid geometry at spawn position
    Handle trace = TR_TraceHullFilterEx(spawnPos, spawnPos, mins, maxs, 
                                       MASK_SOLID, TraceEntityFilterSolid, 0);
    if (trace == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create hull trace in IsSpawnInsideSolidGeometry");
        return true; // Fail safe - reject if we can't verify
    }
    
    bool insideGeometry = TR_DidHit(trace);
    
    // Debug logging for problem spawns
    if (insideGeometry)
    {
        int hitEntity = TR_GetEntityIndex(trace);
        float hitPos[3];
        TR_GetEndPosition(hitPos, trace);
        
        PrintToServer("[BM] Spawn inside geometry: Entity=%d, HitPos=(%.1f,%.1f,%.1f), NPC=%s", 
                     hitEntity, hitPos[0], hitPos[1], hitPos[2], g_NPCConfigs[npcIndex].classname);
        
        if (hitEntity > 0 && IsValidGameEntity(hitEntity))
        {
            char classname[64];
            GetEdictClassname(hitEntity, classname, sizeof(classname));
            PrintToServer("[BM] Hit entity class: %s", classname);
        }
    }
    
    SafeCloseTrace(trace);
    return insideGeometry;
}

bool IsSpawnOnConnectedTerrain(float spawnPos[3], float playerPos[3])
{
    // Calculate midpoint between player and spawn
    float midPoint[3];
    midPoint[0] = (playerPos[0] + spawnPos[0]) / 2.0;
    midPoint[1] = (playerPos[1] + spawnPos[1]) / 2.0;
    midPoint[2] = FloatMax(playerPos[2], spawnPos[2]) + TERRAIN_CONNECTIVITY_OFFSET;
    
    // Test if there's valid ground at the midpoint
    float groundPos[3];
    bool midpointHasGround = FindGroundBelow(midPoint, groundPos);
    
    if (!midpointHasGround)
    {
        PrintToServer("[BM] Terrain connectivity failed: No ground at midpoint (%.1f,%.1f,%.1f)", 
                     midPoint[0], midPoint[1], midPoint[2]);
        return false;
    }
    
    // Additional check: Test quarter points for better connectivity validation
    float quarterPoint1[3], quarterPoint2[3];
    
    // First quarter point (closer to player)
    quarterPoint1[0] = playerPos[0] + ((spawnPos[0] - playerPos[0]) * 0.25);
    quarterPoint1[1] = playerPos[1] + ((spawnPos[1] - playerPos[1]) * 0.25);
    quarterPoint1[2] = FloatMax(playerPos[2], spawnPos[2]) + TERRAIN_CONNECTIVITY_OFFSET;
    
    // Third quarter point (closer to spawn)
    quarterPoint2[0] = playerPos[0] + ((spawnPos[0] - playerPos[0]) * 0.75);
    quarterPoint2[1] = playerPos[1] + ((spawnPos[1] - playerPos[1]) * 0.75);
    quarterPoint2[2] = FloatMax(playerPos[2], spawnPos[2]) + TERRAIN_CONNECTIVITY_OFFSET;
    
    // Test quarter points
    float ground1[3], ground2[3];
    bool quarter1HasGround = FindGroundBelow(quarterPoint1, ground1);
    bool quarter2HasGround = FindGroundBelow(quarterPoint2, ground2);
    
    // Require at least 2 out of 3 intermediate points to have ground
    int validPoints = 0;
    if (midpointHasGround) validPoints++;
    if (quarter1HasGround) validPoints++;
    if (quarter2HasGround) validPoints++;
    
    bool connected = (validPoints >= 2);
    
    if (!connected)
    {
        PrintToServer("[BM] Terrain connectivity failed: Only %d/3 intermediate points have ground", validPoints);
        PrintToServer("[BM] Mid: %s, Q1: %s, Q2: %s", 
                     midpointHasGround ? "OK" : "FAIL",
                     quarter1HasGround ? "OK" : "FAIL", 
                     quarter2HasGround ? "OK" : "FAIL");
    }
    
    return connected;
}

// FIXED: IsPositionInWater with comprehensive trace cleanup
bool IsPositionInWater(float origin[3], float hullWidth, float hullHeight)
{
    Handle trace = INVALID_HANDLE;
    
    // Center water check with guaranteed cleanup
    float testPos[3];
    testPos[0] = origin[0];
    testPos[1] = origin[1];
    testPos[2] = origin[2] + (hullHeight * 0.5);
    
    trace = TR_TraceRayFilterEx(testPos, testPos, CONTENTS_WATER, RayType_EndPoint, TraceEntityFilterWorld, 0);
    if (trace == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create center water trace in IsPositionInWater");
        return true; // Fail safe - assume water if we can't check
    }
    
    bool isInWater = TR_DidHit(trace);
    SafeCloseTrace(trace);
    
    if (isInWater) return true;
    
    // Corner water checks with cleanup in each iteration
    float checkPositions[4][3];
    float radius = hullWidth * 0.4;
    
    for (int i = 0; i < 4; i++)
    {
        float angle = (90.0 * i) * (3.14159 / 180.0);
        checkPositions[i][0] = origin[0] + (radius * Cosine(angle));
        checkPositions[i][1] = origin[1] + (radius * Sine(angle));
        checkPositions[i][2] = origin[2] + 10.0;
        
        trace = TR_TraceRayFilterEx(checkPositions[i], checkPositions[i], CONTENTS_WATER, RayType_EndPoint, TraceEntityFilterWorld, 0);
        if (trace == INVALID_HANDLE)
        {
            LogError("[BM] Failed to create corner water trace %d in IsPositionInWater", i);
            return true; // Fail safe
        }
        
        bool cornerWater = TR_DidHit(trace);
        SafeCloseTrace(trace);
        
        if (cornerWater) return true;
    }
    
    // Hull water check with guaranteed cleanup
    float mins[3], maxs[3];
    mins[0] = -hullWidth/2.0;
    mins[1] = -hullWidth/2.0;
    mins[2] = 0.0;
    maxs[0] = hullWidth/2.0;
    maxs[1] = hullWidth/2.0;
    maxs[2] = hullHeight * 0.7;
    
    trace = TR_TraceHullFilterEx(origin, origin, mins, maxs, CONTENTS_WATER, TraceEntityFilterWorld, 0);
    if (trace == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create hull water trace in IsPositionInWater");
        return true; // Fail safe
    }
    
    bool hullInWater = TR_DidHit(trace);
    SafeCloseTrace(trace);
    
    if (hullInWater) return true;
    
    // Buffer distance checks with cleanup in each iteration
    float bufferDistance = gCvar_WaterBufferDistance.FloatValue;
    if (bufferDistance > 0.0)
    {
        for (int i = 0; i < 8; i++)
        {
            float angle = (45.0 * i) * (3.14159 / 180.0);
            float bufferPos[3];
            
            // First buffer check
            bufferPos[0] = origin[0] + (bufferDistance * Cosine(angle));
            bufferPos[1] = origin[1] + (bufferDistance * Sine(angle));
            bufferPos[2] = origin[2] + 10.0;
            
            trace = TR_TraceRayFilterEx(bufferPos, bufferPos, CONTENTS_WATER, RayType_EndPoint, TraceEntityFilterWorld, 0);
            if (trace == INVALID_HANDLE)
            {
                LogError("[BM] Failed to create buffer trace %d-1 in IsPositionInWater", i);
                return true; // Fail safe
            }
            
            bool buffer1Water = TR_DidHit(trace);
            SafeCloseTrace(trace);
            
            if (buffer1Water) return true;
            
            // Second buffer check
            bufferPos[2] = origin[2] + (hullHeight * 0.5);
            trace = TR_TraceRayFilterEx(bufferPos, bufferPos, CONTENTS_WATER, RayType_EndPoint, TraceEntityFilterWorld, 0);
            if (trace == INVALID_HANDLE)
            {
                LogError("[BM] Failed to create buffer trace %d-2 in IsPositionInWater", i);
                return true; // Fail safe
            }
            
            bool buffer2Water = TR_DidHit(trace);
            SafeCloseTrace(trace);
            
            if (buffer2Water) return true;
        }
    }
    
    return false;
}

bool IsOnStairs(float origin[3])
{
    float frontHeight, backHeight;
    float testPos[3], groundPos[3];
    
    testPos[0] = origin[0];
    testPos[1] = origin[1] + 40.0;
    testPos[2] = origin[2] + 50.0;
    if (!FindGroundBelow(testPos, groundPos))
        return false;
    frontHeight = groundPos[2];
    
    testPos[0] = origin[0];
    testPos[1] = origin[1] - 40.0;
    testPos[2] = origin[2] + 50.0;
    if (!FindGroundBelow(testPos, groundPos))
        return false;
    backHeight = groundPos[2];
    
    float heightDifference = (frontHeight > backHeight) ? (frontHeight - backHeight) : (backHeight - frontHeight);
    
    return (heightDifference > 10.0);
}

// FIXED: IsOnMovingPlatform with guaranteed trace cleanup
bool IsOnMovingPlatform(float origin[3])
{
    float traceEnd[3];
    traceEnd[0] = origin[0];
    traceEnd[1] = origin[1];
    traceEnd[2] = origin[2] - 50.0;
    
    Handle trace = TR_TraceRayFilterEx(origin, traceEnd, MASK_SOLID, RayType_EndPoint, TraceEntityFilterWorld, 0);
    if (trace == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create trace handle in IsOnMovingPlatform");
        return false; // Fail safe - assume not on moving platform
    }
    
    bool isMovingPlatform = false;
    
    if (TR_DidHit(trace))
    {
        int entity = TR_GetEntityIndex(trace);
        if (entity > 0 && IsValidGameEntity(entity))
        {
            char classname[64];
            GetEdictClassname(entity, classname, sizeof(classname));
            
            if (classname[0] == 'f' && classname[1] == 'u' && classname[2] == 'n' && classname[3] == 'c' && classname[4] == '_')
            {
                if (StrEqual(classname[5], "door", false) ||
                    StrEqual(classname[5], "train", false) ||
                    StrEqual(classname[5], "movelinear", false) ||
                    StrEqual(classname[5], "rotating", false) ||
                    StrEqual(classname[5], "tracktrain", false))
                {
                    isMovingPlatform = true;
                }
            }
            else if (StrContains(classname, "plat", false) != -1 ||
                     StrContains(classname, "elevator", false) != -1 ||
                     StrContains(classname, "lift", false) != -1)
            {
                isMovingPlatform = true;
            }
        }
    }
    
    SafeCloseTrace(trace);
    return isMovingPlatform;
}

// NPC Configuration Management
public void OnNPCEnabledChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    UpdateNPCEnabledStates();
    
    int enabledCount = 0;
    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (g_NPCConfigs[i].enabled)
            enabledCount++;
    }
    
    PrintToServer("[BM] NPC enabled states updated. %d/%d NPCs enabled for spawning.", enabledCount, NPC_COUNT);
}

void UpdateNPCEnabledStates()
{
    g_NPCConfigs[0].enabled = gCvar_EnableAlienSlave.BoolValue;
    g_NPCConfigs[1].enabled = gCvar_EnableSnark.BoolValue;
    g_NPCConfigs[2].enabled = gCvar_EnableHeadcrab.BoolValue;
    g_NPCConfigs[3].enabled = gCvar_EnableHoundeye.BoolValue;
    g_NPCConfigs[4].enabled = gCvar_EnableBullsquid.BoolValue;
    g_NPCConfigs[5].enabled = gCvar_EnableAlienGrunt.BoolValue;
    g_NPCConfigs[6].enabled = gCvar_EnableAlienController.BoolValue;
    g_NPCConfigs[7].enabled = gCvar_EnableZombieHEV.BoolValue;
    g_NPCConfigs[8].enabled = gCvar_EnableZombieScientist.BoolValue;
    g_NPCConfigs[9].enabled = gCvar_EnableZombieScientistTorso.BoolValue;
    g_NPCConfigs[10].enabled = gCvar_EnableZombieSecurity.BoolValue;
    g_NPCConfigs[11].enabled = gCvar_EnableZombieGrunt.BoolValue;
    g_NPCConfigs[12].enabled = gCvar_EnableHumanGrenadier.BoolValue;
    g_NPCConfigs[13].enabled = gCvar_EnableHumanAssassin.BoolValue;
    g_NPCConfigs[14].enabled = gCvar_EnableHumanGrunt.BoolValue;
}

// Admin Commands
public Action Command_ToggleNPC(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[BM] Usage: sm_npc_toggle <npc_classname> [0/1]");
        ReplyToCommand(client, "[BM] Available NPCs:");
        for (int i = 0; i < NPC_COUNT; i++)
        {
            ReplyToCommand(client, "  %s (%s)", g_NPCConfigs[i].classname, 
                g_NPCConfigs[i].enabled ? "Enabled" : "Disabled");
        }
        return Plugin_Handled;
    }
    
    char npcName[32], enableStr[16];
    GetCmdArg(1, npcName, sizeof(npcName));
    
    int npcIndex = -1;
    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (StrEqual(g_NPCConfigs[i].classname, npcName, false))
        {
            npcIndex = i;
            break;
        }
    }
    
    if (npcIndex == -1)
    {
        ReplyToCommand(client, "[BM] NPC '%s' not found.", npcName);
        return Plugin_Handled;
    }
    
    bool newState;
    if (args >= 2)
    {
        GetCmdArg(2, enableStr, sizeof(enableStr));
        newState = (StringToInt(enableStr) != 0);
    }
    else
    {
        newState = !g_NPCConfigs[npcIndex].enabled;
    }
    
    g_NPCConfigs[npcIndex].enabled = newState;
    
    switch(npcIndex)
    {
        case 0: gCvar_EnableAlienSlave.SetBool(newState);
        case 1: gCvar_EnableSnark.SetBool(newState);
        case 2: gCvar_EnableHeadcrab.SetBool(newState);
        case 3: gCvar_EnableHoundeye.SetBool(newState);
        case 4: gCvar_EnableBullsquid.SetBool(newState);
        case 5: gCvar_EnableAlienGrunt.SetBool(newState);
        case 6: gCvar_EnableAlienController.SetBool(newState);
        case 7: gCvar_EnableZombieHEV.SetBool(newState);
        case 8: gCvar_EnableZombieScientist.SetBool(newState);
        case 9: gCvar_EnableZombieScientistTorso.SetBool(newState);
        case 10: gCvar_EnableZombieSecurity.SetBool(newState);
        case 11: gCvar_EnableZombieGrunt.SetBool(newState);
        case 12: gCvar_EnableHumanGrenadier.SetBool(newState);
        case 13: gCvar_EnableHumanAssassin.SetBool(newState);
        case 14: gCvar_EnableHumanGrunt.SetBool(newState);
    }
    
    ReplyToCommand(client, "[BM] %s is now %s", npcName, newState ? "ENABLED" : "DISABLED");
    
    int enabledCount = 0;
    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (g_NPCConfigs[i].enabled)
            enabledCount++;
    }
    
    ReplyToCommand(client, "[BM] Total enabled NPCs: %d/%d", enabledCount, NPC_COUNT);
    
    return Plugin_Handled;
}

public Action Command_SpawnPools(int client, int args)
{
    if (args == 0)
    {
        // Show current status
        bool enabled = gCvar_UsePoolSpawning.BoolValue;
        float portalWeight = gCvar_PortalNPCWeight.FloatValue;
        float stealthWeight = gCvar_StealthNPCWeight.FloatValue;
        
        ReplyToCommand(client, "[BM] Pool Spawn Type Control: %s", enabled ? "ENABLED" : "DISABLED");
        if (enabled)
        {
            float total = portalWeight + stealthWeight;
            if (total > 0.0)
            {
                float portalPercent = (portalWeight / total) * 100.0;
                ReplyToCommand(client, "[BM] Spawn Type Distribution: Portal=%.1f (%.1f%%), Stealth=%.1f (%.1f%%)", 
                    portalWeight, portalPercent, stealthWeight, 100.0 - portalPercent);
                ReplyToCommand(client, "[BM] This controls what TYPE of spawn happens next, not which NPCs spawn");
                ReplyToCommand(client, "[BM] Any NPC capable of that spawn type can be selected");
            }
            else
            {
                ReplyToCommand(client, "[BM] Warning: Both weights are zero!");
            }
        }
        
        ReplyToCommand(client, "[BM] Usage:");
        ReplyToCommand(client, "  sm_spawn_pools enable/disable - Toggle pool spawn type control");
        ReplyToCommand(client, "  sm_spawn_pools <portal_weight> <stealth_weight> - Set type distribution");
        ReplyToCommand(client, "  sm_spawn_pools 50 50 - Equal portal/stealth distribution");
        ReplyToCommand(client, "  sm_spawn_pools 30 70 - Favor stealth spawns");
        
        return Plugin_Handled;
    }
    
    if (args == 1)
    {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));
        
        if (StrEqual(arg, "enable", false) || StrEqual(arg, "on", false))
        {
            gCvar_UsePoolSpawning.SetBool(true);
            ReplyToCommand(client, "[BM] Pool spawn type control ENABLED");
            ReplyToCommand(client, "[BM] Spawns will be distributed by type (portal vs stealth) rather than individual NPC chance");
        }
        else if (StrEqual(arg, "disable", false) || StrEqual(arg, "off", false))
        {
            gCvar_UsePoolSpawning.SetBool(false);
            ReplyToCommand(client, "[BM] Pool spawn type control DISABLED");
            ReplyToCommand(client, "[BM] Using individual NPC portal chance system");
        }
        else
        {
            ReplyToCommand(client, "[BM] Invalid argument. Use: enable, disable, or provide two weight values");
        }
        
        return Plugin_Handled;
    }
    
    if (args == 2)
    {
        char portalArg[16], stealthArg[16];
        GetCmdArg(1, portalArg, sizeof(portalArg));
        GetCmdArg(2, stealthArg, sizeof(stealthArg));
        
        float portalWeight = StringToFloat(portalArg);
        float stealthWeight = StringToFloat(stealthArg);
        
        if (portalWeight < 0.0 || stealthWeight < 0.0)
        {
            ReplyToCommand(client, "[BM] Weights must be non-negative numbers");
            return Plugin_Handled;
        }
        
        if (portalWeight == 0.0 && stealthWeight == 0.0)
        {
            ReplyToCommand(client, "[BM] At least one weight must be greater than zero");
            return Plugin_Handled;
        }
        
        gCvar_PortalNPCWeight.SetFloat(portalWeight);
        gCvar_StealthNPCWeight.SetFloat(stealthWeight);
        
        // Auto-enable pool spawning when weights are set
        if (!gCvar_UsePoolSpawning.BoolValue)
        {
            gCvar_UsePoolSpawning.SetBool(true);
            ReplyToCommand(client, "[BM] Pool spawn type control auto-enabled");
        }
        
        float total = portalWeight + stealthWeight;
        float portalPercent = (portalWeight / total) * 100.0;
        
        ReplyToCommand(client, "[BM] Spawn type distribution updated:");
        ReplyToCommand(client, "  Portal spawns: %.1f (%.1f%%)", portalWeight, portalPercent);
        ReplyToCommand(client, "  Stealth spawns: %.1f (%.1f%%)", stealthWeight, 100.0 - portalPercent);
        ReplyToCommand(client, "[BM] This affects spawn TYPE selection, not NPC selection");
        
        return Plugin_Handled;
    }
    
    ReplyToCommand(client, "[BM] Usage: sm_spawn_pools [enable/disable] or [portal_weight] [stealth_weight]");
    return Plugin_Handled;
}

// Visibility System Functions
bool IsPositionVisibleToAnyPlayer(float pos[3])
{
    if (gCvar_VisibilityMode.IntValue == 0)
    {
        return IsPositionVisibleLOS(pos);
    }
    else
    {
        return IsPositionVisibleFOV(pos);
    }
}

bool IsPositionVisibleLOS(float pos[3], int npcIndex = -1)
{
    float hullWidth = NPC_HULL_WIDTH;
    float hullHeight = NPC_HULL_HEIGHT;
    
    if (npcIndex >= 0 && npcIndex < NPC_COUNT)
    {
        hullWidth = g_NPCConfigs[npcIndex].hullWidth;
        hullHeight = g_NPCConfigs[npcIndex].hullHeight;
    }
    
    float testPoints[MAX_HULL_CHECK_POINTS][3];
    int numPoints = 0;
    
    testPoints[numPoints][0] = pos[0];
    testPoints[numPoints][1] = pos[1];
    testPoints[numPoints][2] = pos[2] + NPC_EYE_LEVEL_OFFSET;
    numPoints++;
    
    testPoints[numPoints][0] = pos[0];
    testPoints[numPoints][1] = pos[1];
    testPoints[numPoints][2] = pos[2] + hullHeight * 0.9;
    numPoints++;
    
    testPoints[numPoints][0] = pos[0];
    testPoints[numPoints][1] = pos[1];
    testPoints[numPoints][2] = pos[2] + hullHeight * 0.1;
    numPoints++;
    
    float cornerOffset = hullWidth * 0.4;
    
    if (numPoints < MAX_HULL_CHECK_POINTS)
    {
        testPoints[numPoints][0] = pos[0] - cornerOffset;
        testPoints[numPoints][1] = pos[1] - cornerOffset;
        testPoints[numPoints][2] = pos[2] + hullHeight * 0.5;
        numPoints++;
    }
    
    if (numPoints < MAX_HULL_CHECK_POINTS)
    {
        testPoints[numPoints][0] = pos[0] + cornerOffset;
        testPoints[numPoints][1] = pos[1] - cornerOffset;
        testPoints[numPoints][2] = pos[2] + hullHeight * 0.5;
        numPoints++;
    }
    
    if (numPoints < MAX_HULL_CHECK_POINTS)
    {
        testPoints[numPoints][0] = pos[0] - cornerOffset;
        testPoints[numPoints][1] = pos[1] + cornerOffset;
        testPoints[numPoints][2] = pos[2] + hullHeight * 0.5;
        numPoints++;
    }
    
    if (numPoints < MAX_HULL_CHECK_POINTS)
    {
        testPoints[numPoints][0] = pos[0] + cornerOffset;
        testPoints[numPoints][1] = pos[1] + cornerOffset;
        testPoints[numPoints][2] = pos[2] + hullHeight * 0.5;
        numPoints++;
    }
    
    if (numPoints < MAX_HULL_CHECK_POINTS)
    {
        testPoints[numPoints][0] = pos[0];
        testPoints[numPoints][1] = pos[1];
        testPoints[numPoints][2] = pos[2] + hullHeight * 0.5;
        numPoints++;
    }
    
    for (int i = 0; i < g_ValidPlayerCount; i++)
    {
        int client = g_ValidPlayers[i];
        float playerEyePos[3];
        GetClientEyePosition(client, playerEyePos);
        
        for (int point = 0; point < numPoints; point++)
        {
            if (IsLineOfSightClear(playerEyePos, testPoints[point]))
            {
                return true;
            }
        }
    }
    
    return false;
}

bool IsPositionVisibleFOV(float pos[3])
{
    float npcEyePos[3];
    npcEyePos[0] = pos[0];
    npcEyePos[1] = pos[1];
    npcEyePos[2] = pos[2] + NPC_EYE_LEVEL_OFFSET;
    
    float fovThreshold = gCvar_FOVAngle.FloatValue / 2.0;
    
    for (int i = 0; i < g_ValidPlayerCount; i++)
    {
        int client = g_ValidPlayers[i];
        float playerEyePos[3];
        GetClientEyePosition(client, playerEyePos);
        
        float playerAngles[3];
        GetClientEyeAngles(client, playerAngles);
        
        float toSpawn[3];
        SubtractVectors(npcEyePos, playerEyePos, toSpawn);
        NormalizeVector(toSpawn, toSpawn);
        
        float playerForward[3];
        GetAngleVectors(playerAngles, playerForward, NULL_VECTOR, NULL_VECTOR);
        
        float dotProduct = GetVectorDotProduct(playerForward, toSpawn);
        float angle = ArcCosine(dotProduct) * (180.0 / 3.14159);
        
        if (angle <= fovThreshold)
        {
            return true;
        }
    }
    return false;
}

// FIXED: IsLineOfSightClear with guaranteed trace cleanup
bool IsLineOfSightClear(float start[3], float end[3])
{
    Handle trace = TR_TraceRayFilterEx(start, end, MASK_SHOT, RayType_EndPoint, TraceEntityFilterTransparent, 0);
    if (trace == INVALID_HANDLE)
    {
        LogError("[BM] Failed to create trace handle in IsLineOfSightClear");
        return false; // Fail safe - assume not visible
    }
    
    bool visible = !TR_DidHit(trace);
    SafeCloseTrace(trace);
    
    return visible;
}

// Trace Filter Functions
bool IsTransparentGlass(int entity)
{
    if (!IsValidGameEntity(entity))
        return false;
        
    char classname[64];
    GetEdictClassname(entity, classname, sizeof(classname));
    
    if (StrContains(classname, "glass", false) != -1 ||
        StrContains(classname, "window", false) != -1 ||
        StrEqual(classname, "func_breakable_surf", false) ||
        StrEqual(classname, "func_breakable", false))
    {
        return true;
    }
    
    if (HasEntProp(entity, Prop_Send, "m_nRenderMode"))
    {
        int renderMode = GetEntProp(entity, Prop_Send, "m_nRenderMode");
        if (renderMode == 2 || renderMode == 5)
        {
            if (HasEntProp(entity, Prop_Send, "m_clrRender"))
            {
                int colorRender = GetEntProp(entity, Prop_Send, "m_clrRender");
                int alpha = (colorRender >> 24) & 0xFF;
                if (alpha < 255)
                {
                    return true;
                }
            }
        }
    }
    
    return false;
}

bool TraceEntityFilterTransparent(int entity, int contentsMask)
{
    if (entity == 0) return true;
    
    if (!IsValidGameEntity(entity))
        return false;

    if (entity >= 1 && entity <= MaxClients)
        return false;

    if (IsTransparentGlass(entity))
        return false;

    char classname[64];
    GetEdictClassname(entity, classname, sizeof(classname));
    
    if (StrEqual(classname, "func_wall", false) ||
        StrEqual(classname, "func_detail", false) ||
        StrEqual(classname, "func_brush", false) ||
        StrEqual(classname, "func_door", false) ||
        StrEqual(classname, "func_door_rotating", false) ||
        StrContains(classname, "prop_", false) == 0)
    {
        return true;
    }
    
    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (StrEqual(classname, g_NPCConfigs[i].classname, false))
            return false;
    }
    
    return true;
}

bool TraceEntityFilterWorld(int entity, int contentsMask)
{
    if (entity == 0) return true;
    
    if (!IsValidGameEntity(entity))
        return false;

    if (entity >= 1 && entity <= MaxClients)
        return false;

    char classname[64];
    GetEdictClassname(entity, classname, sizeof(classname));
    
    if (StrEqual(classname, "func_wall", false) ||
        StrEqual(classname, "func_detail", false) ||
        StrEqual(classname, "func_brush", false) ||
        StrEqual(classname, "func_door", false) ||
        StrEqual(classname, "func_door_rotating", false) ||
        StrContains(classname, "prop_", false) == 0)
    {
        return true;
    }
    
    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (StrEqual(classname, g_NPCConfigs[i].classname, false))
            return false;
    }
    
    return true;
}

bool TraceEntityFilterSolid(int entity, int contentsMask)
{
    // ALWAYS block world geometry (entity 0) - KEY DIFFERENCE from TraceEntityFilterWorld
    if (entity == 0) 
        return false; // Block world brushes
    
    if (!IsValidGameEntity(entity))
        return true; // Allow invalid entities to pass through
    
    // Block players
    if (entity >= 1 && entity <= MaxClients)
        return false;
    
    char classname[64];
    GetEdictClassname(entity, classname, sizeof(classname));
    
    // Block all solid level geometry entities
    if (StrEqual(classname, "func_wall", false) ||
        StrEqual(classname, "func_detail", false) ||
        StrEqual(classname, "func_brush", false) ||
        StrEqual(classname, "func_door", false) ||
        StrEqual(classname, "func_door_rotating", false) ||
        StrEqual(classname, "worldspawn", false) ||
        StrContains(classname, "prop_static", false) == 0 ||
        StrContains(classname, "prop_physics", false) == 0)
    {
        return false; // Block these solid entities
    }
    
    // Allow NPCs to pass through (don't block spawning near other NPCs)
    for (int i = 0; i < NPC_COUNT; i++)
    {
        if (StrEqual(classname, g_NPCConfigs[i].classname, false))
            return true; // Allow NPCs to pass through
    }
    
    return true; // Allow everything else to pass through
}


public void OnEntityCreated(int entity, const char[] classname)
{
    if (StrContains(classname, "npc_", false) == 0 && gCvar_NPCFacePlayer.BoolValue)
    {
        // Wait one frame for entity to be ready
        RequestFrame(QuickOrientNPC, EntIndexToEntRef(entity));
    }
}

// Frame callback function
public void QuickOrientNPC(int entityRef)
{
    int entity = EntRefToEntIndex(entityRef);
    if (entity == INVALID_ENT_REFERENCE || !IsValidGameEntity(entity))
        return;
    
    int player = FindNearestPlayer(entity);
    if (player > 0)
        OrientNPCToPlayer(entity, player);
}

// Find nearest player function
int FindNearestPlayer(int npcEntity)
{
    float npcPos[3];
    GetEntPropVector(npcEntity, Prop_Send, "m_vecOrigin", npcPos);
    
    int nearestPlayer = -1;
    float nearestDistance = 999999.0;
    
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsPlayerAlive(client))
            continue;
        
        float playerPos[3];
        GetClientAbsOrigin(client, playerPos);
        
        float distance = GetVectorDistance(npcPos, playerPos);
        if (distance < nearestDistance)
        {
            nearestDistance = distance;
            nearestPlayer = client;
        }
    }
    
    return nearestPlayer;
}

// FIXED orient function with proper SourcePawn syntax
void OrientNPCToPlayer(int npcEntity, int player)
{
    float npcPos[3], playerPos[3];
    GetEntPropVector(npcEntity, Prop_Send, "m_vecOrigin", npcPos);
    GetClientAbsOrigin(player, playerPos);
    
    // Calculate direction vector
    float direction[3];
    SubtractVectors(playerPos, npcPos, direction);
    
    // Calculate yaw angle
    float yaw = ArcTangent2(direction[1], direction[0]) * (180.0 / 3.14159);
    
    // SOURCEMOD SYNTAX: Must declare array first, then assign
    float newAngles[3];
    newAngles[0] = 0.0;    // Pitch (up/down)
    newAngles[1] = yaw;    // Yaw (left/right) - face the player
    newAngles[2] = 0.0;    // Roll (tilt)
    
    // Apply the rotation
    TeleportEntity(npcEntity, NULL_VECTOR, newAngles, NULL_VECTOR);
    
    // Debug output
    char playerName[64];
    GetClientName(player, playerName, sizeof(playerName));
    PrintToServer("[BM] NPC oriented to face %s (yaw: %.1f°)", playerName, yaw);
}

// Portal Effect Admin Commands
public Action Command_TogglePortalEffects(int client, int args)
{
    if (args >= 1)
    {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));
        bool newState = (StringToInt(arg) != 0);
        gCvar_PortalEffect.SetBool(newState);
        ReplyToCommand(client, "[BM] Portal effects %s", newState ? "ENABLED" : "DISABLED");
    }
    else
    {
        bool currentState = !gCvar_PortalEffect.BoolValue;
        gCvar_PortalEffect.SetBool(currentState);
        ReplyToCommand(client, "[BM] Portal effects %s", currentState ? "ENABLED" : "DISABLED");
    }
    
    return Plugin_Handled;
}

public Action Command_SetPortalVolume(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[BM] Usage: sm_portal_volume <0.0-1.0>");
        ReplyToCommand(client, "[BM] Current portal sound volume: %.2f", gCvar_PortalSoundVolume.FloatValue);
        return Plugin_Handled;
    }
    
    char arg[16];
    GetCmdArg(1, arg, sizeof(arg));
    float volume = StringToFloat(arg);
    
    if (volume < 0.0 || volume > 1.0)
    {
        ReplyToCommand(client, "[BM] Volume must be between 0.0 and 1.0");
        return Plugin_Handled;
    }
    
    gCvar_PortalSoundVolume.SetFloat(volume);
    ReplyToCommand(client, "[BM] Portal sound volume set to %.2f", volume);
    
    return Plugin_Handled;
}

// OPTION 1: Portal In-Sight Toggle Command
public Action Command_TogglePortalInSight(int client, int args)
{
    if (args >= 1)
    {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));
        bool newState = (StringToInt(arg) != 0);
        gCvar_PortalSpawnInSight.SetBool(newState);
        ReplyToCommand(client, "[BM] Portal in-sight spawning %s", newState ? "ENABLED" : "DISABLED");
    }
    else
    {
        bool currentState = !gCvar_PortalSpawnInSight.BoolValue;
        gCvar_PortalSpawnInSight.SetBool(currentState);
        ReplyToCommand(client, "[BM] Portal in-sight spawning %s", currentState ? "ENABLED" : "DISABLED");
    }
    
    ReplyToCommand(client, "[BM] Portal NPCs will now spawn %s", 
        gCvar_PortalSpawnInSight.BoolValue ? "in line of sight (dramatic)" : "randomly (classic)");
    
    return Plugin_Handled;
}

// OPTION 5: Portal Chance Toggle Command
public Action Command_TogglePortalChance(int client, int args)
{
    if (args >= 1)
    {
        char arg[16];
        GetCmdArg(1, arg, sizeof(arg));
        bool newState = (StringToInt(arg) != 0);
        gCvar_UsePortalChance.SetBool(newState);
        ReplyToCommand(client, "[BM] Per-NPC portal chance system %s", newState ? "ENABLED" : "DISABLED");
    }
    else
    {
        bool currentState = !gCvar_UsePortalChance.BoolValue;
        gCvar_UsePortalChance.SetBool(currentState);
        ReplyToCommand(client, "[BM] Per-NPC portal chance system %s", currentState ? "ENABLED" : "DISABLED");
    }
    
    if (gCvar_UsePortalChance.BoolValue)
    {
        ReplyToCommand(client, "[BM] NPCs will now use individual portal probabilities:");
        ReplyToCommand(client, "  Xen creatures: 50-90%% portal chance");
        ReplyToCommand(client, "  Zombies: 10-25%% portal chance");
        ReplyToCommand(client, "  Humans: 10-50%% portal chance");
        ReplyToCommand(client, "  Use sm_npc_info to see specific chances");
    }
    else
    {
        ReplyToCommand(client, "[BM] Using pool-based spawning (portal vs stealth pools)");
    }
    
    return Plugin_Handled;
}

void RegisterPortalCommands()
{
    RegAdminCmd("sm_portal_toggle", Command_TogglePortalEffects, ADMFLAG_CONFIG, "Toggle portal effects on/off");
    RegAdminCmd("sm_portal_volume", Command_SetPortalVolume, ADMFLAG_CONFIG, "Set portal sound volume");
    RegAdminCmd("sm_portal_sight", Command_TogglePortalInSight, ADMFLAG_CONFIG, "Toggle portal NPCs spawning in sight");
    RegAdminCmd("sm_portal_chance", Command_TogglePortalChance, ADMFLAG_CONFIG, "Toggle per-NPC portal probability system");
    RegAdminCmd("sm_npc_info", Command_NPCInfo, ADMFLAG_GENERIC, "Show NPC portal chance information");
}