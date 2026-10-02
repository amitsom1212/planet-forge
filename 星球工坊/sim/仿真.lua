-- Drive the PlanetForge config-driven writer (`src/planet_forge.lua`) offline.
--
--   luajit tools/sim/run_planet_forge_sim.lua        (from the workspace root)
--
-- What this has to prove, in order of how badly it would hurt to get wrong:
--
--   scenario 1  a config with three lines lands three rows, with the right tags, planet ids and
--               faction filters (the filter is read from the planet's live faction unless the
--               line overrides it), and nothing outside those rows is touched;
--   scenario 2  a row that already belongs to a real modifier event is NOT overwritten -- our
--               rows go to free rows and the existing row comes out byte-identical;
--   scenario 3  editing the config is picked up without a restart, and dropping a line gives its
--               row back (original bytes restored);
--   scenario 4  a malformed line is reported and ignored while the good lines still apply.

local real = require('ffi')
rawset(_G, '__SIM_REAL_FFI', real)

local ROOT = './'
-- ASCII only: LuaJIT's file API goes through the C runtime, which mangles a non-ASCII path on this
-- machine (it created a mojibake directory instead), so the simulation's scratch space stays ASCII.
local OUT = ROOT .. 'build/sim_planet_forge'
local ADDON = ROOT .. 'src/planet_forge.lua'

local GAME_BASE = 0x180000000
local RVA_GLOBALS_PTR = 0x346D518
local RVA_BOARD_PTR = 0x347CEE8
local TABLE_AT = 0x100000000
local BOARD_AT = 0x100800000
local TABLE_SIZE = 32 * 356
local ROW_SIZE = 356
local CAMPAIGN_OFFSET = 1053752
local PLANET_DYNAMIC_OFFSET = 286752
local PLANET_DYNAMIC_STRIDE = 304
local TASK_TABLE_OFFSET = 1012352
local TASK_ROW_SIZE = 92
local CHECK_TICKS = 120

local problems = 0
local function check(label, condition, detail)
    print(string.format('  %s %s%s', condition and 'ok  ' or 'FAIL', label,
        detail and (' -- ' .. detail) or ''))
    if not condition then problems = problems + 1 end
end

local function read_file(path)
    local handle = io.open(path, 'rb')
    if not handle then return nil end
    local body = handle:read('*a')
    handle:close()
    return body
end

local function write_file(path, text)
    local handle = io.open(path, 'wb')
    if not handle then return false end
    handle:write(text)
    handle:close()
    return true
end

local function u32le(value)
    local holder = real.new('uint32_t[1]', value)
    return real.string(real.cast('uint8_t *', holder), 4)
end

local function u64le(value)
    return u32le(value % 4294967296) .. u32le(math.floor(value / 4294967296))
end

local function blank(size) return string.rep('\0', size) end

local function poke(bytes, offset, payload)
    return bytes:sub(1, offset) .. payload .. bytes:sub(offset + #payload + 1)
end

local function u32(bytes, offset)
    if not bytes or offset + 4 > #bytes then return nil end
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

local function nonzero(bytes)
    local count = 0
    for index = 1, #bytes do
        if bytes:byte(index) ~= 0 then count = count + 1 end
    end
    return count
end

local function page_of(address) return address - (address % 4096) end

local function build_space(factions, table_prefill, viewed)
    local fake = dofile(ROOT .. 'tools/sim/fake_ffi.lua')
    local space = fake.new_space()
    space:add_module('game.dll', GAME_BASE)
    space:add(GAME_BASE, 0x1000, 0x1000, 0x02, 0x1000000, blank(0x1000))
    -- modifier table pointer
    do
        local page = page_of(GAME_BASE + RVA_GLOBALS_PTR)
        space:add(page, 0x1000, 0x1000, 0x04, 0x1000000,
            poke(blank(0x1000), GAME_BASE + RVA_GLOBALS_PTR - page, u64le(TABLE_AT)))
    end
    -- board pointer plus the planets' faction fields
    do
        local page = page_of(GAME_BASE + RVA_BOARD_PTR)
        space:add(page, 0x1000, 0x1000, 0x04, 0x1000000,
            poke(blank(0x1000), GAME_BASE + RVA_BOARD_PTR - page, u64le(BOARD_AT)))
        local size = math.max(CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET + 400 * PLANET_DYNAMIC_STRIDE,
            1548952 + 16)
        local body = blank(size)
        for planet, faction in pairs(factions or {}) do
            body = poke(body, CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
                + planet * PLANET_DYNAMIC_STRIDE + 36, u32le(faction))
        end
        -- PARTION carries the mission-related fields a working planet has, so the copy line has
        -- something to copy
        body = poke(body, CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
            + 215 * PLANET_DYNAMIC_STRIDE + 64, u32le(54))
        body = poke(body, CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
            + 215 * PLANET_DYNAMIC_STRIDE + 68, u32le(171))
        body = poke(body, CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
            + 215 * PLANET_DYNAMIC_STRIDE + 72, u32le(217))
        -- which planet the player is looking at (the reference's trigger reads active/hovered)
        body = poke(body, 1548952, u32le(viewed or 0))
        body = poke(body, 1548956, u32le(viewed or 0))
        -- four mission rows for the template planet and one live row, so the unlock has something
        -- to copy and something it must NOT overwrite
        body = poke(body, TASK_TABLE_OFFSET + 0 * TASK_ROW_SIZE + 16, u32le(215))
        body = poke(body, TASK_TABLE_OFFSET + 0 * TASK_ROW_SIZE + 52, u32le(1))
        for row = 1, 3 do
            body = poke(body, TASK_TABLE_OFFSET + row * TASK_ROW_SIZE + 16, u32le(215))
            body = poke(body, TASK_TABLE_OFFSET + row * TASK_ROW_SIZE + 24, u32le(10 + row))
            body = poke(body, TASK_TABLE_OFFSET + row * TASK_ROW_SIZE + 52, u32le(1))
        end
        body = poke(body, TASK_TABLE_OFFSET + 9 * TASK_ROW_SIZE + 16, u32le(262))
        body = poke(body, TASK_TABLE_OFFSET + 9 * TASK_ROW_SIZE + 52, u32le(1))
        -- a valid row belonging to ANOTHER unlock target: the leak fix has to invalidate it, because
        -- the game counted such leftovers as part of whichever planet was selected next
        body = poke(body, TASK_TABLE_OFFSET + 30 * TASK_ROW_SIZE + 16, u32le(152))
        body = poke(body, TASK_TABLE_OFFSET + 30 * TASK_ROW_SIZE + 52, u32le(1))
        -- a Super Earth (faction 1) planet with rows: the only kind of source the neutral policy
        -- accepts, so the copy path has a legal template
        for row = 20, 22 do
            body = poke(body, TASK_TABLE_OFFSET + row * TASK_ROW_SIZE + 16, u32le(96))
            body = poke(body, TASK_TABLE_OFFSET + row * TASK_ROW_SIZE + 24, u32le(30 + row))
            body = poke(body, TASK_TABLE_OFFSET + row * TASK_ROW_SIZE + 52, u32le(1))
        end
        space:add(BOARD_AT, size, 0x1000, 0x04, 0x20000, body)
    end
    -- the modifier table itself
    local table_body = blank(TABLE_SIZE)
    if table_prefill then
        for offset, payload in pairs(table_prefill) do
            table_body = poke(table_body, offset, payload)
        end
    end
    space:add(TABLE_AT, TABLE_SIZE, 0x1000, 0x04, 0x20000, table_body)
    return fake, space
end

local function use_space(fake, space)
    rawset(_G, '__SIM_KERNEL', fake.kernel(space))
    package.loaded['ffi'] = fake
    rawset(_G, 'stingray', {})
    rawset(_G, '__PLANET_FORGE_CFG_DIR', OUT)
    rawset(_G, '__PLANET_FORGE_LOG_DIR', OUT)
end

local function install()
    rawset(_G, '__PLANET_FORGE_INSTALLED', nil)
    rawset(_G, 'update', function() end)
    return dofile(ADDON)
end

local function tick(times)
    local last_error = nil
    for _ = 1, times do
        local ok, err = pcall(rawget(_G, 'update'), 0.25)
        if not ok then
            last_error = tostring(err)
            break
        end
    end
    return last_error
end

os.execute('mkdir "' .. OUT:gsub('/', '\\') .. '" 2>nul')
os.remove(OUT .. '/PlanetForge.log')

local function fresh_log()
    os.remove(OUT .. '/PlanetForge.log')
end

local function logged(text)
    local log = read_file(OUT .. '/PlanetForge.log') or ''
    return log:find(text, 1, true) ~= nil
end

local CFG = OUT .. '/planetforge.cfg'

-- ---------------------------------------------------------------- scenario 1: three lines land
print('=== scenario 1: three config lines -> three rows')
write_file(CFG, '# test\nplanet 215 tag 9\nplanet 253 tag 12,24\nplanet 224 tag 27 filter 4\n')
local fake, space = build_space({ [215] = 2, [253] = 3, [224] = 4 })
use_space(fake, space)
local addon = install()
check('the addon installs', type(addon) == 'table' and addon.installed == true)
local err = tick(3)
check('the ticks return cleanly', err == nil, err)

local log = read_file(OUT .. '/PlanetForge.log') or ''
check('the log opens with the self-proving install line',
    log:match('^[^\r\n]*this line means the addon loaded') ~= nil)
check('the table address is reported', log:find('modifier table at 0x', 1, true) ~= nil)
check('the config is read', log:find('CFG loaded: 3 line(s) accepted, 0 ignored', 1, true) ~= nil)
check('all three rows are written',
    logged('WRITE ok #1 row=0 planet=215 tags=9 filter=2 count=1')
    and logged('WRITE ok #2 row=1 planet=253 tags=12,24 filter=3 count=2')
    and logged('WRITE ok #3 row=2 planet=224 tags=27 filter=4 count=1'))

local row0 = space:read(TABLE_AT, ROW_SIZE)
local row1 = space:read(TABLE_AT + ROW_SIZE, ROW_SIZE)
local row2 = space:read(TABLE_AT + 2 * ROW_SIZE, ROW_SIZE)
check('row 0: type 17 and tag 9', row0:byte(1) == 17 and u32(row0, 4) == 9)
check('row 0: count 1, scope 0, planet 215, filter 2 (from the live faction)',
    u32(row0, 80) == 1 and u32(row0, 84) == 0 and u32(row0, 88) == 215 and u32(row0, 92) == 2)
check('row 1 stacks two tags', row1:byte(1) == 17 and u32(row1, 4) == 12
    and row1:byte(17) == 17 and u32(row1, 20) == 24 and u32(row1, 80) == 2)
check('row 1: planet 253, filter 3', u32(row1, 88) == 253 and u32(row1, 92) == 3)
check('row 2 honours the explicit filter', u32(row2, 4) == 27 and u32(row2, 88) == 224
    and u32(row2, 92) == 4)
local table_bytes = space:read(TABLE_AT, TABLE_SIZE)
check('only rows 0-2 were touched', nonzero(table_bytes:sub(3 * ROW_SIZE + 1)) == 0)
check('the untouched rows are still zero', nonzero(table_bytes) < 30,
    'non-zero bytes: ' .. nonzero(table_bytes))

-- ---------------------------------------------------------------- scenario 2: keep a real event
print('=== scenario 2: a row that a real event owns is never overwritten')
local prefill = {
    [80] = u32le(1),             -- row 0: count = 1 ...
    [84] = u32le(0),
    [88] = u32le(99),            -- ... for planet 99
    [92] = u32le(3),
    [4] = u32le(7),              -- ... tag 7
}
fake, space = build_space({ [215] = 2, [253] = 3, [224] = 4 }, prefill)
use_space(fake, space)
fresh_log()
local before = space:read(TABLE_AT, ROW_SIZE)
install()
err = tick(3)
check('the ticks return cleanly', err == nil, err)
check('the event row is noticed and skipped (our first row is row 1)',
    logged('WRITE ok #1 row=1 planet=215'))
local after = space:read(TABLE_AT, ROW_SIZE)
check('the event row is byte-identical afterwards', before == after)
check('the third row also moved up',
    logged('WRITE ok #3 row=3 planet=224'))

-- ---------------------------------------------------------------- scenario 3: hot reload
print('=== scenario 3: editing the config is picked up without a restart')
write_file(CFG, 'planet 215 tag 9,10\nplanet 224 tag 27 filter 4\n')
err = tick(CHECK_TICKS + 4)
check('the reload ticks return cleanly', err == nil, err)
check('the reload is logged', logged('CFG reload: 2 line(s) accepted, 0 ignored'))
check('row 1 is rewritten with both tags',
    logged('WRITE ok #4 row=1 planet=215 tags=9,10 filter=2 count=2'))
check('the dropped planet gives its row back', logged('WRITE released row=2'))
local row1 = space:read(TABLE_AT + ROW_SIZE, ROW_SIZE)
check('row 1 now carries tags 9 and 10', u32(row1, 4) == 9 and u32(row1, 20) == 10
    and u32(row1, 80) == 2)
check('the released row is all zero again',
    nonzero(space:read(TABLE_AT + 2 * ROW_SIZE, ROW_SIZE)) == 0)
check('the event row is still untouched',
    space:read(TABLE_AT, ROW_SIZE) == before)

-- ---------------------------------------------------------------- scenario 4: bad lines
print('=== scenario 4: a malformed line is reported and ignored')
write_file(CFG, 'planet 999 tag 5\nfoo bar\nplanet 253 tag 40\nplanet 249 tag 5\n'
    .. 'planet 215 tag 9\n')
fake, space = build_space({ [215] = 2, [253] = 3 })
use_space(fake, space)
fresh_log()
install()
err = tick(3)
check('the ticks return cleanly', err == nil, err)
check('the bad planet is reported', logged('CFG ignored: bad planet: 999'))
check('the unknown directive is reported', logged('CFG ignored: unknown directive: foo'))
check('the out-of-range tag is reported', logged('CFG ignored: bad tag: 40'))
check('a line whose tags were all bad is reported too',
    logged('CFG ignored: no tag on planet 253'))
check('only the good lines are accepted (and applied)',
    logged('CFG loaded: 2 line(s) accepted, 4 ignored')
    and logged('WRITE ok #1 row=0 planet=249 tags=5 filter=2 count=1')
    and logged('WRITE ok #2 row=1 planet=215 tags=9 filter=2 count=1'))
check('the faction read is reported for every planet, so a silent fallback cannot hide',
    logged('FACTION planet=249 live=0 used=2 source=auto')
    and logged('FACTION planet=215 live=2 used=2 source=auto'))

-- ------------------------------------------- scenario 5: no config anywhere -> template created
print('=== scenario 5: no config file at all -> the pack creates the template itself')
os.remove(CFG)
fake, space = build_space({ [215] = 2, [100] = 2, [253] = 3, [262] = 3, [70] = 3, [114] = 3,
    [224] = 4, [225] = 4, [90] = 4, [79] = 2, [259] = 2, [261] = 3, [126] = 1, [96] = 1,
    [152] = 3 }, nil, 126)
use_space(fake, space)
fresh_log()
install()
err = tick(3)
check('the ticks return cleanly', err == nil, err)
check('the template creation is announced',
    read_file(OUT .. '/PlanetForge.log'):find('CFG created template at ', 1, true) ~= nil)
local template = read_file(CFG)
check('the template file now exists and is a config', template ~= nil
    and template:find('planet 215 tag 9', 1, true) ~= nil)
check('the template lines are applied',
    logged('CFG loaded: 8 line(s) accepted, 0 ignored'))
check('the unlock line is reported', logged('CFG unlock line(s): 5'))
check('each faction keeps its own variants on its own planet',
    logged('WRITE ok #1 row=0 planet=215 tags=9,10,11 filter=2 count=3')
    and logged('WRITE ok #2 row=1 planet=262 tags=20,21,23 filter=3 count=3')
    and logged('WRITE ok #3 row=2 planet=224 tags=27,28,29,30 filter=4 count=4')
    and logged('WRITE ok #4 row=3 planet=152 tags=20,21,23 filter=3 count=3')
    and logged('WRITE ok #5 row=4 planet=238 tags=27,28,29,30 filter=4 count=4')
    and logged('WRITE ok #6 row=5 planet=235 tags=9,10,11 filter=2 count=3'))
check('the hidden planet gets its own tag line as well',
    logged('WRITE ok #7 row=6 planet=127 tags=9,10,11 filter=2 count=3'))
check('the planet to unlock gets its modifiers too',
    logged('WRITE ok #8 row=7 planet=126 tags=9,10 filter=2 count=2'))
-- persistence: another target's leftover rows are KEPT (cross-faction mixing is prevented at the
-- source by the per-faction templates, and clearing them on every fill is what used to wipe the
-- other planets the moment you played a match and looked somewhere else)
check('rows of another unlock target are left alone',
    not logged('UNLOCK cleared') and not logged('UNLOCK evicted'))
local foreign_row = space:read(BOARD_AT + TASK_TABLE_OFFSET + 30 * TASK_ROW_SIZE, TASK_ROW_SIZE)
check('the other target row stays valid (persistence)', foreign_row:byte(53) ~= 0,
    'valid byte = ' .. tostring(foreign_row:byte(53)))
check('the dynamic record is unlocked and the change is reported',
    logged('UNLOCK ok planet=126 plan=125 faction=1->2 available=0->1'))
check('the unlock writes only its own record fields',
    logged('(own record)') and not logged('(copied'))
-- the 125 plan is the one that enables the task-row layer, so rows ARE written here
check('one immutable template copy is kept per faction',
    logged('UNLOCK template: faction 2 <= planet 215 (first seen)')
    and logged('UNLOCK template: faction 3 <= planet 262 (first seen)')
    and logged('UNLOCK template: faction 1 <= planet 96 (first seen)'))
check('a target uses the template of its own faction',
    logged('UNLOCK template in use: faction 2, source planet=215, 4 row(s) (target=126)'))
check('the 125 plan brings its mission rows with it',
    logged('UNLOCK task rows planet=126 wrote=4, now 4 of 4 row(s) (viewed=true, template faction 2, '
        .. 'source planet 215)'))
local rows_for_126 = 0
for index = 0, 30 do
    local row = space:read(BOARD_AT + TASK_TABLE_OFFSET + index * TASK_ROW_SIZE, TASK_ROW_SIZE)
    if u32(row, 16) == 126 then rows_for_126 = rows_for_126 + 1 end
end
check('every copied row really declares the target planet', rows_for_126 == 4,
    'found ' .. rows_for_126)
check('the 125 plan leaves timer and state alone',
    logged('state@28=0->0') and logged('timer@44=0->0'))
check('the ready line names the config path and the write count',
    logged('PLANETFORGE ready: cfg=') and logged('writes_total=8'))
-- the unlocked planet really is available now, and the template planet's rows are untouched
local record = space:read(BOARD_AT + CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
    + 126 * PLANET_DYNAMIC_STRIDE, PLANET_DYNAMIC_STRIDE)
check('the unlocked record says faction 2 and is available',
    u32(record, 36) == 2 and u32(record, 48) == 1)
check('the template planet keeps its own rows (nothing was overwritten in place)',
    u32(space:read(BOARD_AT + TASK_TABLE_OFFSET + 9 * TASK_ROW_SIZE, TASK_ROW_SIZE), 16) == 262)
-- the fast path: a brief hover has to be enough, and repeats must not flood the log
fresh_log()
err = tick(64)
local view_text = read_file(OUT .. '/PlanetForge.log') or ''
local _, unlock_lines = view_text:gsub('UNLOCK ok planet=126', '')
check('looking at the target runs the work on the short cycle',
    view_text:find('UNLOCK triggered by view: planet=126', 1, true) ~= nil)
-- the first re-apply differs (the record just changed), every later one is byte-identical and is
-- suppressed, so four cycles must not produce four lines
check('identical repeats are written once, not every cycle', unlock_lines <= 1,
    'found ' .. unlock_lines .. ' over ~4 cycles')
-- `policy any` is the experiment switch: it restores the old "copy whatever planet is on screen"
-- behaviour, and the log has to say that is what happened
-- an explicit other-faction template (experiment switch): a Terminid target may copy the Automaton
-- copy when the config asks for it
write_file(CFG, 'unlock 126 faction 2 policy automaton\nplanet 215 tag 9 filter 2\n')
fresh_log()
err = tick(122)
check('the ticks return cleanly with policy automaton', err == nil, err)
check('an explicit faction uses that faction template',
    logged('UNLOCK template in use: faction 3, source planet=262, 1 row(s) (target=126)'))
-- dropping the unlock line has to put the record back the way it was found, so an experiment can be
-- undone by editing the config instead of restarting the game
write_file(CFG, 'planet 215 tag 9,10,11 filter 2\n')
fresh_log()
err = tick(122)
check('dropping the unlock line restores the record',
    logged('UNLOCK released planet=126'))
local restored = space:read(BOARD_AT + CAMPAIGN_OFFSET + PLANET_DYNAMIC_OFFSET
    + 126 * PLANET_DYNAMIC_STRIDE, PLANET_DYNAMIC_STRIDE)
check('the restored record is no longer available and has no copied field',
    u32(restored, 48) == 0 and u32(restored, 68) == 0 and u32(restored, 36) == 1,
    string.format('available=%d +68=%d faction=%d', u32(restored, 48), u32(restored, 68),
        u32(restored, 36)))

-- ------------------------------------- scenario 6: an old generated template is refreshed
print('=== scenario 6: a generated template from an older pack is refreshed, an edited one is not')
local function checksum(text)
    local hash = 2166136261
    for index = 1, #text do
        hash = (hash * 131 + text:byte(index)) % 4294967296
    end
    return string.format('%d-%d', hash, #text)
end
local function write_state(version, hash)
    write_file(OUT .. '/PlanetForge.state', string.format('version=%d\nhash=%s\n', version, hash))
end

local OLD = '# PlanetForge config -- template v1\nplanet 215 tag 9\nplanet 259 tag 30\n'
write_file(CFG, OLD)
write_state(1, checksum(OLD))
fake, space = build_space({ [215] = 2, [224] = 4, [253] = 3, [262] = 3, [70] = 3, [114] = 3,
    [225] = 4, [231] = 4, [100] = 2 })
use_space(fake, space)
fresh_log()
install()
err = tick(3)
check('the ticks return cleanly', err == nil, err)
check('the untouched old template is refreshed and the fact is logged',
    logged('CFG refreshed: template v1 -> v19'))
check('the previous content was backed up',
    (read_file(CFG .. '.bak') or '') == OLD)
check('the refreshed config is the new batch',
    (read_file(CFG) or ''):find('unlock 126 faction 2', 1, true) ~= nil)
check('the old rows are gone',
    (read_file(CFG) or ''):find('planet 259 tag 30', 1, true) == nil)
check('the new template is applied', logged('CFG loaded: 8 line(s) accepted, 0 ignored'))

-- The real migration case: a config written by an older pack, which left no state file at all.
os.remove(OUT .. '/PlanetForge.state')
os.remove(CFG .. '.bak')
local OLD_BANNER = '# PlanetForge config -- edited live, picked up within about two seconds, '
    .. 'no restart needed.\nplanet 215 tag 9\nplanet 259 tag 30\n'
write_file(CFG, OLD_BANNER)
fresh_log()
install()
err = tick(3)
check('the ticks return cleanly', err == nil, err)
check('a banner-only old config with no state file is migrated too',
    logged('CFG refreshed: template vold -> v19'))
check('the migration backed the old file up', (read_file(CFG .. '.bak') or '') == OLD_BANNER)
check('and applied the new batch',
    (read_file(CFG) or ''):find('planet 224 tag 27,28,29,30 filter 4', 1, true) ~= nil)

-- ------------------------------------------- scenario 7: more than five tags on one planet
print('=== scenario 7: a planet with more than five tags spills into a second row')
write_file(CFG, 'planet 215 tag 0,1,2,3,4,5,6 filter 2\n')
fake, space = build_space({ [215] = 2 })
use_space(fake, space)
fresh_log()
install()
err = tick(3)
check('the ticks return cleanly', err == nil, err)
check('the first five tags take the first row',
    logged('WRITE ok #1 row=0 planet=215 tags=0,1,2,3,4 filter=2 count=5'))
check('the rest spill into the next row',
    logged('WRITE ok #2 row=1 planet=215 tags=5,6 filter=2 count=2'))
check('the second row is really on the same planet',
    u32(space:read(TABLE_AT + ROW_SIZE, ROW_SIZE), 88) == 215)

-- ---------------- scenario 9: the game swaps the table out; the template must survive that
print('=== scenario 9: the game replaces the table; the target is still restorable')
write_file(CFG, 'unlock 126 faction 2\nplanet 215 tag 9 filter 2\n')
fake, space = build_space({ [215] = 2, [126] = 1 }, nil, 126)
use_space(fake, space)
fresh_log()
install()
err = tick(3)
check('the ticks return cleanly', err == nil, err)
check('the first fill copies the template',
    logged('wrote=4, now 4 of 4 row(s) (viewed=true, template faction 2, source planet 215)'))
-- what the game does when the player looks at another planet: the table is replaced wholesale. Take
-- one row first, wipe everything, then put that single 215 row back -- exactly the situation that
-- made our templates disappear and left every target without a source.
local one_row = space:read(BOARD_AT + TASK_TABLE_OFFSET, TASK_ROW_SIZE)
local blank = string.rep('\0', TASK_ROW_SIZE)
for index = 0, 40 do
    space:write(BOARD_AT + TASK_TABLE_OFFSET + index * TASK_ROW_SIZE, blank)
end
space:write(BOARD_AT + TASK_TABLE_OFFSET, one_row)
space:write(BOARD_AT + 1548952, u32le(215))
space:write(BOARD_AT + 1548956, u32le(215))
fresh_log()
err = tick(16)
check('the view change is handled cleanly', err == nil, err)
-- back to the target: the cached copy has to be there even though its original slots were overwritten
space:write(BOARD_AT + 1548952, u32le(126))
space:write(BOARD_AT + 1548956, u32le(126))
fresh_log()
err = tick(16)
check('the view change back is handled cleanly', err == nil, err)
local restored = 0
for index = 0, 40 do
    local row = space:read(BOARD_AT + TASK_TABLE_OFFSET + index * TASK_ROW_SIZE, TASK_ROW_SIZE)
    if u32(row, 16) == 126 then restored = restored + 1 end
end
check('the target is filled again from the retained template', restored == 4,
    'rows for 126: ' .. restored)
check('and no "no faction" failure was logged',
    not logged('no faction 2 (same as target) planet with validated rows'))

-- ------- scenario 10: the cfg that the generator produces must be accepted by this same parser
-- (addon/generator alignment; the file is written by 星球工坊/tools/对齐检查.py)
print('=== scenario 10: the config the generator writes is parsed and applied')
-- the ASCII copy first: LuaJIT's io.open goes through the C runtime, which is not happy with a
-- non-ASCII path on this machine, so the alignment tool writes both
local handle = io.open('build/_generated_default.cfg', 'rb')
    or io.open('星球工坊/build/generated_default.cfg', 'rb')
if not handle then
    print('  note: generated_default.cfg missing -- run 星球工坊/tools/对齐检查.py --write')
else
    local generated = handle:read('*a')
    handle:close()
    write_file(CFG, generated)
    fake, space = build_space({ [215] = 2, [262] = 3, [224] = 4, [235] = 1, [152] = 1, [238] = 1,
        [126] = 1, [127] = 1 }, nil, 126)
    use_space(fake, space)
    fresh_log()
    install()
    err = tick(3)
    check('the generated config is parsed cleanly', err == nil, err)
    check('every generated line is accepted',
        logged('CFG loaded: 8 line(s) accepted, 0 ignored'))
    check('all generated unlocks are recognised', logged('CFG unlock line(s): 5'))
    check('a generated unlock writes its record', logged('UNLOCK ok planet=126 plan=125'))
    check('the generated hidden-planet line really asks for plan 127',
        logged('UNLOCK ok planet=127 plan=127'))
    check('the generated tag lines are written',
        logged('WRITE ok #8 row=7 planet=127 tags=9,10,11 filter=2 count=3'))
end

-- ------------------------------- scenario 8: the 127 plan (hidden planet) and the neutral marks
print('=== scenario 8: `plan 127` writes timer/state and keeps the row layer off')
write_file(CFG, 'unlock 126 faction 2 plan 127\nplanet 215 tag 9 filter 2\n')
fake, space = build_space({ [215] = 2, [126] = 1 }, nil, 215)
use_space(fake, space)
fresh_log()
install()
err = tick(3)
check('the ticks return cleanly', err == nil, err)
check('the 127 plan writes state and zeroes the timer',
    logged('plan=127 faction=1->2 available=0->1 state@28=0->5 timer@44=0->0'))
check('the 127 plan keeps the row layer off by default',
    not logged('UNLOCK task rows planet=126'))
check('the 127 plan does not zero anything else', logged('(own record)'))

-- An edited file whose recorded state still points at the pack's old template: left alone.
local EDITED = OLD .. 'planet 70 tag 9\n'
write_file(CFG, EDITED)
write_state(1, checksum(OLD))
fresh_log()
install()
err = tick(3)
check('the ticks return cleanly', err == nil, err)
check('an edited config is left alone and said so',
    logged('CFG kept: this file has been edited'))
check('the edit survived', read_file(CFG) == EDITED)
check('the edited lines are the ones applied',
    logged('CFG loaded: 3 line(s) accepted, 0 ignored'))

-- ------------- scenario 11: the user's bug -- after a match one target used to wipe the others
print('=== scenario 11: two targets survive a match and refill without re-visiting them')
write_file(CFG, 'unlock 126 faction 2\nunlock 127 faction 2 plan 127 rows on\n'
    .. 'planet 215 tag 9 filter 2\nplanet 126 tag 9 filter 2\nplanet 127 tag 9 filter 2\n')
fake, space = build_space({ [215] = 2, [126] = 1, [127] = 1 }, nil, 126)
use_space(fake, space)
fresh_log()
install()
err = tick(3)
check('the ticks return cleanly', err == nil, err)
local function rows_of(planet)
    local count = 0
    for index = 0, 30 do
        local row = space:read(BOARD_AT + TASK_TABLE_OFFSET + index * TASK_ROW_SIZE, TASK_ROW_SIZE)
        if u32(row, 16) == planet and row:byte(53) ~= 0 then count = count + 1 end
    end
    return count
end
check('both targets get their mission rows', rows_of(126) == 4 and rows_of(127) == 4,
    'rows for 126: ' .. tostring(rows_of(126)) .. ', for 127: ' .. tostring(rows_of(127)))
-- a finished match: the game rebuilds the table from scratch. The player is looking at 126 only.
for index = 0, 40 do
    space:write(BOARD_AT + TASK_TABLE_OFFSET + index * TASK_ROW_SIZE, string.rep('\0', TASK_ROW_SIZE))
end
space:write(BOARD_AT + 1548952, u32le(126))
space:write(BOARD_AT + 1548956, u32le(126))
fresh_log()
-- one full check cycle (CHECK_TICKS = 120): the viewed planet is refilled by the fast view path, and
-- every other configured target by the slower poll pass
err = tick(150)
check('the ticks after the match return cleanly', err == nil, err)
check('the viewed target is refilled', rows_of(126) == 4,
    'rows for 126: ' .. tostring(rows_of(126)))
check('and the target that was NOT viewed is refilled too -- this is the bug that was reported',
    rows_of(127) == 4, 'rows for 127: ' .. tostring(rows_of(127)))
check('the refill is reported for both', logged('planet=126 wrote=') and logged('planet=127 wrote='))

print('  --- log (last scenario)')
for line in (read_file(OUT .. '/PlanetForge.log') or ''):gmatch('[^\r\n]+') do
    print('    ' .. line)
end

print(string.format('\nplanet forge simulation: %d problem(s)', problems))
os.exit(problems == 0 and 0 or 1)
