-- A stand-in for LuaJIT's `ffi`, backed by a fake address space held in Lua strings.
--
-- The point is to run `src/frv_zone_patch.lua` *unmodified* outside the game: it calls
-- ReadProcessMemory / WriteProcessMemory / VirtualQuery through `ffi`, so a fake kernel
-- with a fake address space is enough to exercise the whole scan, the profile checks and
-- every write. Records come from the real datalibrary (`build/records/<index>.bin`, made
-- by `python tools/extract_vehicle_health.py --raw`), so the test sees the same bytes the
-- game will.
--
-- Only what the addon actually uses is implemented. Scalars are packed through the real
-- ffi so the IEEE754 and little-endian behaviour is exact, not re-derived.

local real = assert(rawget(_G, '__SIM_REAL_FFI'), 'runner must stash the real ffi')

local M = {}

local TYPES = {
    int8 = 1, int16 = 2, int32 = 4, int64 = 8,
    uint8 = 1, uint16 = 2, uint32 = 4, uint64 = 8,
    fp32 = 4, fp64 = 8,
}
local CTYPE = {
    int8_t = 'int8', int16_t = 'int16', int32_t = 'int32', int64_t = 'int64',
    uint8_t = 'uint8', uint16_t = 'uint16', uint32_t = 'uint32', uint64_t = 'uint64',
    size_t = 'uint64', float = 'fp32', double = 'fp64', ['void *'] = 'uint64',
    uintptr_t = 'uint64',
}
local CTYPE_SIZE = { int8 = 1, int16 = 2, int32 = 4, int64 = 8, uint8 = 1,
                     uint16 = 2, uint32 = 4, uint64 = 8, fp32 = 4, fp64 = 8 }
-- The Lua-side name is only a label here; the real ffi needs the C spelling.
local CNAME = { int8 = 'int8_t', int16 = 'int16_t', int32 = 'int32_t', int64 = 'int64_t',
                uint8 = 'uint8_t', uint16 = 'uint16_t', uint32 = 'uint32_t',
                uint64 = 'uint64_t', fp32 = 'float', fp64 = 'double' }

local function pack(kind, value)
    local h = real.new(CNAME[kind] .. '[1]', value or 0)
    return real.string(real.cast('uint8_t *', h), CTYPE_SIZE[kind])
end

local function unpack(kind, bytes, offset)
    local h = real.new('uint8_t[8]')
    real.copy(h, bytes:sub(offset + 1, offset + CTYPE_SIZE[kind]), CTYPE_SIZE[kind])
    local value = real.cast(CNAME[kind] .. ' *', h)[0]
    -- A 64-bit value does not survive `tonumber`, and entity ids are 64-bit, so those
    -- come back as the cdata itself -- exactly what real ffi gives the addon.
    if kind == 'uint64' or kind == 'int64' then return value end
    return tonumber(value)
end

-- ---------------------------------------------------------------- array objects
local ArrayMT = {}

local function array(kind, count, unit, extra)
    local size = (unit or CTYPE_SIZE[kind]) * count
    local o = setmetatable({ kind = kind, count = count,
                             unit = unit or CTYPE_SIZE[kind], n = size,
                             b = string.rep('\0', size) }, ArrayMT)
    for key, value in pairs(extra or {}) do rawset(o, key, value) end
    return o
end

ArrayMT.__index = function(o, key)
    if key == 0 and rawget(o, 'region_view') then return rawget(o, 'region_view') end
    if type(key) == 'number' then
        return unpack(rawget(o, 'elem') or o.kind, rawget(o, 'b'), key * o.unit)
    end
    return rawget(o, key)
end

ArrayMT.__newindex = function(o, key, value)
    if type(key) == 'number' then
        local bytes = pack(rawget(o, 'elem') or o.kind, value)
        local at = key * o.unit
        rawset(o, 'b', o.b:sub(1, at) .. bytes .. o.b:sub(at + o.unit + 1))
        return
    end
    rawset(o, key, value)
end

-- A view of the 48-byte VirtualQuery region struct, by field name.
local REGION_FIELDS = { base = { 'uint64', 0 }, allocation_base = { 'uint64', 8 },
                        allocation_protection = { 'uint32', 16 },
                        partition = { 'uint16', 20 }, reserved = { 'uint16', 22 },
                        size = { 'uint64', 24 }, state = { 'uint32', 32 },
                        protection = { 'uint32', 36 }, type = { 'uint32', 40 } }
local ViewMT = {
    __index = function(v, key)
        local field = REGION_FIELDS[key]
        if not field then return nil end
        return unpack(field[1], rawget(v, 'b'), field[2])
    end,
}

-- A read-only pointer, for `ffi.cast('float *', holder)[0]`.
local PtrMT = {
    __index = function(p, key)
        if type(key) ~= 'number' then return rawget(p, key) end
        return unpack(rawget(p, 'elem'), rawget(p, 'b'), key * 4)
    end,
}

-- ---------------------------------------------------------------- fake funcs
function M.cdef() end

function M.sizeof(value)
    if type(value) == 'table' then return value.n end
    local kind = CTYPE[value]
    if kind then return CTYPE_SIZE[kind] end
    return 48  -- the VirtualQuery region struct, whatever the addon calls it
end

local function new_region()
    local o = array('uint8', 48)
    o.region_view = setmetatable({ b = o.b }, ViewMT)
    -- The view must see later writes, so keep them pointing at the same string.
    return setmetatable(o, { __index = function(t, k)
        if k == 0 then
            rawget(t, 'region_view').b = rawget(t, 'b')
            return rawget(t, 'region_view')
        end
        return ArrayMT.__index(t, k)
    end, __newindex = ArrayMT.__newindex })
end

function M.new(ctype, size)
    if ctype == 'uint8_t[?]' then return array('uint8', size) end
    local base, count = ctype:match('^(.-)%[(%d+)%]$')
    if not base then error('sim: ffi.new(' .. tostring(ctype) .. ') unsupported') end
    local kind = CTYPE[base]
    if not kind then
        -- Any single-element struct we do not model is the region struct.
        if tonumber(count) == 1 then return new_region() end
        error('sim: ffi.new for ' .. base .. ' unsupported')
    end
    local o = array(kind, tonumber(count))
    if size ~= nil then o[0] = size end
    return o
end

function M.cast(ctype, value)
    if ctype == 'void *' or ctype == 'const void *' or ctype == 'uintptr_t' then return value end
    if ctype == 'uint8_t *' then return value end
    local base = ctype:match('^(.-) %*$')
    if base then
        local kind = CTYPE[base]
        if not kind then error('sim: ffi.cast for ' .. ctype .. ' unsupported') end
        return setmetatable({ elem = kind, b = value.b, unit = 4, cname = CNAME[kind] },
                            PtrMT)
    end
    error('sim: ffi.cast(' .. tostring(ctype) .. ') unsupported')
end

function M.string(value, size)
    return value.b:sub(1, size)
end

function M.copy(dest, src, size)
    local bytes = type(src) == 'string' and src:sub(1, size) or src.b:sub(1, size)
    dest.b = bytes .. dest.b:sub(size + 1)
end

-- ---------------------------------------------------------------- fake kernel
local Space = {}
Space.__index = Space

function M.new_space()
    local s = setmetatable({ regions = {}, modules = {} }, Space)
    return s
end

function Space:add_module(name, base)
    self.modules[name] = base
    return base
end

function Space:add(base, size, state, protection, kind, bytes)
    local region = { base = base, size = size, state = state, protection = protection,
                     type = kind, bytes = bytes or string.rep('\0', size) }
    assert(#region.bytes == size, 'region payload size mismatch')
    table.insert(self.regions, region)
    table.sort(self.regions, function(a, b) return a.base < b.base end)
    return region
end

function Space:find(address, size)
    for _, region in ipairs(self.regions) do
        if address >= region.base and address + size <= region.base + region.size then
            return region
        end
    end
    return nil
end

function Space:read(address, size)
    local region = self:find(address, size)
    if not region then return nil end
    local at = address - region.base
    return region.bytes:sub(at + 1, at + size)
end

function Space:write(address, bytes)
    local region = self:find(address, #bytes)
    if not region then return false end
    local at = address - region.base
    region.bytes = region.bytes:sub(1, at) .. bytes .. region.bytes:sub(at + #bytes + 1)
    return true
end

function M.kernel(space)
    local kernel = {}
    function kernel.GetCurrentProcess() return 1 end
    -- Loaded-module handles. The runner plants `space.modules` (name -> base address); real
    -- kernel32 returns NULL for a module that is not loaded, and GetModuleHandleA(NULL) is the
    -- executable itself, which the runner stores under the empty name.
    function kernel.GetModuleHandleA(name)
        local modules = rawget(space, 'modules')
        if not modules then return nil end
        if name == nil or name == 0 then return modules[''] end
        return modules[name]
    end
    function kernel.ReadProcessMemory(_, address, buffer, size, count)
        local bytes = space:read(address, size)
        if not bytes then return 0 end
        buffer.b = bytes
        count[0] = size
        return 1
    end
    function kernel.WriteProcessMemory(_, address, buffer, size, written)
        -- A Lua string is what LuaJIT itself accepts for `const void *`; addons in this
        -- project write f32/u32 payloads that way, so accept both spellings.
        local bytes = type(buffer) == 'string' and buffer:sub(1, size) or buffer.b:sub(1, size)
        if not space:write(address, bytes) then return 0 end
        written[0] = size
        return 1
    end
    function kernel.VirtualProtect() return 1 end
    -- Addons that create their own log directory fall back to this when the loader does
    -- not hand them one; reporting "already exists" keeps them on the %LOCALAPPDATA% path.
    function kernel.CreateDirectoryA() return 1 end
    function kernel.GetLastError() return 183 end
    -- VirtualQuery takes no process handle: (address, out, size).
    --
    -- A free gap is reported the way Windows reports it: one span whose base is where the
    -- free area *begins* (the end of the previous mapping), not the address that was
    -- asked about. That distinction is what lets a DESCENDING walk -- the shared
    -- `frv_region_walk` the FRV addons now use -- jump a gap in one hop, and above the
    -- last mapping it is what stops the walk stepping down one page at a time, which is
    -- 2^31 iterations of nothing. (The old code both rebased the gap on the queried
    -- address and returned 0 past the last mapping; an ascending walk never noticed.)
    local function free_span(address)
        local start, above = 0x10000, nil
        for _, region in ipairs(space.regions) do
            local finish = region.base + region.size
            if finish <= address then
                if finish > start then start = finish end
            elseif above == nil or region.base < above then
                above = region.base
            end
        end
        local top = above or 0x00007FFFFFFFFFFF
        if top <= start or address < start then return nil end
        return start, top - start
    end
    function kernel.VirtualQuery(address, out, _)
        for _, region in ipairs(space.regions) do
            if address >= region.base and address < region.base + region.size then
                out.b = pack('uint64', region.base) .. pack('uint64', region.base)
                    .. pack('uint32', region.protection) .. pack('uint16', 0)
                    .. pack('uint16', 0) .. pack('uint64', region.size)
                    .. pack('uint32', region.state) .. pack('uint32', region.protection)
                    .. pack('uint32', region.type) .. string.rep('\0', 4)
                return 48
            end
        end
        local base, size = free_span(address)
        if not base then return 0 end
        out.b = pack('uint64', base) .. pack('uint64', 0)
            .. pack('uint32', 0) .. pack('uint16', 0) .. pack('uint16', 0)
            .. pack('uint64', size) .. pack('uint32', 0) .. pack('uint32', 0)
            .. pack('uint32', 0) .. string.rep('\0', 4)
        return 48
    end
    return kernel
end

function M.load(name)
    if name ~= 'kernel32' then error('sim: ffi.load(' .. tostring(name) .. ')') end
    return assert(rawget(_G, '__SIM_KERNEL'), 'runner must install the fake kernel')
end

return M
