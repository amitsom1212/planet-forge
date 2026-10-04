"""HD2 / LuaJIT tooling.

Verified against shipped mod archives (Bingus Shared Loader v12 and the
R-2124 Constitution Bolt AMR Bridge v4 package):
 * ``.patch_0`` entry layout
 * Lua resource wrapper used by the engine's ``lua`` resource type
 * resource-name hash
"""
import hashlib
import struct

ARCHIVE = '9ba626afa44a3aa3.patch_0'
LUA_TYPE = 0xA14E8DFA2CD117E2
LUA_RESOURCE_TYPE = 2

# --- .patch_0 layout --------------------------------------------------------
TABLE_OFFSET = 104          # first entry
ENTRY_SIZE = 80
# Entry fields, verified byte-for-byte against shipped archives
# (entry base +0x00):
#   +0x00 u64 resource name hash
#   +0x08 u64 resource type        (LUA_TYPE)
#   +0x10 u32 resource offset
#   +0x14 u32 0
#   +0x18 u32 0
#   +0x1C u32 0
#   +0x20 u32 0
#   +0x24 u32 0
#   +0x28 u32 0
#   +0x2C u32 0
#   +0x30 u32 0
#   +0x34 u32 0
#   +0x38 u32 resource length      (unpadded bytecode resource)
#   +0x3C u32 0
#   +0x40 u32 0
#   +0x44 u32 16
#   +0x48 u32 16
#   +0x4C u32 entry index


def sha256_upper(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def resource_hash(name: str) -> int:
    """MurmurHash64A variant used by the engine for resource names."""
    data = name.encode('utf-8')
    mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
    value = len(data) * mix & mask
    end = len(data) // 8 * 8
    for (word,) in struct.iter_unpack('<Q', data[:end]):
        word = word * mix & mask
        word ^= word >> 47
        value = (value ^ (word * mix & mask)) * mix & mask
    if data[end:]:
        value = (value ^ int.from_bytes(data[end:], 'little')) * mix & mask
    value ^= value >> 47
    value = value * mix & mask
    return value ^ (value >> 47)


def lua_resource(ljbc: bytes) -> bytes:
    """Engine ``lua`` resource: <u32 bytecode length><u32 type=2><LuaJIT dump>."""
    return struct.pack('<II', len(ljbc), LUA_RESOURCE_TYPE) + ljbc


def make_archive(resources: dict) -> bytes:
    """Build a .patch_0 archive. ``resources`` maps name hash -> resource bytes."""
    if not resources:
        raise ValueError('an archive needs at least one resource')
    count = len(resources)
    offset = (TABLE_OFFSET + ENTRY_SIZE * count + 15) & ~15
    entries, body = bytearray(), bytearray(offset)
    for index, (name, resource) in enumerate(sorted(resources.items())):
        entry = bytearray(ENTRY_SIZE)
        entry[0x00:0x08] = struct.pack('<Q', name)
        entry[0x08:0x10] = struct.pack('<Q', LUA_TYPE)
        entry[0x10:0x14] = struct.pack('<I', offset)
        entry[0x38:0x3C] = struct.pack('<I', len(resource))
        entry[0x44:0x48] = struct.pack('<I', 16)
        entry[0x48:0x4C] = struct.pack('<I', 16)
        entry[0x4C:0x50] = struct.pack('<I', index)
        entries += entry
        body += resource
        # Pad the stream so the next resource starts 16-byte aligned, and record
        # the aligned end offset in header field 0x20. Verified byte-for-byte
        # against the Bingus loader, Constitution and P-11 archives.
        padding = -len(body) % 16
        body += b'\0' * padding
        offset = len(body)
    header = struct.pack('=III20sQQ24s', 0xF0000011, 1, count, b'', offset, 0, b'')
    types = struct.pack('=IIQIIII', 0, 0, LUA_TYPE, count, 0, 16, 16)
    body[:TABLE_OFFSET + len(entries)] = header + types + entries
    return bytes(body)


def read_archive(path: str):
    """Return {name_hash: resource_bytes} from a .patch_0 archive."""
    with open(path, 'rb') as fh:
        b = fh.read()
    count = int.from_bytes(b[8:12], 'little')
    out = {}
    for i in range(count):
        o = TABLE_OFFSET + ENTRY_SIZE * i
        name = int.from_bytes(b[o:o + 8], 'little')
        off = int.from_bytes(b[o + 16:o + 20], 'little')
        length = int.from_bytes(b[o + 0x38:o + 0x3C], 'little')
        out[name] = b[off:off + length]
    return out


# ---------------------------------------------------------------- LuaJIT dump

def uleb(data: bytes, pos: int):
    val = 0
    shift = 0
    while True:
        byte = data[pos]
        pos += 1
        val |= (byte & 0x7f) << shift
        if byte < 0x80:
            return val, pos
        shift += 7


def dump_info(bytecode: bytes):
    """Return (version, flags, chunkname) of a LuaJIT dump."""
    assert bytecode[:3] == b'\x1bLJ', 'not a LuaJIT dump'
    version = bytecode[3]
    flags, pos = uleb(bytecode, 4)
    name = None
    if not (flags & 0x02):
        nl, pos = uleb(bytecode, pos)
        name = bytecode[pos:pos + nl].decode('utf-8', 'replace')
    return version, flags, name


def strings_in(bytecode: bytes, minlen: int = 4):
    out, cur, start = [], bytearray(), 0
    for i, c in enumerate(bytecode):
        if 32 <= c < 127:
            if not cur:
                start = i
            cur.append(c)
        else:
            if len(cur) >= minlen:
                out.append((start, cur.decode('latin1')))
            cur = bytearray()
    if len(cur) >= minlen:
        out.append((start, cur.decode('latin1')))
    return out
