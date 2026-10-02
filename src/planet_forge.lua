-- HD2-Addon: mods/codex/planet_forge
-- PlanetForge: put campaign enemy-template modifiers on the planets named in an external config
-- file, with an Arsenal-free edit/apply loop.
--
-- WHAT IT WRITES. The global campaign modifier table, pointer documented at game.dll + 0x346D518:
--   32 rows x 356 bytes; row = entry slots at +0 (up to five 16-byte entries,
--   {type u8 = 17 at +0, tag u32 at +4}), count u32 at +80, scope u32 at +84 (0 = planet),
--   value u32 at +88 (planet id), faction filter u32 at +92 (1 Super Earth, 2 Terminid,
--   3 Automaton, 4 Illuminate). This is the mechanism the reference mods document and it is
--   VERIFIED on this build: tag 9 (Predator Strain) on planet 215 showed up in the mission screen's
--   enemy forecast ("超级掠食者 · 强化追猎虫变种"). Note the galaxy-map screen does NOT show these
--   modifiers -- look at the mission screen / enemy forecast, or in the mission itself.
--
-- CONFIG: %APPDATA%\Arrowhead\Helldivers2\planetforge.cfg   (polled every ~2 s, no restart needed)
--
--   # comments start with #
--   planet 215 tag 9                 # one planet, one tag
--   planet 253 tag 12,24             # up to five tags stacked on one planet
--   planet 224 tag 27 filter 4       # filter defaults to the planet's live faction
--
--   * planet  : war-map planet id (1..400)
--   * tag     : campaign tag table index (0..31). Known: 9 = Predator Strain (掠食变种),
--               10 = Spore Burst (孢裂变种). The rest are identified by watching the mission
--               screen's enemy forecast for the planet you attach them to.
--   * filter  : optional; omit and the planet's current faction is used.
--
-- SAFETY. Rows are only taken from the pool of rows whose count is 0 -- an existing modifier event
-- is never overwritten. Every row we take is snapshotted first, read back after the write, and
-- rolled back on any mismatch. The table itself must be committed private read-write data of at
-- least 32 x 356 bytes. Restarting the game restores everything.
--
-- Log: %LOCALAPPDATA%\PlanetForge.log   (first line = "this line means the addon loaded")

local sr = rawget(_G, 'stingray')
if not sr then return { installed = false } end
if rawget(_G, '__PLANET_FORGE_INSTALLED') then return { installed = true } end

local ffi = require('ffi')
ffi.cdef [[
    void *GetModuleHandleA(const char *name);
    void *GetCurrentProcess(void);
    int ReadProcessMemory(void *process, const void *address, void *buffer,
                          size_t size, size_t *read);
    int WriteProcessMemory(void *process, void *address, const void *buffer,
                           size_t size, size_t *written);
    int VirtualQuery(const void *address, void *region, size_t size);
    typedef struct {
        void *base; void *allocation_base; uint32_t allocation_protection;
        uint16_t partition; uint16_t reserved; size_t size;
        uint32_t state; uint32_t protection; uint32_t type;
    } PlanetForgeRegion;
]]

local kernel = ffi.load('kernel32')
local process = kernel.GetCurrentProcess()

local RVA_GLOBALS_POINTER = 0x346D518
local RVA_BOARD_POINTER = 0x347CEE8
local CAMPAIGN_OFFSET = 1053752
local PLANET_DYNAMIC_OFFSET = 286752
local PLANET_DYNAMIC_STRIDE = 304
local PLANET_FACTION_OFFSET = 36
local PLANET_TIMER_OFFSET = 44
local PLANET_AVAILABLE_OFFSET = 48
local UNLOCK_STATE_OFFSET = 28
local UNLOCK_STATE_VALUE = 5
local TASK_TABLE_OFFSET = 1012352
local TASK_ROW_SIZE = 92
local TASK_ROW_COUNT = 110
local TASK_PLANET_OFFSET = 16
local TASK_VALID_OFFSET = 52
local ACTIVE_PLANET_OFFSET = 1548952
local HOVERED_PLANET_OFFSET = 1548956
local UNLOCK_TEMPLATE_PLANET = 215
local UNLOCK_MAX_ROWS = 12
local ROW_COUNT, ROW_SIZE = 32, 356
local TABLE_SIZE = ROW_COUNT * ROW_SIZE
local TOTAL_OFFSET, SCOPE_OFFSET, VALUE_OFFSET, FILTER_OFFSET = 80, 84, 88, 92
local ENTRY_TYPE_OFFSET, ENTRY_TAG_OFFSET = 0, 4
local ENTRY_TYPE = 17
local MAX_ENTRIES = 5
-- Read-only live export (see live_export below): where the tag hash table and the campaign modifier
-- definitions live, so the generator can be told about tags this build has that our table does not.
local RVA_TAG_TABLE = 0x21E1920
local RVA_DEFINITIONS = 0x347CD98
local DEFINITION_STRIDE = 52
local DEFINITION_COUNT_OFFSET = 53248
local TAG_TABLE_SIZE = 32
local LIVE_NAME = 'PlanetForge.live.json'
local CHECK_TICKS = 120
-- The player only hovers a planet for a moment, and one check cycle can be tens of seconds apart
-- once SmoothBoot throttles update, so the view is watched far more often: three reads, and only the
-- full work runs when the target planet actually came into view.
local VIEW_TICKS = 15
local LOG_NAME = 'PlanetForge.log'
local CFG_NAME = 'planetforge.cfg'
local base_dir = os.getenv('LOCALAPPDATA')

-- Written on first load when no config exists anywhere, so "the pack is on but nothing happens"
-- cannot happen quietly. One tag per planet: the user asked for that after the previous batch.
--
-- The version marker matters: this file is only ever written by the pack when the file on disk is
-- missing OR is a template the pack wrote earlier and the user has not edited (checked by hash in
-- PlanetForge.state). Without that, shipping a new batch could not reach a machine that already had
-- the previous one -- exactly what happened with batch 4.
local CFG_TEMPLATE_VERSION = 19
local CFG_TEMPLATE = [[
# PlanetForge generated config -- template v10 (the pack replaces this file only while untouched)
#
# Tag dictionary (all 32 confirmed in game): 0 empty | 1 敌潮部队(防守战) | 2 吐酸虫群 | 3 重甲虫群
#   4 追猎虫群 | 5 飞行虫群 | 6 轻型虫群 | 7 虫族育巢 | 8 混编虫群 | 9 掠食变种 | 10 孢裂变种
#   11 爆裂变种(掘地虫群) | 12 蟑龙启用 | 13 尖啸虫修正 | 14 突击部队 | 15 方阵部队 | 16 炮兵部队
#   17 空中编组 | 18 装甲纵队 | 19 机器人混编部队 | 20 喷气旅 | 21 生化人部队 | 22 炮艇修正
#   23 象牙军团(喷火旅) | 24 霸王虫标识 | 25 光能者残部 | 26 战争机器修正
#   27 占领者 | 28 入侵部队 | 29 无脑群氓 | 30 窃票者 | 31 超级地球支援(SEAF)
#
#   planet <id> tag <index>[,<index>...] [filter 1-4]    more than five tags spill into a new row
#   unlock <id> [faction 1-4]                            make a planet that cannot be entered attackable
#   live on|off                                          read-only export for the cfg generator
#                                                        (%LOCALAPPDATA%\PlanetForge.live.json):
#                                                        what planets and tag hashes THIS build has
#
# A variant only takes effect on missions of its own faction, so each faction's variants go on a
# planet of that faction. The Automaton side now has three variants (20 Jet Brigade, 21 Cyborg,
# 23 Ivory Legion) and they are stacked on one planet on purpose, to see whether all three hold.

# --- Terminid variants on a Terminid planet ---
planet 215 tag 9,10,11 filter 2      # PARTION: 掠食 + 孢裂 + 爆裂
# --- all three Automaton variants on one Automaton planet ---
planet 262 tag 20,21,23 filter 3     # K-ICXXVI: 喷气旅 + 生化人部队 + 喷火旅
# --- Illuminate variants on an Illuminate planet ---
planet 224 tag 27,28,29,30 filter 4  # RD-4: 占领者 + 入侵部队 + 无脑群氓 + 窃票者
# --- the three test planets the user picked (long-term unoccupied; unlocked further below) ---
planet 152 tag 20,21,23 filter 3      # DURGEN         -- Automaton variants
planet 238 tag 27,28,29,30 filter 4   # TIBIT          -- Illuminate variants
planet 235 tag 9,10,11 filter 2       # STOR THA PRIME -- Terminid variants

# --- unlock a planet that currently cannot be entered, then put modifiers on it ---
# VERIFIED 2026-10-02: planet 126 (TURING) became Terminid-controlled, enterable and it really shows
# missions. The rule that made it work: copy the source planet's WHOLE row set (a planet's rows are
# one complete operation list -- a truncated copy is discarded), and only act while the target is the
# planet in view. The row source must have the SAME faction as the target, because the rows ARE that
# planet's faction-specific operations; view an attackable planet of that faction once (215 Terminid
# / 262 Automaton / 224 Illuminate above), then select the planet being unlocked.
# `plan 125` (default) writes available + faction only; `plan 127` also zeroes the timer and sets
# state@28 (the hidden-planet plan, still unverified). Deleting a line restores that planet's record.
#
# The three test planets the user picked -- long-term unoccupied, and all three are Super Earth-held
# with available 0 right now, exactly like TURING was. Each gets its own faction's modifiers (above)
# and is unlocked to that faction.
unlock 152 faction 3                  # DURGEN         -> Automaton
unlock 238 faction 4                  # TIBIT          -> Illuminate
unlock 235 faction 2                  # STOR THA PRIME -> Terminid
unlock 126 faction 2                  # TURING (the verified case, kept as a control)
# --- the hidden-planet plan (Gosporebrust, 127 ANGEL'S VENTURE) ---
# VERIFIED 2026-10-02: with `plan 127` the planet became enterable (its record gets available=1,
# faction=2, timer=0, state@28=5). The reference deliberately writes NO task rows for it, so it had
# no missions; `rows on` extends that plan with the same row layer TURING uses (source = the lowest-id
# Terminid planet that has been viewed, i.e. 215 PARTION here).
unlock 127 faction 2 plan 127 rows on
# The mission rows and the modifier tags are two independent layers: `unlock` decides which missions
# a planet offers, `planet <id> tag ...` decides which enemy variants show up in its forecast. Planet
# 127 needs its own tag line, otherwise it only shows the game's plain modifiers.
planet 127 tag 9,10,11 filter 2
planet 126 tag 9,10 filter 2
]]

local function cfg_dirs()
    local override = rawget(_G, '__PLANET_FORGE_CFG_DIR')
    if override then return { override } end
    local list = {}
    local appdata, localappdata = os.getenv('APPDATA'), os.getenv('LOCALAPPDATA')
    if appdata then
        list[#list + 1] = appdata .. '\\Arrowhead\\Helldivers2'
        list[#list + 1] = appdata
    end
    if localappdata then list[#list + 1] = localappdata end
    return list
end

local log_state = { recent = {} }

local function log(line)
    -- One line per distinct event: the writer logs a small repeating cycle (trigger, record, source,
    -- rows) while a planet stays in view, so a ring of the last few lines is checked instead of only
    -- the previous one -- otherwise every cycle is written again and the file floods.
    for _, recent in ipairs(log_state.recent) do
        if recent == line then return end
    end
    log_state.recent[#log_state.recent + 1] = line
    if #log_state.recent > 8 then table.remove(log_state.recent, 1) end
    pcall(function()
        local dir = rawget(_G, '__PLANET_FORGE_LOG_DIR') or base_dir
        if not dir then return end
        local handle = io.open(dir .. '/' .. LOG_NAME, 'ab')
        if not handle then return end
        handle:write(tostring(line) .. '\n')
        handle:close()
    end)
end

local function hex(value)
    if value == nil then return 'nil' end
    return string.format('0x%X', value)
end

local function u32(bytes, offset)
    if not bytes or offset < 0 or offset + 4 > #bytes then return nil end
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function u32_bytes(value)
    return string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

local function read_page(address, size)
    local buffer = ffi.new('uint8_t[?]', size)
    local count = ffi.new('size_t[1]')
    local ok, result = pcall(function()
        return kernel.ReadProcessMemory(process, ffi.cast('const void *', address),
            buffer, size, count)
    end)
    if not ok or result == 0 or tonumber(count[0]) ~= size then return nil end
    return ffi.string(buffer, size)
end

local function read_span(address, size)
    if type(address) ~= 'number' or size <= 0 then return nil end
    local chunks = {}
    local cursor, remaining = address, size
    while remaining > 0 do
        local within = cursor % 4096
        local want = math.min(4096 - within, remaining)
        local part = read_page(cursor, want)
        if not part then return nil end
        chunks[#chunks + 1] = part
        cursor, remaining = cursor + want, remaining - want
    end
    return table.concat(chunks)
end

local function write_span(address, bytes)
    local buffer = ffi.new('uint8_t[?]', #bytes)
    ffi.copy(buffer, bytes, #bytes)
    local count = ffi.new('size_t[1]')
    local ok, result = pcall(function()
        return kernel.WriteProcessMemory(process, ffi.cast('void *', address),
            buffer, #bytes, count)
    end)
    return ok and result ~= 0 and tonumber(count[0]) == #bytes
end

local region = ffi.new('PlanetForgeRegion[1]')
local REGION_SIZE = ffi.sizeof(region)
local function region_at(address)
    local ok = pcall(function()
        return kernel.VirtualQuery(ffi.cast('const void *', address), region, REGION_SIZE)
    end)
    if not ok then return nil end
    local r = region[0]
    if tonumber(r.size) == 0 then return nil end
    return { base = tonumber(ffi.cast('uintptr_t', r.base)), size = tonumber(r.size),
             state = tonumber(r.state), protection = tonumber(r.protection),
             kind = tonumber(r.type) }
end

-- ------------------------------------------------------------------ config
local function read_file(path)
    local handle = io.open(path, 'rb')
    if not handle then return nil end
    local body = handle:read('*a')
    handle:close()
    return body
end

-- State of the config the pack generated: enough to tell "our old template, untouched" from
-- "the user's own file", so a new batch can reach a machine that already has the old one.
-- The checksum is weak on purpose -- it only has to notice an edit -- and the multiplier is small
-- so the product stays inside a double's exact integer range.
local STATE_NAME = 'PlanetForge.state'

local function checksum(text)
    local hash = 2166136261
    for index = 1, #text do
        hash = (hash * 131 + text:byte(index)) % 4294967296
    end
    return string.format('%d-%d', hash, #text)
end

local function state_path()
    local dir = rawget(_G, '__PLANET_FORGE_LOG_DIR') or base_dir
    if not dir then return nil end
    return dir .. '/' .. STATE_NAME
end

local function read_state()
    local path = state_path()
    if not path then return nil, nil end
    local text = read_file(path)
    if not text then return nil, nil end
    return tonumber(text:match('version=(%d+)')), text:match('hash=([^\r\n]+)')
end

local function write_state(version, hash)
    local path = state_path()
    if not path then return end
    local handle = io.open(path, 'wb')
    if not handle then return end
    handle:write(string.format('version=%d\nhash=%s\n', version, hash))
    handle:close()
end

local function parse_config(text)
    local wants, problems, notes, unlocks = {}, {}, {}, {}
    local live = true
    local order = 0
    for raw_line in tostring(text or ''):gmatch('[^\r\n]+') do
        local line = raw_line:gsub('#.*$', ''):gsub('^%s+', ''):gsub('%s+$', '')
        if line ~= '' then
            local fields = {}
            for word in line:gmatch('%S+') do fields[#fields + 1] = word end
            if fields[1] == 'live' then
                -- read-only switch for the live export (planets + tag hashes this build has); it is
                -- a diagnostic, nothing in the writing path depends on it
                live = fields[2] ~= 'off'
            elseif fields[1] == 'unlock' then
                local planet = tonumber(fields[2])
                local faction = 2
                local copy_offsets, copy_from, rows = nil, nil, nil
                local state_value, plan = nil, 125
                local source, exclude = nil, nil
                local policy = 'same'
                local index = 3
                while index <= #fields do
                    if fields[index] == 'faction' and fields[index + 1] then
                        faction = tonumber(fields[index + 1]) or 2
                        index = index + 2
                    elseif fields[index] == 'copy' and fields[index + 1] then
                        copy_offsets = {}
                        for piece in fields[index + 1]:gmatch('[^,]+') do
                            local offset = tonumber(piece)
                            if offset and offset >= 0 and offset <= 300 and offset % 4 == 0 then
                                copy_offsets[#copy_offsets + 1] = math.floor(offset)
                            else
                                problems[#problems + 1] = 'bad copy offset: ' .. piece
                            end
                        end
                        index = index + 2
                        if fields[index] == 'from' and fields[index + 1] then
                            copy_from = tonumber(fields[index + 1])
                            index = index + 2
                        else
                            problems[#problems + 1] = 'copy needs "from <planet>"'
                        end
                    elseif fields[index] == 'state' and fields[index + 1] then
                        -- The reference plan for planet 127 writes state@28 = 5 (its manifest records
                        -- the observed sequence 17 -> 9 -> 5). This override is here so that a
                        -- different value can be tried without a rebuild.
                        state_value = tonumber(fields[index + 1])
                        index = index + 2
                    elseif fields[index] == 'policy' and fields[index + 1] then
                        -- terminid (default, what the reference does) / superearth / any
                        policy = fields[index + 1]
                        index = index + 2
                    elseif fields[index] == 'source' and fields[index + 1] then
                        -- Force the row source planet (the reference's `task_source_planet`)
                        source = tonumber(fields[index + 1])
                        index = index + 2
                    elseif fields[index] == 'exclude' and fields[index + 1] then
                        -- Its `task_source_excluded_planets`; 268 is always excluded
                        exclude = {}
                        for piece in fields[index + 1]:gmatch('[^,]+') do
                            local id = tonumber(piece)
                            if id and id >= 1 and id <= 400 then
                                exclude[#exclude + 1] = math.floor(id)
                            else
                                problems[#problems + 1] = 'bad exclude planet: ' .. piece
                            end
                        end
                        index = index + 2
                    elseif fields[index] == 'plan' and fields[index + 1] then
                        -- Which reference plan to follow. The user (2026-10-02) sorted the two
                        -- apart: planet 127 (Gosporebrust) is the HIDDEN-planet case -- a planet
                        -- that is not on the map at all -- while planet 125 (GoPredator) is "on the
                        -- map but cannot be entered", which is exactly TURING. The 125 plan writes
                        -- available (plus the faction) and the task-row layer, and does NOT touch
                        -- timer/state; the 127 plan writes timer/state instead.
                        plan = fields[index + 1] == '127' and 127 or 125
                        index = index + 2
                    elseif fields[index] == 'rows' and fields[index + 1] then
                        -- Copying mission rows is the reference mod's OPTIONAL layer: its 127 plan
                        -- has task_entry_mutation=false and only the 125 plan turns it on. Off by
                        -- default, because writing rows the game does not expect is what kept the
                        -- unlocked planet showing no missions.
                        rows = fields[index + 1] == 'on'
                        index = index + 2
                    elseif fields[index] == 'template' and fields[index + 1] then
                        -- `template` used to mean "copy the whole record", which carried map position
                        -- data and moved the planet on the star map. It now means the mission-related
                        -- fields only, so an old config line cannot do harm any more.
                        copy_from = tonumber(fields[index + 1])
                        copy_offsets = { 64, 68, 72 }
                        index = index + 2
                    else
                        problems[#problems + 1] = 'unknown field: ' .. fields[index]
                        index = index + 1
                    end
                end
                if not planet or planet < 1 or planet > 400 then
                    problems[#problems + 1] = 'bad planet: ' .. tostring(fields[2])
                elseif copy_from and (copy_from < 1 or copy_from > 400) then
                    problems[#problems + 1] = 'bad copy source planet: ' .. tostring(copy_from)
                else
                    unlocks[#unlocks + 1] = { planet = math.floor(planet),
                        faction = math.floor(faction),
                        plan = plan,
                        -- the 125 plan needs the row layer; with the 127 plan it stays opt-in
                        rows = rows == nil and (plan == 125) or rows,
                        state = state_value,
                        source = source,
                        exclude = exclude,
                        policy = policy,
                        copy_offsets = copy_offsets,
                        copy_from = copy_from and math.floor(copy_from) or nil }
                end
            elseif fields[1] ~= 'planet' then
                problems[#problems + 1] = 'unknown directive: ' .. fields[1]
            else
                local planet = tonumber(fields[2])
                local tags, filter = {}, nil
                local index = 3
                while index <= #fields do
                    local key = fields[index]
                    if key == 'tag' and fields[index + 1] then
                        for value in fields[index + 1]:gmatch('[^,]+') do
                            local tag = tonumber(value)
                            if tag and tag >= 0 and tag < 32 then
                                tags[#tags + 1] = math.floor(tag)
                            else
                                problems[#problems + 1] = 'bad tag: ' .. tostring(value)
                            end
                        end
                        index = index + 2
                    elseif key == 'filter' and fields[index + 1] then
                        filter = tonumber(fields[index + 1])
                        index = index + 2
                    else
                        problems[#problems + 1] = 'unknown field: ' .. key
                        index = index + 1
                    end
                end
                if not planet or planet < 1 or planet > 400 then
                    problems[#problems + 1] = 'bad planet: ' .. tostring(fields[2])
                elseif #tags == 0 then
                    problems[#problems + 1] = 'no tag on planet ' .. planet
                else
                    -- No truncation here: a planet may carry more than five tags, and build_units
                    -- splits them across rows (five entries per row).
                    if #tags > MAX_ENTRIES * ROW_COUNT then
                        problems[#problems + 1] = 'too many tags on planet ' .. planet
                    else
                        local id = math.floor(planet)
                        local existing = nil
                        for _, want in ipairs(wants) do
                            if want.planet == id then existing = want end
                        end
                        if existing then
                            -- One line per planet: a second line for the same planet replaces the
                            -- first instead of fighting over rows.
                            notes[#notes + 1] = 'duplicate planet ' .. id .. ': the later line wins'
                            existing.tags, existing.filter = tags, filter
                        else
                            order = order + 1
                            wants[#wants + 1] = { planet = id, tags = tags, filter = filter,
                                order = order }
                        end
                    end
                end
            end
        end
    end
    return wants, problems, notes, unlocks, live
end

-- ------------------------------------------------------------------ table + board
local state = {
    phase = 'start',
    ticks = 0,
    table = nil,
    rows = {},          -- row index -> { index, address, snapshot, key, want, filter, written }
    unlocks = {},       -- configured unlock lines
    unlock_rows = {},   -- planet -> rows we wrote into the task table
    unlock_snapshots = {}, -- planet -> the record bytes as they were before we touched them
    templates = {},   -- faction -> { source = planet, rows = { immutable row copies } }
    view_signature = nil,
    cfg = nil,
    applied = 0,
    reapplied = 0,
}

local function planet_faction(planet)
    local game = kernel.GetModuleHandleA('game.dll')
    local base = game and tonumber(ffi.cast('uintptr_t', game)) or nil
    if not base then return nil end
    local pointer = read_span(base + RVA_BOARD_POINTER, 8)
    if not pointer then return nil end
    local board = u32(pointer, 0) + u32(pointer, 4) * 4294967296
    if not board or board < 0x10000 then return nil end
    local record = board + CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET + planet * PLANET_DYNAMIC_STRIDE
    local bytes = read_span(record + PLANET_FACTION_OFFSET, 4)
    return u32(bytes, 0)
end

local function build_row(want, filter)
    local row = string.rep('\0', ROW_SIZE)
    local function put(offset, bytes)
        row = row:sub(1, offset) .. bytes .. row:sub(offset + #bytes + 1)
    end
    for index, tag in ipairs(want.tags) do
        local at = (index - 1) * 16
        put(at + ENTRY_TYPE_OFFSET, string.char(ENTRY_TYPE))
        put(at + ENTRY_TAG_OFFSET, u32_bytes(tag))
    end
    put(TOTAL_OFFSET, u32_bytes(#want.tags))
    put(SCOPE_OFFSET, u32_bytes(0))
    put(VALUE_OFFSET, u32_bytes(want.planet))
    put(FILTER_OFFSET, u32_bytes(filter or 2))
    return row
end

local function row_is_ours(row, want, filter)
    if not row then return false end
    for index, tag in ipairs(want.tags) do
        local at = (index - 1) * 16
        if row:byte(at + ENTRY_TYPE_OFFSET + 1) ~= ENTRY_TYPE then return false end
        if u32(row, at + ENTRY_TAG_OFFSET) ~= tag then return false end
    end
    return u32(row, TOTAL_OFFSET) == #want.tags
        and u32(row, SCOPE_OFFSET) == 0
        and u32(row, VALUE_OFFSET) == want.planet
        and u32(row, FILTER_OFFSET) == (filter or 2)
end

local function row_count(address)
    return u32(read_span(address, ROW_SIZE), TOTAL_OFFSET)
end

local function resolve_table()
    local game = kernel.GetModuleHandleA('game.dll')
    local base = game and tonumber(ffi.cast('uintptr_t', game)) or nil
    if not base then return nil, 'game.dll not loaded' end
    local pointer = read_span(base + RVA_GLOBALS_POINTER, 8)
    if not pointer then return nil, 'modifier table pointer unreadable' end
    local table = u32(pointer, 0) + u32(pointer, 4) * 4294967296
    if not table or table < 0x10000 or table >= 0x800000000000 then
        return nil, 'implausible table pointer'
    end
    local r = region_at(table)
    if not r then return nil, 'VirtualQuery failed' end
    if not (r.state == 0x1000 and r.protection == 0x04 and r.kind == 0x20000)
        or r.size < TABLE_SIZE then
        return nil, 'target is not private read-write data of ' .. TABLE_SIZE .. ' bytes'
    end
    return table
end

-- A planet with more than MAX_ENTRIES tags needs more than one row: a row holds at most five
-- entries and the game reads each row of a planet independently, so the tags are split into
-- "units" of five and each unit gets its own row.
local function build_units(wants)
    local units = {}
    for _, want in ipairs(wants) do
        local chunk, index = 0, 1
        while index <= #want.tags do
            chunk = chunk + 1
            local tags = {}
            for position = index, math.min(index + MAX_ENTRIES - 1, #want.tags) do
                tags[#tags + 1] = want.tags[position]
            end
            index = index + MAX_ENTRIES
            units[#units + 1] = { planet = want.planet, tags = tags, chunk = chunk,
                key = want.planet .. ':' .. chunk }
        end
    end
    return units
end

-- Rebuilds the row assignment from the current config: a unit that already owns a row keeps it
-- (so a reload does not shuffle rows), and every other unit takes a row whose count is 0. Rows
-- owned by a real modifier event are never taken.
local function plan_rows(units)
    local table = state.table
    local used, plan = {}, {}
    for _, entry in ipairs(state.rows) do
        if entry.key then
            for _, unit in ipairs(units) do
                if unit.key == entry.key then
                    plan[unit.key] = entry.index
                    used[entry.index] = true
                end
            end
        end
    end
    for _, unit in ipairs(units) do
        if not plan[unit.key] then
            for index = 0, ROW_COUNT - 1 do
                if not used[index] and row_count(table + index * ROW_SIZE) == 0 then
                    plan[unit.key] = index
                    used[index] = true
                    break
                end
            end
        end
    end
    return plan
end

local function apply_plan(units, plan, filter_of)
    local active = {}
    for _, unit in ipairs(units) do
        local index = plan[unit.key]
        if index == nil then
            log(string.format('WRITE skipped planet=%d chunk=%d: no free row',
                unit.planet, unit.chunk))
        else
            active[unit.key] = true
            local address = state.table + index * ROW_SIZE
            local filter = filter_of[unit.planet]
            local snapshot = read_span(address, ROW_SIZE)
            local row = state.rows[index]
            if not row then
                row = { index = index, address = address }
                state.rows[index] = row
            end
            row.snapshot = snapshot
            if not write_span(address, build_row(unit, filter)) then
                if snapshot then write_span(address, snapshot) end
                log(string.format('WRITE aborted row=%d planet=%d: write failed, row restored',
                    index, unit.planet))
            elseif not row_is_ours(read_span(address, ROW_SIZE), unit, filter) then
                if snapshot then write_span(address, snapshot) end
                log(string.format('WRITE aborted row=%d planet=%d: read-back mismatch, '
                    .. 'row restored', index, unit.planet))
            else
                row.key, row.want, row.filter, row.written = unit.key, unit, filter, true
                state.applied = state.applied + 1
                local tags = {}
                for _, tag in ipairs(unit.tags) do tags[#tags + 1] = tostring(tag) end
                log(string.format('WRITE ok #%d row=%d planet=%d tags=%s filter=%d count=%d',
                    state.applied, index, unit.planet, table.concat(tags, ','), filter,
                    #unit.tags))
            end
        end
    end
    -- Rows whose unit is gone from the config: put the original bytes back.
    for index, row in pairs(state.rows) do
        if row.written and row.key and not active[row.key] then
            if row.snapshot then write_span(row.address, row.snapshot) end
            log(string.format('WRITE released row=%d (%s is gone from the config)', index,
                tostring(row.key)))
            row.written, row.key, row.want, row.filter = false, nil, nil, nil
        end
    end
end

-- ------------------------------------------------------------------ unlock (the second ability)
-- Makes a planet that cannot be entered attackable, the way the reference mod does it: the planet's
-- dynamic record carries the availability flag, and the local task table carries the mission rows.
-- Both are written with a snapshot, a read-back and a rollback, and only into rows that are empty.
local function board_address()
    local game = kernel.GetModuleHandleA('game.dll')
    local base = game and tonumber(ffi.cast('uintptr_t', game)) or nil
    if not base then return nil end
    local pointer = read_span(base + RVA_BOARD_POINTER, 8)
    if not pointer then return nil end
    local board = u32(pointer, 0) + u32(pointer, 4) * 4294967296
    if not board or board < 0x10000 then return nil end
    return board
end

-- Read-only A/B dump: every time the viewed planet changes, that planet's dynamic record and the
-- whole local task table are appended to our own file. Nothing in the game is written -- this is what
-- makes "what does a planet WITH missions have that the unlocked one does not" answerable offline,
-- instead of guessing at fields (the v2 board dump is from another session and lacks the unlocked
-- state). The index holds one line per snapshot: planet|record offset|table offset|sizes.
local DUMP_NAME = 'PlanetForge.dump.bin'
local DUMP_INDEX = 'PlanetForge.dump.idx'

local function any_nonzero(bytes)
    for index = 1, #bytes do
        if bytes:byte(index) ~= 0 then return true end
    end
    return false
end

-- Read-only live export: write down what THIS build currently has -- the planet dynamic records and
-- the campaign tag hash table -- so the config generator can be told about anything new (a planet
-- slot that did not exist when our tables were captured, a tag the game added) instead of trusting
-- tables from weeks ago. It never writes to the game, the whole body is pcall'd, and it cannot feed
-- back into the writing path: `live off` disables it and the writes do not depend on it.
local function live_export()
    if state.live == false then return end
    local board = board_address()
    if not board then return end
    local parts = { string.format('{"taken":"%s","planets":[', os.date('%Y-%m-%d %H:%M:%S')) }
    local first = true
    local count = 0
    for planet = 1, 400 do
        local record = read_span(board + CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
            + planet * PLANET_DYNAMIC_STRIDE, PLANET_DYNAMIC_STRIDE)
        if record and any_nonzero(record) then
            parts[#parts + 1] = string.format('%s{"id":%d,"faction":%d,"available":%d,"state":%d,'
                .. '"timer":%d}', first and '' or ',', planet, u32(record, PLANET_FACTION_OFFSET),
                u32(record, PLANET_AVAILABLE_OFFSET), u32(record, UNLOCK_STATE_OFFSET),
                u32(record, PLANET_TIMER_OFFSET))
            first = false
            count = count + 1
        end
    end
    parts[#parts + 1] = ']'
    local hashes, tags = {}, 0
    local game = kernel.GetModuleHandleA('game.dll')
    local module = game and tonumber(ffi.cast('uintptr_t', game)) or nil
    if module then
        for index = 0, TAG_TABLE_SIZE - 1 do
            local hash = u32(read_span(module + RVA_TAG_TABLE + index * 4, 4), 0)
            if hash and hash ~= 0 then
                tags = tags + 1
                hashes[#hashes + 1] = string.format('%s{"index":%d,"hash":%d}',
                    tags > 1 and ',' or '', index, hash)
            end
        end
    end
    parts[#parts + 1] = ',"tag_hashes":[' .. table.concat(hashes) .. ']'
    parts[#parts + 1] = string.format(',"tag_count":%d}\n', tags)
    local text = table.concat(parts)
    if text == state.live_text then return end        -- only write when something really changed
    state.live_text = text
    pcall(function()
        local dir = rawget(_G, '__PLANET_FORGE_LOG_DIR') or base_dir
        if not dir then return end
        local handle = io.open(dir .. '/' .. LIVE_NAME, 'wb')
        if not handle then return end
        handle:write(text)
        handle:close()
    end)
    log(string.format('LIVE export: %d planet(s), %d tag hash(es) -> %s (read-only, live off disables)',
        count, tags, LIVE_NAME))
end

local function dump_view(planet)
    if not planet or planet == 0 or planet >= 900 then return end
    state.dumped = state.dumped or {}
    if state.dumped[planet] then return end
    if state.dump_count and state.dump_count >= 40 then return end
    local board = board_address()
    if not board then return end
    local record = read_span(board + CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
        + planet * PLANET_DYNAMIC_STRIDE, PLANET_DYNAMIC_STRIDE)
    local table_bytes = read_span(board + TASK_TABLE_OFFSET, TASK_ROW_COUNT * TASK_ROW_SIZE)
    if not record or not table_bytes then return end
    state.dumped[planet] = true
    state.dump_count = (state.dump_count or 0) + 1
    pcall(function()
        local dir = rawget(_G, '__PLANET_FORGE_LOG_DIR') or base_dir
        if not dir then return end
        local bin = io.open(dir .. '/' .. DUMP_NAME, 'ab')
        local index = io.open(dir .. '/' .. DUMP_INDEX, 'ab')
        if not bin or not index then return end
        local position = bin:seek('end') or 0
        bin:write(record)
        local record_at = bin:seek('end') or position + #record
        bin:write(table_bytes)
        local table_at = bin:seek('end') or record_at + #table_bytes
        bin:close()
        index:write(string.format('planet=%d|record=%d|record_len=%d|table=%d|table_len=%d|'
            .. 'faction=%d|available=%d|state=%d|timer=%d\n', planet, record_at, #record,
            table_at, #table_bytes, u32(record, PLANET_FACTION_OFFSET),
            u32(record, PLANET_AVAILABLE_OFFSET), u32(record, UNLOCK_STATE_OFFSET),
            u32(record, PLANET_TIMER_OFFSET)))
        index:close()
    end)
    log(string.format('DUMP snapshot planet=%d (record %d B, table %d B) -- read-only',
        planet, #record, #table_bytes))
end
-- third "selected index" one) and only acts when the target is the active or hovered planet -- it
-- never writes them (its manifest has active_planet_mutation: false). The task table only ever holds
-- the viewed planet's rows, so which planet is in view decides what is captured.
local function view_planets()
    local board = board_address()
    if not board then return nil, nil, nil end
    local active = u32(read_span(board + ACTIVE_PLANET_OFFSET, 4), 0)
    local hovered = u32(read_span(board + HOVERED_PLANET_OFFSET, 4), 0)
    local next_field = u32(read_span(board + HOVERED_PLANET_OFFSET + 4, 4), 0)
    return active, hovered, next_field
end

local function log_view(target)
    local active, hovered, next_field = view_planets()
    if not active then return nil, nil end
    local signature = string.format('%s/%s/%s', tostring(active), tostring(hovered),
        tostring(next_field))
    if signature ~= state.view_signature then
        state.view_signature = signature
        log(string.format('UNLOCK view: active=%s hovered=%s next=%s (target=%s)', tostring(active),
            tostring(hovered), tostring(next_field), tostring(target)))
    end
    return active, hovered
end

-- Mission rows, step 1: scan the table the way the reference does, and never accept a row just
-- because it was found there.
--
-- Its scanner (gopred prototype at listing line 1051) reads the whole table, slices it into rows,
-- and for every row reads (a) the row's OWN planet field and (b) its validity BYTE -- only rows with
-- both are considered, rows already belonging to the target are skipped, and a configurable
-- exclusion list (its `task_source_excluded_planets`, 268 in the shipped plan) is honoured. Only then
-- does it pick ONE source planet per run and remember it together with an owner token, so a stale
-- board cannot be mistaken for live data. This does the same, keeping the rows grouped by the planet
-- each row declares.
local function row_valid_flag(address)
    local byte = read_span(address + TASK_VALID_OFFSET, 1)
    return byte and byte:byte(1) or 0
end


-- Capture ONE immutable template copy per faction (the user's design, 2026-10-02). Earlier versions
-- cached rows per source planet and re-validated them later; both ideas were fragile: the game
-- replaces the whole table with the viewed planet's rows (so a cached slot can hold unrelated data --
-- re-validating once wiped every template), and per-planet groups kept duplicates. A faction's rows
-- ARE that faction's operations, so one copy per faction is all that is needed: a Terminid target
-- copies the Terminid copy, an Automaton target the Automaton copy, and nothing gets mixed.
local function capture_templates(target, excluded, wanted_source, wanted_faction)
    local board = board_address()
    if not board then return end
    local table_base = board + TASK_TABLE_OFFSET
    local templates = state.templates or {}
    for index = 0, TASK_ROW_COUNT - 1 do
        local address = table_base + index * TASK_ROW_SIZE
        local body = read_span(address, TASK_ROW_SIZE)
        if body then
            local planet = u32(body, TASK_PLANET_OFFSET)
            local flag = row_valid_flag(address)
            if planet and planet ~= 0 and flag ~= 0 and planet ~= target
                and not excluded[planet] then
                local faction = planet_faction(planet) or 0
                local slot
                if wanted_source then
                    -- the config names the source: its rows feed the template of the target faction
                    if planet == wanted_source then
                        slot = templates[wanted_faction]
                        if not slot or slot.source ~= planet then
                            slot = { source = planet, rows = {} }
                            templates[wanted_faction] = slot
                            log(string.format('UNLOCK template: faction %d <= planet %d (named '
                                .. 'source)', wanted_faction, planet))
                        end
                    end
                elseif faction >= 1 then
                    -- first planet seen for a faction wins: one stable copy, no duplicates
                    slot = templates[faction]
                    if not slot then
                        slot = { source = planet, rows = {} }
                        templates[faction] = slot
                        log(string.format('UNLOCK template: faction %d <= planet %d (first seen)',
                            faction, planet))
                    end
                end
                if slot and slot.source == planet then
                    local known = false
                    for _, row in ipairs(slot.rows) do
                        if row.body == body then known = true end
                    end
                    if not known then slot.rows[#slot.rows + 1] = { index = index, body = body } end
                end
            end
        end
    end
    state.templates = templates
end

-- Which faction's template a target copies: its own faction by default (`policy same`), an explicitly
-- named faction for experiments, and `policy any` falls back to the target's faction first.
local FACTIONS = { terminid = 2, superearth = 1, automaton = 3, illuminate = 4 }

local function pick_template(entry)
    local templates = state.templates or {}
    local own = entry.faction or 2
    if entry.policy == 'any' then
        local slot = templates[own]
        if slot and #slot.rows > 0 then return slot, own, string.format('faction %d (same as target)', own) end
        local best
        for faction, candidate in pairs(templates) do
            if #candidate.rows > 0 and (not best or faction < best) then best = faction end
        end
        if best then
            return templates[best], best, string.format('faction %d (fallback, policy any)', best)
        end
        return nil, nil, 'no template has been captured yet'
    end
    local faction = FACTIONS[entry.policy] or tonumber(entry.policy) or own
    local slot = templates[faction]
    if slot and #slot.rows > 0 then
        return slot, faction, string.format('faction %d', faction)
    end
    return nil, faction, string.format('no faction %d template has been captured yet', faction)
end

local function apply_unlock(entry)
    local board = board_address()
    if not board then
        log('UNLOCK aborted planet=' .. entry.planet .. ': board unreadable')
        return
    end
    local record = board + CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
        + entry.planet * PLANET_DYNAMIC_STRIDE
    local snapshot = read_span(record, PLANET_DYNAMIC_STRIDE)
    if not snapshot then
        log('UNLOCK aborted planet=' .. entry.planet .. ': dynamic record unreadable')
        return
    end
    -- The four fields the availability/faction layer needs. Which of them are written depends on the
    -- plan: the 125 plan (GoPredator -- "on the map but not enterable", i.e. the TURING case) writes
    -- available and the faction only; the 127 plan (Gosporebrust -- a hidden planet) also zeroes the
    -- timer and sets state@28. Writing the 127 fields on the 125 case is very likely what kept the
    -- missions from appearing, so the two are kept apart.
    local updated = snapshot
    local patches = { { PLANET_AVAILABLE_OFFSET, 1 }, { PLANET_FACTION_OFFSET, entry.faction } }
    if entry.plan == 127 then
        patches[#patches + 1] = { PLANET_TIMER_OFFSET, 0 }
        patches[#patches + 1] = { UNLOCK_STATE_OFFSET, entry.state or UNLOCK_STATE_VALUE }
    end
    for _, patch in ipairs(patches) do
        updated = updated:sub(1, patch[1]) .. u32_bytes(patch[2]) .. updated:sub(patch[1] + 5)
    end

    -- Optional `copy <offset>[,<offset>...] from <planet>`: copy individual record fields off a
    -- planet that really offers missions. A whole-record copy is deliberately NOT offered any more:
    -- it also carries map position/identity, and in game that moved the unlocked planet onto the
    -- template's spot on the star map and swallowed its click target (2026-10-02).
    -- Offline correlation over the v2 board dump (build/_pf_field_correlation.py) found offset 68
    -- non-zero on all 38 attackable planets and on only 3 of the other 237 -- that is the field to
    -- try, with 64 and 72 as its neighbours.
    local copied_fields = {}
    if entry.copy_offsets and entry.copy_from then
        local template_record = board + CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
            + entry.copy_from * PLANET_DYNAMIC_STRIDE
        local template_bytes = read_span(template_record, PLANET_DYNAMIC_STRIDE)
        if template_bytes then
            for _, offset in ipairs(entry.copy_offsets) do
                local value = u32(template_bytes, offset)
                copied_fields[#copied_fields + 1] = string.format('+%d=%d->%d', offset,
                    u32(updated, offset), value)
                updated = updated:sub(1, offset) .. u32_bytes(value) .. updated:sub(offset + 5)
            end
        else
            log(string.format('UNLOCK note planet=%d: copy source planet %d unreadable',
                entry.planet, entry.copy_from))
        end
    end
    if not write_span(record, updated) then
        log('UNLOCK aborted planet=' .. entry.planet .. ': write failed')
        return
    end
    local back = read_span(record, PLANET_DYNAMIC_STRIDE)
    if back ~= updated then
        write_span(record, snapshot)
        log('UNLOCK aborted planet=' .. entry.planet .. ': read-back mismatch, record restored')
        return
    end
    if not state.unlock_snapshots[entry.planet] then
        state.unlock_snapshots[entry.planet] = snapshot
    end
    log(string.format('UNLOCK ok planet=%d plan=%d faction=%d->%d available=%d->1 '
        .. 'state@28=%d->%d timer@44=%d->%d (%s)', entry.planet, entry.plan,
        u32(snapshot, PLANET_FACTION_OFFSET), u32(updated, PLANET_FACTION_OFFSET),
        u32(snapshot, PLANET_AVAILABLE_OFFSET),
        u32(snapshot, UNLOCK_STATE_OFFSET), u32(updated, UNLOCK_STATE_OFFSET),
        u32(snapshot, PLANET_TIMER_OFFSET), u32(updated, PLANET_TIMER_OFFSET),
        #copied_fields > 0 and ('copied ' .. table.concat(copied_fields, ' ')) or 'own record'))

    -- Mission rows: the reference mod's optional layer (its 127 plan has task_entry_mutation=false,
    -- only the 125 plan enables it), so it only runs when the config asks for it with `rows on`.
    if entry.rows then
        local table_base = board + TASK_TABLE_OFFSET
        -- Exclusion set: the planets that must never be a template source (268 = the shattered slot
        -- whose record still says KEPLER-281b, 99 = KEPLER-361b, a special planet), whatever the line
        -- lists, and every planet we are unlocking in this session -- one target must never be used
        -- as another target's template. Kept in sync with the generator's NEVER set.
        local excluded, names = { [268] = true, [99] = true }, { '268', '99' }
        for _, id in ipairs(entry.exclude or {}) do
            excluded[id] = true
            names[#names + 1] = tostring(id)
        end
        for _, other in ipairs(state.unlocks or {}) do
            if other.planet ~= entry.planet and not excluded[other.planet] then
                excluded[other.planet] = true
                names[#names + 1] = tostring(other.planet)
            end
        end
        capture_templates(entry.planet, excluded, entry.source, entry.faction)
        local template, faction, why = pick_template(entry)
        if not template then
            log(string.format('UNLOCK task rows skipped planet=%d: %s (policy=%s) -- nothing is '
                .. 'copied', entry.planet, tostring(why), tostring(entry.policy)))
            return
        end
        local rows = template.rows
        log(string.format('UNLOCK template in use: %s, source planet=%d, %d row(s) (target=%d)',
            tostring(why), template.source, #rows, entry.planet))
        -- Rows persist. The table is the game's own per-view structure (110 rows) and a set we wrote
        -- stays there across view changes -- it only goes away when the game rebuilds the table (a
        -- finished match, a war update). So the old behaviour of clearing every other target on
        -- every fill destroyed exactly that persistence: playing one match on one target wiped the
        -- others, and filling any planet wiped the rest. Cross-faction mixing is prevented at the
        -- source instead (a target is only ever filled from a template of its own faction), and
        -- rows belonging to other targets are only given up when the planet in view actually needs
        -- the space.
        local function our_rows_for(planet)
            local found = {}
            for index = 0, TASK_ROW_COUNT - 1 do
                local address = table_base + index * TASK_ROW_SIZE
                local body = read_span(address, TASK_ROW_SIZE)
                if body and u32(body, TASK_PLANET_OFFSET) == planet
                    and row_valid_flag(address) ~= 0 then
                    found[#found + 1] = index
                end
            end
            return found
        end
        local free_slots = {}
        for index = 0, TASK_ROW_COUNT - 1 do
            if row_valid_flag(table_base + index * TASK_ROW_SIZE) == 0 then
                free_slots[#free_slots + 1] = index
            end
        end
        local existing = #our_rows_for(entry.planet)
        local active, hovered = log_view(entry.planet)
        local viewed = active == entry.planet or hovered == entry.planet
        if existing >= #rows then
            log(string.format('UNLOCK task rows planet=%d already complete (%d of %d row(s), '
                .. 'viewed=%s) -- nothing to add', entry.planet, existing, #rows, tostring(viewed)))
            return
        end
        -- Eviction is the exception, not the rule: only the planet being looked at may take rows
        -- back from other targets, and only as many as it still needs.
        local missing = #rows - existing
        local evicted = 0
        if viewed and missing > #free_slots then
            local wanted = missing - #free_slots
            for index = 0, TASK_ROW_COUNT - 1 do
                if wanted <= 0 then break end
                local address = table_base + index * TASK_ROW_SIZE
                local body = read_span(address, TASK_ROW_SIZE)
                local planet = body and u32(body, TASK_PLANET_OFFSET)
                if body and planet and planet ~= 0 and planet ~= entry.planet
                    and state.unlock_rows[planet] and row_valid_flag(address) ~= 0 then
                    local patched = body:sub(1, TASK_VALID_OFFSET) .. '\0'
                        .. body:sub(TASK_VALID_OFFSET + 2)
                    if write_span(address, patched) then
                        free_slots[#free_slots + 1] = index
                        evicted = evicted + 1
                        wanted = wanted - 1
                        state.cleared_rows = state.cleared_rows or {}
                        state.cleared_rows[#state.cleared_rows + 1] = { address = address, snapshot = body }
                    end
                end
            end
        end
        if evicted > 0 then
            log(string.format('UNLOCK evicted %d row(s) of other targets to make room for planet=%d '
                .. '(the viewed planet gets priority; the others belong to targets we wrote)',
                evicted, entry.planet))
        end
        if missing > #free_slots then
            log(string.format('UNLOCK task rows planet=%d: only %d of %d missing row(s) fit '
                .. '(viewed=%s, target keeps %d) -- view this planet again after a match to refill it',
                entry.planet, #free_slots, missing, tostring(viewed), existing))
        end
        -- Slot policy, the same as the reference (ensure_task_rows): the planet in view maps the
        -- template onto its OWN valid rows first -- so a planet that already had rows gets them
        -- replaced -- and then onto free rows. A planet nobody is looking at only fills the gaps and
        -- leaves its existing rows alone, which is what keeps several targets alive at the same time.
        local slots = viewed and our_rows_for(entry.planet) or {}
        for slot = 1, #free_slots do
            slots[#slots + 1] = free_slots[slot]
        end
        local copied, written = viewed and 0 or existing, {}
        for slot = 1, #slots do
            -- No row cap: the reference copies the WHOLE template set (`ipairs(templates)`); a
            -- planet's rows are one complete operation list, and a truncated copy is a strong
            -- candidate for being thrown away by the game. The old 12-row cap cut 30 rows to 12.
            if copied >= #rows then break end
            local destination = table_base + slots[slot] * TASK_ROW_SIZE
            local before = read_span(destination, TASK_ROW_SIZE)
            if true then
                local row_body = rows[copied + 1].body
                local patched = row_body:sub(1, TASK_PLANET_OFFSET)
                    .. u32_bytes(entry.planet) .. row_body:sub(TASK_PLANET_OFFSET + 5)
                -- the reference verifies the patched row declares the target before committing it
                if u32(patched, TASK_PLANET_OFFSET) == entry.planet
                    and write_span(destination, patched)
                    and read_span(destination, TASK_ROW_SIZE) == patched then
                    written[#written + 1] = { address = destination, snapshot = before }
                    copied = copied + 1
                elseif before then
                    write_span(destination, before)
                end
            end
        end
        -- keep every row we ever wrote for this planet so `release_stale_unlocks` can restore them
        local records = state.unlock_rows[entry.planet] or {}
        for slot = 1, #written do records[#records + 1] = written[slot] end
        state.unlock_rows[entry.planet] = records
        log(string.format('UNLOCK task rows planet=%d wrote=%d, now %d of %d row(s) (viewed=%s, '
            .. 'template faction %s, source planet %d)', entry.planet, #written,
            viewed and #written or (existing + #written), #rows, tostring(viewed),
            tostring(faction), template.source))
    end
end

-- A planet whose unlock line left the config gets its original record bytes back, and the task rows
-- we wrote for it are restored too. Dropping a line is therefore enough to undo an experiment --
-- the safety net for anything as blunt as a copied field.
local function release_stale_unlocks(configured)
    local wanted = {}
    for _, entry in ipairs(configured) do wanted[entry.planet] = true end
    for planet, snapshot in pairs(state.unlock_snapshots) do
        if not wanted[planet] then
            local board = board_address()
            if board then
                local record = board + CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
                    + planet * PLANET_DYNAMIC_STRIDE
                for _, row in ipairs(state.unlock_rows[planet] or {}) do
                    if row.snapshot then write_span(row.address, row.snapshot) end
                end
                -- rows we invalidated for other planets also get their original bytes back
                for _, row in ipairs(state.cleared_rows or {}) do
                    if row.snapshot then write_span(row.address, row.snapshot) end
                end
                state.cleared_rows = {}
                local current = read_span(record, PLANET_DYNAMIC_STRIDE)
                if current and current ~= snapshot then
                    write_span(record, snapshot)
                    log(string.format('UNLOCK released planet=%d (record restored: available=%d '
                        .. 'faction=%d)', planet, u32(snapshot, PLANET_AVAILABLE_OFFSET),
                        u32(snapshot, PLANET_FACTION_OFFSET)))
                else
                    log(string.format('UNLOCK released planet=%d (record was already original)',
                        planet))
                end
            end
            state.unlock_snapshots[planet] = nil
            state.unlock_rows[planet] = nil
        end
    end
end

-- If the game puts the planet back the way it was, do it again (and say so once). The mission rows
-- need the same treatment: selecting the unlocked planet clears the table, so the cached template
-- rows have to be written again whenever the planet has no missions.
local function watch_unlocks()
    for _, entry in ipairs(state.unlocks or {}) do
        log_view(entry.planet)
        -- Keep the per-planet picture up to date whenever a planet is on screen: rows are validated
        -- (own planet field + validity byte) before they are remembered, so a later copy never draws
        -- on a row that was never really that planet's.
        local excluded, names = { [268] = true, [99] = true }, { '268', '99' }
        for _, other in ipairs(state.unlocks or {}) do
            if not excluded[other.planet] then
                excluded[other.planet] = true
                names[#names + 1] = tostring(other.planet)
            end
        end
        capture_templates(entry.planet, excluded, entry.source, entry.faction)
        local board = board_address()
        if board then
            local record = board + CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
                + entry.planet * PLANET_DYNAMIC_STRIDE
            local bytes = read_span(record, PLANET_DYNAMIC_STRIDE)
            if bytes and (u32(bytes, PLANET_AVAILABLE_OFFSET) ~= 1
                          or u32(bytes, PLANET_FACTION_OFFSET) ~= entry.faction) then
                log(string.format('UNLOCK reapplying planet=%d (the game changed it back)',
                    entry.planet))
                apply_unlock(entry)
            else
                local table_base = board + TASK_TABLE_OFFSET
                local valid_rows = 0
                for index = 0, TASK_ROW_COUNT - 1 do
                    local body = read_span(table_base + index * TASK_ROW_SIZE, TASK_ROW_SIZE)
                    if body and u32(body, TASK_PLANET_OFFSET) == entry.planet
                        and (u32(body, TASK_VALID_OFFSET) or 0) ~= 0 then
                        valid_rows = valid_rows + 1
                    end
                end
                if valid_rows == 0 then
                    -- Per-faction template copies (state.templates) are what makes a refill possible.
                    -- This used to look at a field from before that rework (state.task_templates),
                    -- which is always nil now -- so after a match rebuilt the table the planet was
                    -- never refilled, and the "templates disappear" report was exactly that.
                    local have_template = false
                    for _, copy in pairs(state.templates or {}) do
                        if copy.rows and #copy.rows > 0 then
                            have_template = true
                            break
                        end
                    end
                    if have_template then
                        log(string.format('UNLOCK task rows reapplying planet=%d (no missions yet)',
                            entry.planet))
                        apply_unlock(entry)
                    elseif not state.task_template_warned then
                        state.task_template_warned = true
                        log('UNLOCK note: no mission rows cached yet -- select any attackable planet '
                            .. 'once (so its rows get captured), then the unlocked planet gets filled')
                    end
                end
            end
        end
    end
end

-- Finds the config (in %APPDATA%\Arrowhead\Helldivers2 first, then two fallbacks), creates a
-- template when there is none anywhere, and re-reads it. Quiet unless something actually changed:
-- the previous version logged "CFG not found" on every poll, which buried the one line that
-- mattered in 12 KB of noise.
local function poll()
    local path, existed = nil, false
    for _, dir in ipairs(cfg_dirs()) do
        local candidate = dir .. '/' .. CFG_NAME
        local handle = io.open(candidate, 'rb')
        if handle then
            handle:close()
            path, existed = candidate, true
            break
        end
    end
    if not path then
        for _, dir in ipairs(cfg_dirs()) do
            local candidate = dir .. '/' .. CFG_NAME
            local handle = io.open(candidate, 'wb')
            if handle then
                handle:write(CFG_TEMPLATE)
                handle:close()
                write_state(CFG_TEMPLATE_VERSION, checksum(CFG_TEMPLATE))
                path, existed = candidate, false
                break
            end
        end
    end
    if not path then
        if not state.cfg_unavailable then
            state.cfg_unavailable = true
            log('CFG unavailable: no writable config location -- nothing will be written')
        end
        return
    end
    if not existed and not state.cfg_created then
        state.cfg_created = true
        log('CFG created template at ' .. path .. ' -- edit it in place; changes apply within ~2 s')
    end
    local text = read_file(path)
    if not text then
        log('CFG unreadable: ' .. path)
        return
    end
    -- A config the pack generated itself and the user has not touched gets replaced when the pack
    -- ships a newer template. A file the user edited is never overwritten. The older packs left no
    -- state file, so "starts with our banner and there is no state" also counts as generated --
    -- and in every refresh the previous content is copied to <cfg>.bak first.
    local version, recorded = read_state()
    local first_line = text:match('^[^\r\n]*') or ''
    local looks_generated = first_line:find('^# PlanetForge') ~= nil
    local newer_template = (version == nil and looks_generated)
        or (version ~= nil and version < CFG_TEMPLATE_VERSION)
    if newer_template and not state.cfg_refresh_done then
        state.cfg_refresh_done = true
        local untouched = (recorded ~= nil and recorded == checksum(text))
            or (recorded == nil and looks_generated)
        if untouched then
            local backup = path .. '.bak'
            local handle = io.open(backup, 'wb')
            if handle then
                handle:write(text)
                handle:close()
            end
            handle = io.open(path, 'wb')
            if handle then
                handle:write(CFG_TEMPLATE)
                handle:close()
                write_state(CFG_TEMPLATE_VERSION, checksum(CFG_TEMPLATE))
                text = CFG_TEMPLATE
                log(string.format('CFG refreshed: template v%s -> v%d; the previous content is in %s',
                    tostring(version or 'old'), CFG_TEMPLATE_VERSION, backup))
            end
        else
            log(string.format('CFG kept: this file has been edited, so the pack left it alone '
                .. '(pack template is v%d)', CFG_TEMPLATE_VERSION))
        end
    end
    if text == state.cfg_text then return end
    local reason = state.cfg_text and 'reload' or 'loaded'
    state.cfg_text = text
    local wants, problems, notes, unlocks, live = parse_config(text)
    state.live = live
    for _, problem in ipairs(problems) do log('CFG ignored: ' .. problem) end
    for _, note in ipairs(notes) do log('CFG note: ' .. note) end
    log(string.format('CFG %s: %d line(s) accepted, %d ignored', reason, #wants, #problems))
    if #unlocks > 0 then
        log(string.format('CFG unlock line(s): %d', #unlocks))
    end
    local filter_of = {}
    for _, want in ipairs(wants) do
        -- The planet's live faction is read even when the line states one, so the log says what
        -- the board actually holds. That is how the silent fallback to 2 was found: the automatic
        -- read returned nothing on the live session, so every row (including Illuminate and
        -- Automaton planets) was written with filter 2 and showed nothing.
        local live = planet_faction(want.planet)
        local used
        if want.filter then
            used = want.filter
        elseif live and live >= 1 and live <= 4 then
            used = live
        else
            used = 2
        end
        filter_of[want.planet] = used
        log(string.format('FACTION planet=%d live=%s used=%d source=%s', want.planet,
            tostring(live), used, want.filter and 'cfg' or 'auto'))
    end
    local units = build_units(wants)
    local plan = plan_rows(units)
    apply_plan(units, plan, filter_of)
    release_stale_unlocks(unlocks)
    state.unlocks = unlocks
    for _, entry in ipairs(unlocks) do
        apply_unlock(entry)
    end
    live_export()
    log(string.format('PLANETFORGE ready: cfg=%s lines=%d ignored=%d writes_total=%d',
        path, #wants, #problems, state.applied))
end

-- ------------------------------------------------------------------ lifecycle
local previous = rawget(_G, 'update')
if type(previous) ~= 'function' then
    return { installed = false }
end

rawset(_G, '__PLANET_FORGE_INSTALLED', true)
pcall(function()
    local dir = rawget(_G, '__PLANET_FORGE_LOG_DIR') or base_dir
    if not dir then return end
    local handle = io.open(dir .. '/' .. LOG_NAME, 'wb')
    if handle then
        handle:write('planet forge installed -- this line means the addon loaded, before any '
            .. 'match (verified mechanism: tag 9 on planet 215 shows up in the mission screen\'s '
            .. 'enemy forecast)\n')
        handle:close()
    end
end)

rawset(_G, 'update', function(...)
    local results = { previous(...) }
    local ok, err = pcall(function()
        if state.phase == 'start' then
            state.phase = 'running'
            log(string.format('planet forge run %s', os.date('%Y-%m-%d %H:%M:%S')))
            local table, reason = resolve_table()
            if not table then
                state.phase = 'aborted'
                log('WRITE aborted: ' .. tostring(reason))
                return
            end
            state.table = table
            log(string.format('modifier table at %s; %d rows x %d bytes', hex(table),
                ROW_COUNT, ROW_SIZE))
            poll()
        elseif state.phase == 'running' then
            state.ticks = state.ticks + 1
            if state.ticks >= CHECK_TICKS then
                state.ticks = 0
                poll()
                watch_unlocks()
            end
            -- Fast path: the moment the player looks at a planet we are unlocking, do the work. The
            -- previous version only reacted on the slow cycle, so a brief hover was simply missed
            -- (the log showed the view arriving at the target and then nothing at all).
            state.view_ticks = (state.view_ticks or 0) + 1
            if state.view_ticks >= VIEW_TICKS then
                state.view_ticks = 0
                for _, entry in ipairs(state.unlocks or {}) do
                    local active, hovered = view_planets()
                    -- read-only snapshots of whatever is in view: this is the A/B evidence for the
                    -- unlocked planet vs a planet that really offers missions
                    dump_view(hovered)
                    dump_view(active)
                    if active == entry.planet or hovered == entry.planet then
                        log(string.format('UNLOCK triggered by view: planet=%d (you are looking at '
                            .. 'it)', entry.planet))
                        apply_unlock(entry)
                    end
                end
            end
        end
    end)
    if not ok then
        state.phase = 'failed'
        log('planet forge step failed: ' .. tostring(err))
    end
    return unpack(results)
end)

return { installed = true }
