-- Long Tables: built tables standing side by side (west to east) and made of the same material
-- are drawn as one long table, with one leg under every join.  Cosmetic: only the picture changes.
--@ module = true
--
-- All of it is this script: one overlay widget that, after the game has drawn the map, puts the
-- pictures of joined tables in the map's building layer.  Nothing is stored; which tables join is
-- worked out again every frame from where the tables stand.

local overlay = require('plugins.overlay')

local NAME = 'long-tables'

-- The folder next to this script that holds the art.
local function data_dir()
    local src = debug.getinfo(1, 'S').source
    local path = src:sub(1, 1) == '@' and src:sub(2) or dfhack.findScript(NAME)
    local dir = path and path:gsub('\\', '/'):match('^(.*)/[^/]*$')
    return (dir or '.') .. '/internal/' .. NAME .. '/'
end
local DATA = data_dir()

local TILE = 32
local CLASS_WOOD, CLASS_STONE, CLASS_METAL, CLASS_GLASS = 0, 1, 2, 3
local CLASS_NAME = {[0]='wood', 'stone', 'metal', 'glass'}
local SINGLE, LEFT, MIDDLE, RIGHT = 0, 1, 2, 3      -- pieces: a table alone, and the parts of a joined one
local PIECE_NAME = {[0]='S', 'L', 'M', 'R'}

-- ---- the art ----------------------------------------------------------------------------------
--
-- template.lua (made by art/make_template.py from the game's own table sprite) holds, for each
-- class of material, the table tile as it is alone (S) and as the left end, middle and right end
-- of a joined table (L, M, R), plus a long strip of table-top surface that the tiles of a joined
-- table show consecutive parts of.  Pixels are not colours but shades: the game gives every
-- material colour a palette of 18 shades (two ramps of nine, dark to light) and draws its own
-- table by looking each sprite pixel up in the material's palette.  The script does the same.
--
-- Shade codes after parsing: 0..17 a palette shade, and
local CLEAR, SHADOW, BLEND, FAINT, HALF = -1, 18, 19, 20, 21
--   SHADOW  the shadow under the table: shade 0 at half strength
--   BLEND   halfway between shades 14 and 15 (a faint speck on stone)
--   FAINT   a quarter of the way from shade 15 to 16 (a faint streak on metal and glass)
--   HALF    halfway between shades 15 and 16 (the softened highlight along a joined table's edges)
local SHADOW_ALPHA = 128
local PALETTE_BYTES = 54              -- 18 shades, rgb
local END_SETS = 4                    -- sets of extra speckles for the ends of a stone table

local CODE = {['.']=CLEAR, ['~']=SHADOW, x=BLEND, y=FAINT, z=HALF}
for i = 0, 17 do CODE[('0123456789abcdefgh'):sub(i + 1, i + 1)] = i end

local template        -- [class] = {r0=, r1=, [SINGLE..RIGHT] = 1024 codes, strip = codes, ends = sets}
local phases          -- how many tiles the strip is long

local function codes(s, want)
    if type(s) ~= 'string' or #s ~= want then return nil end
    local out = {}
    for i = 1, #s do
        local c = CODE[s:sub(i, i)]
        if not c then return nil end
        out[i] = c
    end
    return out
end

-- Read template.lua.  Returns true when the template is in place.
local function load_template()
    local ok, data = pcall(dofile, DATA .. 'template.lua')
    if not ok or type(data) ~= 'table' then return false end
    local n = data.phases
    if math.type(n) ~= 'integer' or n < 1 or n > 64 then return false end
    local classes = {}
    for class = CLASS_WOOD, CLASS_GLASS do
        local src = data[CLASS_NAME[class]]
        if type(src) ~= 'table' then return false end
        local r0, r1 = src.r0, src.r1
        if math.type(r0) ~= 'integer' or math.type(r1) ~= 'integer' or r0 < 0 or r1 >= TILE or r0 > r1 then
            return false
        end
        local c = {r0=r0, r1=r1, strip=codes(src.strip, (r1 - r0 + 1) * n * TILE), ends={}}
        if not c.strip then return false end
        for piece = SINGLE, RIGHT do
            c[piece] = codes(src[PIECE_NAME[piece]], TILE * TILE)
            if not c[piece] then return false end
        end
        for set = 1, END_SETS do
            local specks = {}
            for i, e in ipairs(type(src.ends) == 'table' and src.ends[set] or {}) do
                local shade = type(e) == 'table' and CODE[e[3]]
                if not shade or math.type(e[1]) ~= 'integer' or math.type(e[2]) ~= 'integer' then return false end
                specks[i] = {e[1], e[2], shade}
            end
            c.ends[set] = specks
        end
        classes[class] = c
    end
    template, phases = classes, n
    return true
end

if not load_template() then
    dfhack.printerr(NAME .. ': could not read ' .. DATA .. 'template.lua; tables keep the game\'s own look')
end

-- Which template class a material uses.
local function class_of(flags)
    if flags.IS_GLASS then return CLASS_GLASS end
    if flags.IS_METAL then return CLASS_METAL end
    if flags.IS_STONE then return CLASS_STONE end
    if flags.WOOD then return CLASS_WOOD end
    return CLASS_STONE
end

-- The tint key of a material: (index of its game colour + 1) * 4 + class.  The colour is the
-- first colour of the material's solid-state colour pattern; index 0 (the game's default
-- palette) stands in when the raws give none.
local function material_tint(mat_type, mat_index)
    local info = dfhack.matinfo.decode(mat_type, mat_index)
    if not info then return CLASS_STONE end
    local class = class_of(info.material.flags)
    local d = df.global.world.raws.descriptors
    local p = info.material.state_color.Solid
    if p < 0 or p >= #d.patterns or #d.patterns[p].colors == 0 then return class end
    local c = d.patterns[p].colors[0]
    if c < 0 or c >= #d.colors then return class end
    return (c + 1) * 4 + class
end

-- (globals, so that running `long-tables status` -- which executes this file again -- does not
-- throw the caches away)
tint_of_material = tint_of_material or {}     -- material key -> tint key; emptied with the world

local function tint_of(mat_key)
    local tint = tint_of_material[mat_key]
    if not tint then
        local mat_type = mat_key >> 32
        if mat_type >= 0x80000000 then mat_type = mat_type - 0x100000000 end
        tint = material_tint(mat_type, (mat_key & 0xffffffff) - 1)
        tint_of_material[mat_key] = tint
    end
    return tint
end

-- The colours of a tint key's palette, packed for a texture (red in the low byte): [0..17] the
-- shades, [SHADOW], [BLEND], [FAINT], [HALF].  nil if the game does not have the palette.
local function tint_colours(tint)
    local src
    if tint < 4 then
        src = df.global.gps.default_palette.color
    else
        local colors = df.global.world.raws.descriptors.colors
        local c = tint // 4 - 1
        if c >= #colors then return nil end
        src = colors[c].palette.color
    end
    local pal = {}
    for i = 0, PALETTE_BYTES - 1 do pal[i] = src[i] end
    local col = {}
    for i = 0, 17 do
        col[i] = 0xff000000 | pal[i * 3 + 2] << 16 | pal[i * 3 + 1] << 8 | pal[i * 3]
    end
    col[SHADOW] = SHADOW_ALPHA << 24 | pal[2] << 16 | pal[1] << 8 | pal[0]
    local e, f, g = 14 * 3, 15 * 3, 16 * 3
    col[BLEND] = 0xff000000 | (pal[e + 2] + pal[f + 2]) // 2 << 16 | (pal[e + 1] + pal[f + 1]) // 2 << 8
        | (pal[e] + pal[f]) // 2
    col[FAINT] = 0xff000000 | (3 * pal[f + 2] + pal[g + 2]) // 4 << 16 | (3 * pal[f + 1] + pal[g + 1]) // 4 << 8
        | (3 * pal[f] + pal[g]) // 4
    col[HALF] = 0xff000000 | (pal[f + 2] + pal[g + 2]) // 2 << 16 | (pal[f + 1] + pal[g + 1]) // 2 << 8
        | (pal[f] + pal[g]) // 2
    return col
end

-- The shade codes of one tile: the piece, and for a piece of a joined table the stretch of the
-- strip for its phase laid over the top, and at the ends of a stone table the extra speckles.
local function compose(class, piece, phase)
    local c = template[class]
    local out = {}
    local src = c[piece]
    for i = 1, TILE * TILE do out[i] = src[i] end
    if piece == SINGLE then return out end
    -- an end keeps its own outer edge
    local x0 = piece == LEFT and 3 or 0
    local x1 = piece == RIGHT and TILE - 4 or TILE - 1
    local len = phases * TILE
    for y = c.r0, c.r1 do
        local row = (y - c.r0) * len + phase * TILE
        for x = x0, x1 do out[y * TILE + x + 1] = c.strip[row + x + 1] end
    end
    if piece ~= MIDDLE then
        for _, e in ipairs(c.ends[phase % END_SETS + 1]) do
            local x = piece == LEFT and x0 + e[1] or x1 - e[1]
            if x >= x0 and x <= x1 and e[2] >= c.r0 and e[2] <= c.r1 then
                out[e[2] * TILE + x + 1] = e[3]
            end
        end
    end
    return out
end

-- The pixels of one tile for a tint key; nil without a palette.
local function paint_tile(tint, piece, phase)
    local col = tint_colours(tint)
    if not col then return nil end
    local px = compose(tint & 3, piece, phase)
    for i = 1, TILE * TILE do px[i] = col[px[i]] or 0 end
    return px
end

-- Tiles are painted once and kept: tile key -> texture handle.  They are dropped from the table
-- when the world goes (colour indexes belong to a world's raws) but the textures are never
-- deleted: DFHack does not hand a deleted handle's slot back cleanly.
tile_handles = tile_handles or {}
STATS = STATS or {frames=0, cells=0, tiles=0}

-- Texpos of a tile; nil if it cannot be had.
local function tile_texpos(tint, piece, phase)
    if piece == SINGLE then phase = 0 end
    local key = tint | piece << 32 | phase << 36
    local handle = tile_handles[key]
    if not handle then
        local px = template and paint_tile(tint, piece, phase)
        handle = px and dfhack.textures.createTile(px, TILE, TILE)
        -- a refused texture is left out, so the next draw asks again
        if not handle or handle == 0 then return nil end
        tile_handles[key] = handle
        STATS.tiles = STATS.tiles + 1
    end
    local texpos = dfhack.textures.getTexposByHandle(handle)
    return texpos and texpos > 0 and texpos or nil
end

-- (keyed by where this copy lives: DFHack can have two copies of a mod's script loaded, and each
-- has its own caches to empty)
dfhack.onStateChange[NAME .. ':' .. DATA] = function(event)
    if event == SC_WORLD_UNLOADED then
        tint_of_material, tile_handles = {}, {}
    end
end

-- ---- drawing ------------------------------------------------------------------------------------
--
-- The game draws the map into the viewport's layers of texture numbers, one cell per map tile; a
-- table's picture is in the building layer (screentexpos_building_one).  Each frame, after the
-- game has filled the layers and before they reach the screen, the cell of every finished table
-- in view that has a matching neighbour is given this mod's tile instead.  Only cells the game
-- put a building picture in are touched, so a table the game does not show (unrevealed, say)
-- stays unshown.  Creatures and items are other layers, drawn over this one as before.
--
-- The game draws the level in view into main_viewport and, where the floor is open, up to eight
-- levels below it into lower_viewport[0..7] (0 = one level down).
local LOWER_LEVELS = 8

-- Which stretch of the strip a tile shows.  Neighbours in a row show consecutive stretches; rows
-- start at different places so tables one above the other do not look alike.
local function phase_at(x, y)
    return (x + 5 * y) % phases
end

-- A finished table's material as one number, nil for a table that does not take part.
local function material_key(b)
    if b:getBuildStage() < b:getMaxBuildStage() then return nil end
    local items = b.contained_items
    if #items == 0 then return nil end
    local item = items[0].item
    return item:getMaterial() << 32 | (item:getMaterialIndex() + 1) & 0xffffffff
end

-- Where a table is on the screen, as one number; depth 0 is the level in view.
local function spot(depth, sx, sy)
    return depth << 40 | (sx + 1) << 20 | sy
end

-- The building layer of the viewport a depth is drawn in, nil if there is none of the size of
-- the main one.
local function layer(depth, main, lower, dim_x, dim_y)
    local vp = depth == 0 and main or lower[depth - 1]
    if not vp or vp.dim_x ~= dim_x or vp.dim_y ~= dim_y then return nil end
    return vp.screentexpos_building_one
end

-- Pass 1: note the material of every finished table the game shows, and of those one tile off
-- the left or right edge of the view (they can be the neighbour of one in view).  A table the
-- game does not show does not join: its neighbour would end in nothing.
local function note_table(b, mats, list, wx, wy, wz, dim_x, dim_y, main, lower)
    local depth = wz - b.z
    if depth < 0 or depth > LOWER_LEVELS then return end
    local sx, sy = b.centerx - wx, b.centery - wy
    if sx < -1 or sx > dim_x or sy < 0 or sy >= dim_y then return end
    local in_view = sx >= 0 and sx < dim_x
    if in_view then
        local cells = layer(depth, main, lower, dim_x, dim_y)
        if not cells or cells[sx * dim_y + sy] == 0 then return end
    elseif not dfhack.maps.isTileVisible(b.centerx, b.centery, b.z) then
        -- off the edge there is no cell to tell whether the game shows it
        return
    end
    local key = material_key(b)
    if not key then return end
    mats[spot(depth, sx, sy)] = key
    if in_view then list[#list + 1] = b end
end

-- For checking the template against the game's own picture: draw lone tables too, from the
-- template, instead of leaving them to the game (`long-tables singles on`), or draw every
-- table as a lone one (`long-tables singles only`).
draw_singles = draw_singles or false

local function draw_tables()
    if not template then return end
    local gps = df.global.gps
    local main, lower = gps.main_viewport, gps.lower_viewport
    local wx, wy, wz = df.global.window_x, df.global.window_y, df.global.window_z
    local dim_x, dim_y = main.dim_x, main.dim_y
    local mats, list = {}, {}
    local first_err
    for _, b in ipairs(df.global.world.buildings.other.TABLE) do
        local ok, err = pcall(note_table, b, mats, list, wx, wy, wz, dim_x, dim_y, main, lower)
        if not ok and not first_err then first_err = err end
    end
    -- Pass 2: give every noted table with a like neighbour its piece.
    for i = 1, #list do
        local b = list[i]
        local depth = wz - b.z
        local sx, sy = b.centerx - wx, b.centery - wy
        local key = mats[spot(depth, sx, sy)]
        local left = draw_singles ~= 'only' and mats[spot(depth, sx - 1, sy)] == key
        local right = draw_singles ~= 'only' and mats[spot(depth, sx + 1, sy)] == key
        if left or right or draw_singles then
            local cells = layer(depth, main, lower, dim_x, dim_y)
            local cell = sx * dim_y + sy
            if cells and cells[cell] ~= 0 then
                local piece = left and (right and MIDDLE or RIGHT) or right and LEFT or SINGLE
                local ok, texpos = pcall(tile_texpos, tint_of(key), piece, phase_at(b.centerx, b.centery))
                if ok and texpos then
                    cells[cell] = texpos
                    STATS.cells = STATS.cells + 1
                elseif not ok and not first_err then
                    first_err = texpos
                end
            end
        end
    end
    if first_err then error(first_err, 0) end
end

LongTablesOverlay = defclass(LongTablesOverlay, overlay.OverlayWidget)
LongTablesOverlay.ATTRS{
    desc='Draws tables standing side by side, of one material, as one long table.',
    default_enabled=true,
    viewscreens='dwarfmode',
    frame={w=0, h=0},
}

local draw_failed = false

function LongTablesOverlay:onRenderFrame(dc, rect)
    LongTablesOverlay.super.onRenderFrame(self, dc, rect)
    STATS.frames = STATS.frames + 1
    local ok, err = pcall(draw_tables)
    -- say so once, not sixty times a second
    if not ok and not draw_failed then
        draw_failed = true
        dfhack.printerr(NAME .. ': drawing failed: ' .. tostring(err))
    end
end

OVERLAY_WIDGETS = { map = LongTablesOverlay }

-- For test/run_tests.lua only.
internal = {compose=compose, paint_tile=paint_tile, tint_colours=tint_colours, material_tint=material_tint,
            draw_tables=draw_tables, phase_at=phase_at, load_template=load_template,
            phases=function() return phases end, template=function() return template end, CLEAR=CLEAR, SHADOW=SHADOW, BLEND=BLEND, FAINT=FAINT, HALF=HALF}

-- ---- command line ---------------------------------------------------------------------------
--
--   long-tables status          what the overlay has drawn so far
--   long-tables reload          read the art again and repaint every table (for working on the art)
--   long-tables singles on|off|only   draw lone tables from the template too, or every table
--                                       as a lone one (for checking the art against the game's)

if not dfhack_flags.module then
    local args = {...}
    if args[1] == 'reload' and not args[2] then
        if not load_template() then qerror(NAME .. ': could not read ' .. DATA .. 'template.lua') end
        tile_handles = {}
        print(NAME .. ': reloaded ' .. DATA .. 'template.lua')
    elseif args[1] == 'status' and not args[2] then
        print(('%s: template %s, %d frames, %d table cells drawn, %d tiles painted%s')
            :format(NAME, template and 'loaded' or 'MISSING', STATS.frames, STATS.cells, STATS.tiles,
                    draw_singles and ', singles ' .. tostring(draw_singles == true and 'on' or draw_singles) or ''))
    elseif args[1] == 'singles' and (args[2] == 'on' or args[2] == 'off' or args[2] == 'only') and not args[3] then
        draw_singles = args[2] == 'only' and 'only' or args[2] == 'on'
        print(NAME .. ': ' .. (draw_singles == 'only' and 'every table is drawn as a lone one, by this script'
            or 'lone tables are drawn by ' .. (draw_singles and 'this script' or 'the game')))
    else
        qerror('usage: ' .. NAME .. ' status | reload | singles on|off|only')
    end
end
