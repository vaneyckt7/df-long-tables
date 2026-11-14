-- Long Tables: built tables standing next to each other (west to east or north to south) and made
-- of the same material are drawn as one table, with one leg under every join.  Cosmetic: only the picture changes.
--@ module = true
--
-- All of it is this script: one overlay widget that, after the game has drawn the map, puts the
-- pictures of joined tables in the map's building layer.  Nothing is stored in the save; which
-- tables join is worked out from where the tables stand, and remembered only while nothing changes.

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

-- The rows of the top's surface proper (between the lines along its edges) for each class, and
-- how far the surface is shifted sideways each time those rows are gone through again further
-- down a table that is more than one tile deep.
--   Wood and stone: the rows fit twice in a tile, and two shifts are the five tiles that
--   phase_at() moves the surface from one map row to the next.  So counting the tiles down from
--   map row 0 (vert.k = y) gives every tile, deep or not, the same surface it has in a plain
--   row of tables, and the arms of an L or T fit the part that is deep.
--   Metal and glass: the shift is the height of the rows, so the slanted streaks carry on in a
--   line.  Every joined tile, deep or not, is counted down from map row 0, so the streaks are
--   one pattern over the whole map and the arms of an L, T or plus fit the part that is deep.
--   The rows do not fit a whole number of times in a tile: the pattern comes round after as
--   many tiles as there are rows (SLANT_CYCLE), by then moved sideways by `shift` whole tiles.
local INTERIOR = {[0]={3, 18, 80}, {3, 18, 80}, {2, 20, 19}, {2, 20, 19}}
-- Wood: sprite row 16 is one long pale streak of grain.  Once per table it is grain; down a deep
-- table it comes back every sixteen rows and reads as lines ruled across the top.  A tile of a
-- deep table shows row 11 (plain grain) in its place, and so do the tiles in a row with one
-- (vert.calm), or the streak would run along the arm of an L or T and stop dead at the deep part.
local PALE_ROW, PLAIN_ROW = 16 - 3, 11 - 3
local function counts_from_map_top(class) return class == CLASS_WOOD or class == CLASS_STONE end
local SLANT_CYCLE, SLANT_SHIFT = 20 - 2 + 1, 19
local LEG_ROW = 26
local OUTLINE = 0        -- the shade of the line around the table

local function piece_of(west, east)
    return west and (east and MIDDLE or RIGHT) or east and LEFT or SINGLE
end

-- The columns of a piece that are table top, not edge.
local function extent(piece)
    return (piece == LEFT or piece == SINGLE) and 3 or 0,
           (piece == RIGHT or piece == SINGLE) and TILE - 4 or TILE - 1
end

-- The shade codes of one tile: the piece, and for a piece of a joined table the stretch of the
-- strip for its phase laid over the top, and at the ends of a stone table the extra speckles.
--
-- vert, for a tile of a table more than one tile deep (north to south), is
--   {n=, s=    a like table north / south of this one
--    high=, low=   the piece (SINGLE..RIGHT) the top rows and the leg rows are drawn as, where
--                  that is not `piece` (see draw_tables)
--    k=        how many tiles down from map row 0 the tile is, as far as the surface can tell:
--              modulo K_WRAP (wood, stone) or SLANT_CYCLE (metal, glass)}
-- and phase is then the phase of the tile that many tiles further north.  With a table to the south the legs
-- make way for more table top; with one to the north the top's upper edge does.
local function compose(class, piece, phase, vert)
    local c = template[class]
    local out = {}
    local src = c[piece]
    for i = 1, TILE * TILE do out[i] = src[i] end
    if piece == SINGLE and not vert then return out end
    local len = phases * TILE
    local i0, i1, shift = INTERIOR[class][1], INTERIOR[class][2], INTERIOR[class][3]
    local h = i1 - i0 + 1
    local n, s = vert and vert.n, vert and vert.s
    local high, low = vert and vert.high or piece, vert and vert.low or piece
    local v0 = (vert and vert.k or 0) * TILE
    for y = 0, TILE - 1 do
        -- (with a table to the north, `high` is only for the first row: see the inner corner below)
        local p = y < i0 and (not n or y == 0) and high or y >= LEG_ROW and low or piece
        local x0, x1 = extent(p)
        local surface = y >= i0 and y <= i1 or n and y < i0 or s and y > i1
        local d = v0 + y - i0
        local base = y * TILE
        if surface then
            local q, r = d // h, d % h
            if class == CLASS_WOOD and r == PALE_ROW and (n or s or vert and vert.calm) then r = PLAIN_ROW end
            if y < i0 or y > i1 then
                -- a row that is edge or legs on the game's table: the sides of a surface row
                local from = c[p]
                local ref = (i0 + r) * TILE
                for x = 0, TILE - 1 do out[base + x + 1] = from[ref + x + 1] end
            end
            local row = (i0 + r - c.r0) * len
            local x_strip = phase * TILE + q * shift
            for x = x0, x1 do out[base + x + 1] = c.strip[row + (x_strip + x) % len + 1] end
        else
            if p ~= piece then
                local from = c[p]
                for x = 0, TILE - 1 do out[base + x + 1] = from[base + x + 1] end
            end
            if p ~= SINGLE and y >= c.r0 and y <= c.r1 then
                local row = (y - c.r0) * len + phase * TILE
                for x = x0, x1 do out[base + x + 1] = c.strip[row + x + 1] end
            end
        end
    end
    -- An inner corner: the table goes on to the north and to one side, but not diagonally.  The
    -- outline of the side of the part to the north ends in this tile's first row, where it has to
    -- meet the outline along the top of the part to the side.
    if n and high ~= piece then
        if (piece == LEFT or piece == MIDDLE) and (high == SINGLE or high == RIGHT) then out[TILE] = OUTLINE end
        if (piece == RIGHT or piece == MIDDLE) and (high == SINGLE or high == LEFT) then out[1] = OUTLINE end
    end
    -- The same below: the table goes on to the south and to one side, but not diagonally.  The
    -- outline under the part to the side (row 25) has to reach the outline of the side of the
    -- part to the south, which starts a row lower and a pixel in.
    if s and low ~= piece then
        local row = (LEG_ROW - 1) * TILE
        if (piece == LEFT or piece == MIDDLE) and (low == SINGLE or low == RIGHT) then out[row + TILE] = OUTLINE end
        if (piece == RIGHT or piece == MIDDLE) and (low == SINGLE or low == LEFT) then out[row + 1] = OUTLINE end
    end
    if piece == LEFT or piece == RIGHT then
        local x0, x1 = extent(piece)
        for _, e in ipairs(c.ends[phase % END_SETS + 1]) do
            local x = piece == LEFT and x0 + e[1] or x1 - e[1]
            if x >= x0 and x <= x1 and e[2] >= i0 and e[2] <= i1 then
                out[e[2] * TILE + x + 1] = e[3]
            end
        end
    end
    return out
end

-- The pixels of one tile for a tint key; nil without a palette.
local function paint_tile(tint, piece, phase, vert)
    local col = tint_colours(tint)
    if not col then return nil end
    local px = compose(tint & 3, piece, phase, vert)
    for i = 1, TILE * TILE do px[i] = col[px[i]] or 0 end
    return px
end

-- Tiles are painted once and kept: tile key -> texture handle.  They are dropped from the table
-- when the world goes (colour indexes belong to a world's raws) but the textures are never
-- deleted: DFHack does not hand a deleted handle's slot back cleanly.
tile_handles = tile_handles or {}
STATS = STATS or {frames=0, cells=0, tiles=0}
STATS.indexes, STATS.views = STATS.indexes or 0, STATS.views or 0
-- Raised whenever what the drawing code remembers has to go.  (A global, like the two above: a
-- later run of this script as a command is another run of this file with its own locals, and it
-- has to reach the copy the overlay is drawing with.)
GENERATION = GENERATION or 0

-- The texture handle of a tile; nil if it cannot be had.
local K_WRAP = 16     -- a deep table's surface starts over after this many tiles down
local function tile_handle(tint, piece, phase, vert)
    if piece == SINGLE and not vert then phase = 0 end
    local key = tint | piece << 32 | phase << 36
    if vert then
        key = key | (1 | (vert.n and 2 or 0) | (vert.s and 4 or 0) | vert.high << 3 | vert.low << 5 | vert.k << 7 | (vert.calm and 1 or 0) << 12) << 44
    end
    local handle = tile_handles[key]
    if not handle then
        local px = template and paint_tile(tint, piece, phase, vert)
        handle = px and dfhack.textures.createTile(px, TILE, TILE)
        -- a refused texture is left out, so the next draw asks again
        if not handle or handle == 0 then return nil end
        tile_handles[key] = handle
        STATS.tiles = STATS.tiles + 1
    end
    return handle
end

-- (keyed by where this copy lives: DFHack can have two copies of a mod's script loaded, and each
-- has its own caches to empty)
dfhack.onStateChange[NAME .. ':' .. DATA] = function(event)
    if event == SC_WORLD_UNLOADED then
        tint_of_material, tile_handles = {}, {}
        GENERATION = GENERATION + 1
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
    local items = b.contained_items
    if #items == 0 then return nil end
    local item = items[0].item
    return item:getMaterial() << 32 | (item:getMaterialIndex() + 1) & 0xffffffff
end

-- Where a table is on the screen, as one number; depth 0 is the level in view.
local MARGIN = 1       -- tables one row above and below the view are noted too
local function spot(depth, sx, sy)
    return depth << 40 | (sx + 1) << 20 | (sy + MARGIN)
end

-- The building layer of the viewport a depth is drawn in, nil if there is none of the size of
-- the main one.
local function layer(depth, main, lower, dim_x, dim_y)
    local vp = depth == 0 and main or lower[depth - 1]
    if not vp or vp.dim_x ~= dim_x or vp.dim_y ~= dim_y then return nil end
    return vp.screentexpos_building_one
end

-- Asking the game about every table every frame is what costs time, so it is done as seldom as
-- can be, in three steps that each keep what they found:
--
--   the index   where every finished table stands and what it is made of, by level.  Tables do
--               not move or change material, so it is made again only when the game's list of
--               tables changes (its length, or the id the next building will get), when a table
--               that was being built is finished or the removal of one is called off, and every REINDEX_FRAMES frames regardless, for
--               whatever changes a table in a way that does not show in those.
--   the view    for one position of the camera: which cells of the map get which tile.  Made
--               again when the camera, the size of the map on screen or the index changes, when a
--               table in view starts or stops being shown by the game, and every VIEW_FRAMES
--               frames regardless (a table just outside the view can have been revealed).
--   each frame  the cells of the view are checked and written: two lookups per table in view.
local REINDEX_FRAMES = 600
local VIEW_FRAMES = 30

local index             -- [z] = {n=, xs=, ys=, keys=}
local index_count, index_next_id, index_age = -1, -1, 0
local unfinished = {}   -- positions in the game's list of the tables still being built
local removing = {}     -- and of those a dwarf has begun to take apart
local view              -- see make_view()
local generation = -1

-- Is a dwarf taking this table apart?  (Its build stage goes down while that is done.)
local function being_removed(b)
    local jobs = b.jobs
    for i = 0, #jobs - 1 do
        if jobs[i].job_type == df.job_type.DestroyBuilding then return true end
    end
    return false
end

local function index_table(b, i, byz, unfinished, removing)
    -- a table that is being built does not take part; one that is being taken apart does until
    -- it is gone, so a long table is not drawn in pieces while a dwarf works on one end of it
    if b:getBuildStage() < b:getMaxBuildStage() then
        if not being_removed(b) then
            unfinished[#unfinished + 1] = i
            return
        end
        removing[#removing + 1] = i     -- watched: the removal can be called off half way
    end
    local key = material_key(b)
    if not key then return end
    local z = b.z
    local level = byz[z]
    if not level then
        level = {n=0, xs={}, ys={}, keys={}}
        byz[z] = level
    end
    local n = level.n + 1
    level.n, level.xs[n], level.ys[n], level.keys[n] = n, b.centerx, b.centery, key
end

-- Wood: is the west-east run of like tables this one stands in part of a deep table, that is,
-- does any tile of it have a like table to the north or south?  Asked of the index and not of
-- the view, so the answer is the same wherever the camera is; kept per run until the next index.
local function run_is_deep(level, x, y, key)
    local pos = level.pos
    if not pos then
        pos = {}
        local xs, ys, keys = level.xs, level.ys, level.keys
        for i = 1, level.n do pos[xs[i] << 16 | ys[i]] = keys[i] end
        level.pos, level.deep = pos, {}
    end
    local deep = level.deep
    local here = x << 16 | y
    local answer = deep[here]
    if answer == nil then
        local first, last = here, here
        while pos[first - (1 << 16)] == key do first = first - (1 << 16) end
        while pos[last + (1 << 16)] == key do last = last + (1 << 16) end
        answer = false
        for s = first, last, 1 << 16 do
            if pos[s - 1] == key or pos[s + 1] == key then answer = true; break end
        end
        for s = first, last, 1 << 16 do deep[s] = answer end
    end
    return answer
end

local function make_index(v, count, next_id)
    local byz, first_err = {}, nil
    unfinished, removing = {}, {}
    for i = 0, count - 1 do
        local ok, err = pcall(index_table, v[i], i, byz, unfinished, removing)
        if not ok and not first_err then first_err = err end
    end
    index, index_count, index_next_id, index_age = byz, count, next_id, 0
    STATS.indexes = STATS.indexes + 1
    view = nil
    return first_err
end

-- For checking the template against the game's own picture: draw lone tables too, from the
-- template, instead of leaving them to the game (`long-tables singles on`), or draw every
-- table as a lone one (`long-tables singles only`).
draw_singles = draw_singles or false

-- Work out the view: note the material of every finished table the game shows, and of those just
-- off the view (they can be the neighbour of one in view; a table the game does not show does not
-- join: its neighbour would end in nothing), then give every noted table with a like neighbour
-- its piece.
--
-- A view is {wx=, wy=, wz=, dim_x=, dim_y=, singles=, age=, handles={}, texpos={}, levels={...}}
-- and each level {depth=, n=, cell={}, tile={}, hidden={}}: the cells of the tables in view that
-- the game shows, each with the place in `handles` of the texture handle of its tile (false for a
-- table left to the game), and the cells of the tables in view that the game does not show.
local function make_view(wx, wy, wz, dim_x, dim_y, main, lower)
    local mats = {}
    local levels = {}
    local vw = {wx=wx, wy=wy, wz=wz, dim_x=dim_x, dim_y=dim_y, singles=draw_singles, age=0, handles={}, texpos={}, layers={},
                levels=levels}
    local handles, place_of = vw.handles, {}
    local absent = {}       -- depths with tables in view but no layer to draw them in
    vw.absent = absent
    STATS.views = STATS.views + 1
    local visible = dfhack.maps.isTileVisible
    for depth = 0, LOWER_LEVELS do
        local at = index[wz - depth]
        local cells = at and layer(depth, main, lower, dim_x, dim_y)
        if at then
            local lv = {depth=depth, n=0, cell={}, tile={}, hidden={}, sx={}, sy={}, x={}, y={}}
            local xs, ys, keys = at.xs, at.ys, at.keys
            local base = depth << 40 | 1 << 20 | MARGIN
            for i = 1, at.n do
                local x, y = xs[i], ys[i]
                local sx, sy = x - wx, y - wy
                if sx >= -1 and sx <= dim_x and sy >= -MARGIN and sy < dim_y + MARGIN then
                    if sx >= 0 and sx < dim_x and sy >= 0 and sy < dim_y then
                        if not cells then
                            if absent[#absent] ~= depth then absent[#absent + 1] = depth end
                        else
                            local cell = sx * dim_y + sy
                            if cells[cell] == 0 then
                                lv.hidden[#lv.hidden + 1] = cell
                            else
                                mats[base + (sx << 20) + sy] = keys[i]
                                local n = lv.n + 1
                                lv.n, lv.cell[n], lv.tile[n], lv.sx[n], lv.sy[n], lv.x[n], lv.y[n] =
                                    n, cell, false, sx, sy, x, y
                            end
                        end
                    elseif visible(x, y, wz - depth) then
                        -- off the edge there is no cell to tell whether the game shows it
                        mats[base + (sx << 20) + sy] = keys[i]
                    end
                end
            end
            if lv.n > 0 or lv.hidden[1] then levels[#levels + 1] = lv end
        end
    end
    local join = draw_singles ~= 'only'
    local first_err
    for _, lv in ipairs(levels) do
        local depth = lv.depth
        for i = 1, lv.n do
            local sx, sy = lv.sx[i], lv.sy[i]
            local here = spot(depth, sx, sy)
            local key = mats[here]
            local left = join and mats[here - (1 << 20)] == key
            local right = join and mats[here + (1 << 20)] == key
            local north = join and mats[here - 1] == key
            local south = join and mats[here + 1] == key
            if left or right or north or south or draw_singles then
                local piece = piece_of(left, right)
                -- at the leg rows a neighbour is joined to only if it is the same there: both
                -- with a table to the south, or both without.  At the top, a tile that goes on
                -- to the north is joined to a neighbour only if that one does too.
                local high = piece_of(left and (not north or mats[here - (1 << 20) - 1] == key),
                                      right and (not north or mats[here + (1 << 20) - 1] == key))
                local low = piece_of(left and (mats[here - (1 << 20) + 1] == key) == south,
                                     right and (mats[here + (1 << 20) + 1] == key) == south)
                local tint = tint_of(key)
                local vert, k = nil, 0
                local calm = false
                if join and tint & 3 == CLASS_WOOD and not (north or south) then
                    calm = run_is_deep(index[wz - depth], lv.x[i], lv.y[i], key)
                end
                local phase
                if counts_from_map_top(tint & 3) then
                    if north or south or calm or high ~= piece or low ~= piece then
                        k = lv.y[i]
                        vert = {n=north, s=south, high=high, low=low, k=k % K_WRAP, calm=calm or nil}
                    end
                    phase = phase_at(lv.x[i], lv.y[i] - k)
                else
                    local y = lv.y[i]
                    if left or right or north or south then
                        vert = {n=north, s=south, high=high, low=low, k=y % SLANT_CYCLE}
                    end
                    phase = vert and (phase_at(lv.x[i], 0) + SLANT_SHIFT * (y // SLANT_CYCLE)) % phases
                        or phase_at(lv.x[i], y)
                end
                local ok, handle = pcall(tile_handle, tint, piece, phase, vert)
                if ok and handle then
                    local place = place_of[handle]
                    if not place then
                        place = #handles + 1
                        handles[place], place_of[handle] = handle, place
                    end
                    lv.tile[i] = place
                else
                    -- a tile that could not be had is asked for again next frame
                    vw.age = VIEW_FRAMES
                    if not ok and not first_err then first_err = handle end
                end
            end
        end
        lv.sx, lv.sy, lv.x, lv.y = nil, nil, nil, nil
    end
    return vw, first_err
end

-- Put the view's tiles in the map.  False, with nothing written, if the view no longer fits what
-- the game shows.
local function put_view(vw, main, lower)
    local dim_x, dim_y = vw.dim_x, vw.dim_y
    local levels = vw.levels
    local layers = vw.layers
    local absent = vw.absent
    for i = 1, #absent do
        if layer(absent[i], main, lower, dim_x, dim_y) then return false end
    end
    -- first look, then write: a row must not be half drawn when a table of it has gone from view
    for l = 1, #levels do
        local lv = levels[l]
        local cells = layer(lv.depth, main, lower, dim_x, dim_y)
        if not cells then return false end
        layers[l] = cells
        local hidden = lv.hidden
        for i = 1, #hidden do
            if cells[hidden[i]] ~= 0 then return false end
        end
        local cell = lv.cell
        for i = 1, lv.n do
            if cells[cell[i]] == 0 then return false end
        end
    end
    -- (a handle's texture number is asked for every frame: the game can give it another)
    local texpos_of = dfhack.textures.getTexposByHandle
    local handles, texpos = vw.handles, vw.texpos
    for i = 1, #handles do
        local t = texpos_of(handles[i])
        texpos[i] = t and t > 0 and t or false
    end
    local drawn = 0
    for l = 1, #levels do
        local lv = levels[l]
        local cells = layers[l]
        local cell, tile = lv.cell, lv.tile
        for i = 1, lv.n do
            local t = tile[i]
            t = t and texpos[t]
            if t then
                cells[cell[i]] = t
                drawn = drawn + 1
            end
        end
        layers[l] = false      -- (not kept: the game may free a layer)
    end
    STATS.cells = STATS.cells + drawn
    return true
end

local function draw_tables()
    if not template then return end
    if generation ~= GENERATION then
        index, view, generation = nil, nil, GENERATION
    end
    local g = df.global
    local v = g.world.buildings.other.TABLE
    local count = #v
    if count == 0 then
        index, view = nil, nil
        return
    end
    local next_id = g.building_next_id
    index_age = index_age + 1
    local index_err
    if not index or count ~= index_count or next_id ~= index_next_id or index_age > REINDEX_FRAMES then
        index_err = make_index(v, count, next_id)
    else
        local stale = false
        for i = 1, #unfinished do
            local b = v[unfinished[i]]
            if b:getBuildStage() >= b:getMaxBuildStage() then stale = true; break end
        end
        for i = 1, #removing do
            if stale then break end
            local b = v[removing[i]]
            -- called off: it is a table being built now, or whole again
            if b:getBuildStage() >= b:getMaxBuildStage() or not being_removed(b) then stale = true end
        end
        if stale then index_err = make_index(v, count, next_id) end
    end
    local gps = g.gps
    local main, lower = gps.main_viewport, gps.lower_viewport
    local wx, wy, wz = g.window_x, g.window_y, g.window_z
    local dim_x, dim_y = main.dim_x, main.dim_y
    local vw = view
    if vw and vw.age < VIEW_FRAMES and vw.wx == wx and vw.wy == wy and vw.wz == wz and vw.dim_x == dim_x
            and vw.dim_y == dim_y and vw.singles == draw_singles then
        vw.age = vw.age + 1
        if put_view(vw, main, lower) then return end
    end
    local err
    vw, err = make_view(wx, wy, wz, dim_x, dim_y, main, lower)
    view = vw
    -- (right after it is made a view fits, unless a viewport went missing in between)
    if not put_view(vw, main, lower) then view = nil end
    err = index_err or err
    if err then error(err, 0) end
end

LongTablesOverlay = defclass(LongTablesOverlay, overlay.OverlayWidget)
LongTablesOverlay.ATTRS{
    desc='Draws tables standing next to each other, of one material, as one table.',
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
internal = {MARGIN=MARGIN, compose=compose, paint_tile=paint_tile, tint_colours=tint_colours, material_tint=material_tint,
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
        GENERATION = GENERATION + 1
        print(NAME .. ': reloaded ' .. DATA .. 'template.lua')
    elseif args[1] == 'status' and not args[2] then
        print(('%s: template %s, %d frames, %d table cells drawn, %d tiles painted, tables read %d times, view worked out %d times%s')
            :format(NAME, template and 'loaded' or 'MISSING', STATS.frames, STATS.cells, STATS.tiles, STATS.indexes, STATS.views,
                    draw_singles and ', singles ' .. tostring(draw_singles == true and 'on' or draw_singles) or ''))
    elseif args[1] == 'singles' and (args[2] == 'on' or args[2] == 'off' or args[2] == 'only') and not args[3] then
        draw_singles = args[2] == 'only' and 'only' or args[2] == 'on'
        print(NAME .. ': ' .. (draw_singles == 'only' and 'every table is drawn as a lone one, by this script'
            or 'lone tables are drawn by ' .. (draw_singles and 'this script' or 'the game')))
    else
        qerror('usage: ' .. NAME .. ' status | reload | singles on|off|only')
    end
end
