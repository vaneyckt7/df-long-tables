-- Tests for scripts_modinstalled/long-tables.lua with DFHack and the game stubbed.
--   lua test/run_tests.lua [path to the script]
local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local SCRIPT = arg[1] or (here .. '/../scripts_modinstalled/long-tables.lua')

local failures, count = 0, 0
local function check(name, cond, detail)
    count = count + 1
    if not cond then
        failures = failures + 1
        print('FAIL ' .. name .. (detail and (': ' .. tostring(detail)) or ''))
    end
end
local function eq(name, got, want) check(name, got == want, ('got %s, want %s'):format(tostring(got), tostring(want))) end

-- ---- stubs --------------------------------------------------------------------------------------
local function anything()
    local t = {}
    return setmetatable(t, {__index=function() return anything() end, __call=function() return anything() end})
end
local function zeros(n) local t = {}; for i = 0, n - 1 do t[i] = 0 end; return t end
-- a 0-based vector with a length, like the game's
local VEC = {}
local function vec(list) local t = {}; for i, v in ipairs(list) do t[i - 1] = v end; return setmetatable(t, {__len=function() return #list end, vec=VEC}) end
-- DFHack's ipairs walks such a vector from 0
local function df_ipairs(t)
    local mt = getmetatable(t)
    if not (mt and mt.vec == VEC) then return ipairs(t) end
    return function(_, i) i = i + 1; if i < #t then return i, t[i] end end, t, -1
end
local function viewport(dim_x, dim_y) return {dim_x=dim_x, dim_y=dim_y, screentexpos_building_one=zeros(dim_x * dim_y)} end

-- a palette whose shade i is (i, 100 + i, 200 + i), offset by `base` in red
local function palette(base)
    local p = {}
    for i = 0, 17 do p[i * 3], p[i * 3 + 1], p[i * 3 + 2] = base + i, 100 + i, 200 + i end
    return p
end

local DIM_X, DIM_Y = 25, 17
local W
local function new_world()
    W = {tables={}, building_next_id=0, next_handle=0, pixels={}, unrevealed={}, window_x=100, window_y=50, window_z=10}
    W.gps = {main_viewport=viewport(DIM_X, DIM_Y), lower_viewport={}, default_palette={color=palette(0)}}
    for i = 0, 7 do W.gps.lower_viewport[i] = viewport(DIM_X, DIM_Y) end
    -- like the game's fixed array of eight: any other index is an error
    setmetatable(W.gps.lower_viewport, {__index=function(_, i) if math.type(i) ~= 'integer' or i < 0 or i > 7 then error('index out of bounds') end end})
    -- colour 0 belongs to pattern 0 ... colour 3 to pattern 3
    W.descriptors = {colors=vec{}, patterns=vec{}}
    local colors, patterns = {}, {}
    for c = 0, 3 do
        colors[c + 1] = {palette={color=palette(10 * (c + 1))}}
        patterns[c + 1] = {colors=vec{c}}
    end
    W.descriptors = {colors=vec(colors), patterns=vec(patterns)}
    -- materials: type 0 index n
    W.materials = {
        ['0:0'] = {material={flags={IS_STONE=true}, state_color={Solid=0}}},     -- stone, colour 0
        ['0:1'] = {material={flags={IS_STONE=true}, state_color={Solid=1}}},     -- another stone
        ['0:2'] = {material={flags={IS_METAL=true}, state_color={Solid=2}}},
        ['3:0'] = {material={flags={IS_GLASS=true}, state_color={Solid=3}}},
        ['420:7'] = {material={flags={WOOD=true}, state_color={Solid=0}}},
        ['0:5'] = {material={flags={IS_STONE=true}, state_color={Solid=0}}},     -- a third stone, coloured like the first
        ['-1:-1'] = {material={flags={IS_METAL=true}, state_color={Solid=2}}},
        ['0:9'] = {material={flags={IS_STONE=true}, state_color={Solid=-1}}},    -- no colour in the raws
    }
end

-- puts the cell the game would have filled, too, unless opts.hidden
local function add_table(x, y, z, mat, opts)
    opts = opts or {}
    local b = {id=#W.tables + 1, centerx=x, centery=y, z=z, contained_items=vec{}, jobs=vec(opts.unfinished and {{job_type=68}} or {})}   -- a table being built has its building job
    function b:getBuildStage() return opts.unfinished and 0 or 1 end
    function b:getMaxBuildStage() return 1 end
    if mat then
        local item = {}
        function item:getMaterial() return mat[1] end
        function item:getMaterialIndex() return mat[2] end
        b.contained_items = vec{{item=item}}
    end
    if opts.unrevealed then W.unrevealed[x .. ',' .. y .. ',' .. z] = true end
    if opts.broken then function b:getBuildStage() error('broken table') end end
    W.tables[#W.tables + 1] = b
    W.building_next_id = W.building_next_id + 1      -- as the game does for every new building
    local depth = W.window_z - z
    local sx, sy = x - W.window_x, y - W.window_y
    if not opts.hidden and depth >= 0 and depth <= 8 and sx >= 0 and sx < DIM_X and sy >= 0 and sy < DIM_Y then
        local vp = depth == 0 and W.gps.main_viewport or W.gps.lower_viewport[depth - 1]
        vp.screentexpos_building_one[sx * DIM_Y + sy] = 7     -- the game's picture
    end
    return b
end
local function cell(x, y, depth)
    local vp = (depth or 0) == 0 and W.gps.main_viewport or W.gps.lower_viewport[depth - 1]
    return vp.screentexpos_building_one[(x - W.window_x) * DIM_Y + (y - W.window_y)]
end

local function load_script(template_dir)
    local env = setmetatable({}, {__index=_G})
    env.dfhack_flags = {module=true}
    env.ipairs = df_ipairs
    env.SC_MAP_LOADED, env.SC_WORLD_UNLOADED = 1, 2
    env.require = function() return anything() end
    env.defclass = function() return anything() end
    env.dfhack = {
        onStateChange={},
        printerr=function(msg) W.printed = msg end,
        findScript=function() return SCRIPT end,
        maps={isTileVisible=function(x, y, z) return not W.unrevealed[x .. ',' .. y .. ',' .. z] end},
        matinfo={decode=function(t, i) return W.materials[t .. ':' .. i] end},
        textures={
            createTile=function(px)
                if W.refuse_textures then return W.refuse_textures == 'zero' and 0 or nil end
                W.next_handle = W.next_handle + 1
                W.pixels[W.next_handle] = px
                return W.next_handle
            end,
            getTexposByHandle=function(h) if W.no_texpos then return 0 end; return 1000 + h end,
        },
    }
    env.df = {job_type={DestroyBuilding=9, ConstructBuilding=68}, global=setmetatable({}, {__index=function(_, k)
        if k == 'gps' then return W.gps end
        if k == 'world' then return {buildings={other={TABLE=vec(W.tables)}}, raws={descriptors=W.descriptors}} end
        return W[k]
    end})}
    if template_dir then
        local real = dofile
        env.dofile = function(path) return real(template_dir .. '/template.lua') end
    end
    local chunk = assert(loadfile(SCRIPT, 't', env))
    chunk()
    return env
end
-- what kind of tile a texpos is: the handle's pixels
local function pixels(texpos) return W.pixels[texpos - 1000] end
local function rgba(c) return c & 0xff, c >> 8 & 0xff, c >> 16 & 0xff, c >> 24 end

new_world()
local m = load_script()
local I = m.internal
local PH = I.phases()
local STONE, GLASS = {0, 0}, {3, 0}

-- ---- the template -------------------------------------------------------------------------------
check('template loaded', PH and PH >= 8, PH)
do
    -- class 0 wood, 1 stone, 2 metal, 3 glass; piece 0 alone, 1 left, 2 middle, 3 right
    for class = 0, 3 do
        local s, l, mid, r = I.compose(class, 0, 0), I.compose(class, 1, 0), I.compose(class, 2, 0), I.compose(class, 3, 0)
        local function at(t, x, y) return t[y * 32 + x + 1] end
        eq('1024 codes ' .. class, #mid, 1024)
        -- a lone table has a clear column on the left; a joined piece has table there
        eq('single: clear at the left edge ' .. class, at(s, 0, 10), I.CLEAR)
        eq('left end keeps its edge ' .. class, at(l, 0, 10), I.CLEAR)
        check('left end: table up to the right edge ' .. class, at(l, 31, 10) >= 0 and at(l, 31, 10) ~= I.SHADOW)
        check('middle: table at both edges ' .. class, at(mid, 0, 10) >= 0 and at(mid, 31, 10) >= 0 and at(mid, 31, 10) ~= I.SHADOW)
        check('right end: table at the left edge ' .. class, at(r, 0, 10) >= 0)
        eq('right end keeps its shadow ' .. class, at(r, 31, 10), at(s, 31, 10))
        -- legs: rows 26..30 hold a leg at columns 3..8 and 23..28 on the lone table
        eq('single: left leg ' .. class, at(s, 5, 28) >= 0 and at(s, 5, 28) < 9, true)
        eq('single: under the middle is shadow ' .. class, at(s, 15, 28), I.SHADOW)
        -- a join has half a leg on each tile and no leg next to it
        check('left end: half a leg at the seam ' .. class, at(l, 30, 28) >= 0 and at(l, 30, 28) < 9 and at(l, 31, 28) < 9)
        eq('left end: no leg of its own on the right ' .. class, at(l, 25, 28), I.SHADOW)
        check('left end keeps its left leg ' .. class, at(l, 5, 28) < 9 and at(l, 5, 28) >= 0)
        check('middle: half legs at both seams ' .. class, at(mid, 0, 28) >= 0 and at(mid, 0, 28) < 9 and at(mid, 31, 28) >= 0 and at(mid, 31, 28) < 9)
        eq('middle: no legs of its own ' .. class, at(mid, 5, 28) == I.SHADOW and at(mid, 25, 28) == I.SHADOW, true)
        check('right end keeps its right leg ' .. class, at(r, 25, 28) < 9 and at(r, 25, 28) >= 0)
        -- the two halves make the leg of the lone table: outline, fill, outline over 6 pixels
        local seam = {at(l, 29, 28), at(l, 30, 28), at(l, 31, 28), at(r, 0, 28), at(r, 1, 28), at(r, 2, 28)}
        local leg = {}
        for x = 3, 8 do leg[#leg + 1] = at(s, x, 28) end
        eq('seam leg is the game\'s leg ' .. class, table.concat(seam, ','), table.concat(leg, ','))
        -- the outline along the top and under the top runs through
        eq('middle: top outline at the edges ' .. class, at(mid, 0, 0) == 0 and at(mid, 31, 0) == 0, true)
        eq('middle: outline under the top ' .. class, at(mid, 0, 25) == 0 and at(mid, 31, 25) == 0, true)
        -- no code the painter does not know
        for _, t in ipairs{s, l, mid, r} do
            for i = 1, 1024 do
                if not (t[i] >= -1 and t[i] <= 21) then check('codes in range ' .. class, false, t[i]); break end
            end
        end
    end
    -- neighbouring phases show consecutive stretches of the strip: the middle of phase p+1 is not
    -- that of phase p, and all phases of a metal table differ
    local seen = {}
    for p = 0, PH - 1 do seen[table.concat(I.compose(2, 2, p), ',')] = true end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    eq('every phase of a metal middle is different', n, PH)
    eq('a lone table has no phases', table.concat(I.compose(1, 0, 0)), table.concat(I.compose(1, 0, 5)))
    -- wood: every pixel of the strip rows comes from the game's own board
    local w = I.compose(0, 2, 3)
    for i = 1, 1024 do if w[i] > 8 and w[i] ~= I.SHADOW then check('wood uses the first ramp only', false, w[i]); break end end
    -- the bright lines along the edges of the top are softened between the ends of a joined table
    for class, rows in pairs{[1]={1, 21}, [2]={1, 23}, [3]={1, 23}} do
        local s, l, mid, r = I.compose(class, 0, 0), I.compose(class, 1, 4), I.compose(class, 2, 4), I.compose(class, 3, 4)
        for _, y in ipairs(rows) do
            local bright, soft = 0, 0
            for x = 0, 31 do
                if s[y * 32 + x + 1] == 17 then bright = bright + 1 end
                local c = mid[y * 32 + x + 1]
                if c == 16 or c == I.FAINT or c == I.HALF then soft = soft + 1 end
            end
            check('a lone table keeps its bright edge ' .. class .. ' row ' .. y, bright > 0)
            eq('a middle has a soft edge ' .. class .. ' row ' .. y, soft, 32)
            eq('the left end keeps its corner ' .. class .. ' row ' .. y, l[y * 32 + 2 + 1], s[y * 32 + 2 + 1])
            eq('the right end keeps its corner ' .. class .. ' row ' .. y, r[y * 32 + 29 + 1], s[y * 32 + 29 + 1])
        end
    end
    -- stone ends get extra speckles the middle does not have
    local function dark(t) local k = 0; for y = 3, 18 do for x = 3, 16 do local c = t[y * 32 + x + 1]; if c == 14 or c == I.BLEND then k = k + 1 end end end return k end
    local l0, m0 = dark(I.compose(1, 1, 0)), dark(I.compose(1, 2, 0))
    check('stone left end is more speckled than the same stretch in the middle', l0 > m0, l0 .. ' vs ' .. m0)
    -- the strip is laid row for row, and on an end piece right up to the end's own 3 pixels
    local tpl = I.template()
    for class = 0, 3 do
        local c = tpl[class]
        local len = PH * 32
        for _, ph in ipairs{0, 5} do
            local l, mid, r = I.compose(class, 1, ph), I.compose(class, 2, ph), I.compose(class, 3, ph)
            local bad_mid, bad_l, bad_r = 0, 0, 0
            for y = c.r0, c.r1 do
                -- stone ends carry extra speckles on rows 3..18; the other rows are pure strip
                local pure = #c.ends[1] == 0 or y < 3 or y > 18
                for x = 0, 31 do
                    local want = c.strip[(y - c.r0) * len + ph * 32 + x + 1]
                    if mid[y * 32 + x + 1] ~= want then bad_mid = bad_mid + 1 end
                    if pure and x >= 3 and l[y * 32 + x + 1] ~= want then bad_l = bad_l + 1 end
                    if pure and x <= 28 and r[y * 32 + x + 1] ~= want then bad_r = bad_r + 1 end
                end
            end
            eq('middle is the strip, row for row ' .. class .. ' phase ' .. ph, bad_mid, 0)
            eq('left end is strip from x 3 ' .. class .. ' phase ' .. ph, bad_l, 0)
            eq('right end is strip to x 28 ' .. class .. ' phase ' .. ph, bad_r, 0)
        end
    end
    -- stone end speckles: each phase uses its own set, mirrored on the right end
    do
        local c = tpl[1]
        local len = PH * 32
        check('several sets of end speckles', #c.ends >= 2, #c.ends)
        check('the sets differ', #c.ends[1] ~= #c.ends[2] or c.ends[1][1][1] ~= c.ends[2][1][1] or c.ends[1][1][2] ~= c.ends[2][1][2])
        for ph = 0, #c.ends do
            local set = c.ends[ph % #c.ends + 1]
            for piece, xof in pairs{[1]=function(o) return 3 + o end, [3]=function(o) return 28 - o end} do
                local want = {}
                for y = c.r0, c.r1 do for x = 0, 31 do want[y * 32 + x + 1] = c.strip[(y - c.r0) * len + ph * 32 + x + 1] end end
                for _, e in ipairs(set) do want[e[2] * 32 + xof(e[1]) + 1] = e[3] end
                local got, bad = I.compose(1, piece, ph), 0
                for y = 3, 18 do for x = 3, 28 do if got[y * 32 + x + 1] ~= want[y * 32 + x + 1] then bad = bad + 1 end end end
                eq('stone end speckles, piece ' .. piece .. ' phase ' .. ph, bad, 0)
            end
        end
    end
    eq('phase follows x', (I.phase_at(11, 4) - I.phase_at(10, 4)) % PH, 1)
    check('rows start at different phases', I.phase_at(10, 4) ~= I.phase_at(10, 5))
end

-- ---- painting -----------------------------------------------------------------------------------
do
    local col = I.tint_colours(1)      -- default palette, stone
    local r, g, b, a = rgba(col[0]); check('shade 0', r == 0 and g == 100 and b == 200 and a == 255)
    r, g, b, a = rgba(col[17]); check('shade 17', r == 17 and g == 117 and b == 217 and a == 255)
    r, g, b, a = rgba(col[I.SHADOW]); check('shadow is shade 0 at half strength, not premultiplied', r == 0 and g == 100 and b == 200 and a == 128, a)
    r = rgba(col[I.BLEND]); eq('blend is between 14 and 15', r, 14)
    r = rgba(col[I.FAINT]); eq('faint is near 15', r, 15)
    do  -- the in-between shades, on a palette with room between 14, 15 and 16, all three channels
        local keep = W.gps.default_palette.color
        local p = palette(0)
        p[14 * 3], p[14 * 3 + 1], p[14 * 3 + 2] = 20, 30, 50
        p[15 * 3], p[15 * 3 + 1], p[15 * 3 + 2] = 40, 80, 120
        p[16 * 3], p[16 * 3 + 1], p[16 * 3 + 2] = 60, 120, 200
        W.gps.default_palette.color = p
        local c2 = I.tint_colours(1)
        local function is(name, code, wr, wg, wb)
            local r2, g2, b2, a2 = rgba(c2[code])
            check(name, r2 == wr and g2 == wg and b2 == wb and a2 == 255, ('%d %d %d %d'):format(r2, g2, b2, a2))
        end
        is('blend is halfway from 14 to 15', I.BLEND, 30, 55, 85)
        is('faint is a quarter from 15 to 16', I.FAINT, 45, 90, 140)
        is('half is halfway from 15 to 16', I.HALF, 50, 100, 160)
        W.gps.default_palette.color = keep
    end
    col = I.tint_colours((0 + 1) * 4 + 1)      -- colour 0: red 10 + shade
    r = rgba(col[I.HALF]); eq('half is between 15 and 16', r, 25)
    col = I.tint_colours(1)
    col = I.tint_colours((2 + 1) * 4 + 2)      -- colour 2
    r = rgba(col[3]); eq('a material colour uses its own palette', r, 33)
    eq('no palette for a colour the world lacks', I.tint_colours((99 + 1) * 4), nil)
    local px = I.paint_tile(1, 2, 0)
    eq('painted tile size', #px, 1024)
    local clear, opaque, half = 0, 0, 0
    for i = 1, 1024 do
        local alpha = px[i] >> 24
        if px[i] == 0 then clear = clear + 1 elseif alpha == 255 then opaque = opaque + 1 elseif alpha == 128 then half = half + 1 else check('alpha', false, alpha) end
    end
    check('a middle piece is table and shadow', clear == 0 and opaque > 600 and half > 100, clear .. ' ' .. opaque .. ' ' .. half)
    eq('tint: stone colour 0', I.material_tint(0, 0), 1 * 4 + 1)
    eq('tint: metal colour 2', I.material_tint(0, 2), 3 * 4 + 2)
    eq('tint: glass colour 3', I.material_tint(3, 0), 4 * 4 + 3)
    eq('tint: wood colour 0', I.material_tint(420, 7), 1 * 4 + 0)
    eq('tint: no colour in the raws', I.material_tint(0, 9), 1)
    eq('tint: unknown material', I.material_tint(5, 5), 1)
end

-- ---- which tables join --------------------------------------------------------------------------
local function fresh() new_world(); m = load_script(); I = m.internal end
-- 'S' the game's own picture, else the piece, read from the legs: L has a leg on the left only...
local function kind(x, y, depth)
    local t = cell(x, y, depth)
    if t == 7 then return 'S' end
    if t == 0 then return '-' end
    local px = pixels(t)
    local function leg(col) return px[28 * 32 + col + 1] >> 24 == 255 end
    local own_left, own_right, seam_left, seam_right = leg(5), leg(25), leg(0), leg(31)
    if own_left and seam_right and not own_right and not seam_left then return 'L' end
    if seam_left and seam_right and not own_left and not own_right then return 'M' end
    if seam_left and own_right and not own_left and not seam_right then return 'R' end
    if own_left and own_right then return 's' end      -- a lone table drawn from the template
    return '?'
end
local function row(x0, x1, y, depth) local s = ''; for x = x0, x1 do s = s .. kind(x, y, depth) end; return s end

do
    fresh()
    for x = 110, 114 do add_table(x, 55, 10, STONE) end           -- five in a row
    add_table(116, 55, 10, STONE)                                 -- alone, one tile further
    add_table(110, 57, 10, STONE); add_table(111, 57, 10, STONE)  -- a pair
    add_table(113, 59, 10, STONE); add_table(114, 59, 10, {0, 1}) -- two stones side by side
    add_table(116, 59, 10, STONE); add_table(117, 59, 10, GLASS)  -- stone and glass
    I.draw_tables()
    eq('five in a row', row(110, 114, 55), 'LMMMR')
    eq('a table one tile off is alone', kind(116, 55), 'S')
    eq('a pair', row(110, 111, 57), 'LR')
    eq('different stones do not join', row(113, 114, 59), 'SS')
    eq('stone and glass do not join', row(116, 117, 59), 'SS')
    eq('empty cells stay empty', cell(112, 56), 0)
    -- every tile of the five is painted with the stone palette of colour 0 (red 10 + shade)
    local r = rgba(pixels(cell(112, 55))[10 * 32 + 16 + 1])
    check('painted in the material\'s colour', r >= 10 + 9 and r <= 10 + 17, r)
    local tiles = W.next_handle
    I.draw_tables()
    eq('a second frame paints nothing new', W.next_handle, tiles)
end

do  -- mixed materials in one row: runs split where the material changes
    fresh()
    for x = 110, 112 do add_table(x, 55, 10, STONE) end
    for x = 113, 114 do add_table(x, 55, 10, GLASS) end
    add_table(115, 55, 10, STONE)
    I.draw_tables()
    eq('runs split by material', row(110, 115, 55), 'LMRLRS')
    local stone, glass = rgba(pixels(cell(111, 55))[10 * 32 + 16 + 1]), rgba(pixels(cell(113, 55))[10 * 32 + 16 + 1])
    check('each run in its own colour', stone < 40 and glass >= 40, stone .. ' ' .. glass)
end

do  -- tables the game does not show, unfinished ones, ones without an item
    fresh()
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE, {hidden=true}); add_table(112, 55, 10, STONE)
    add_table(110, 57, 10, STONE); add_table(111, 57, 10, STONE, {unfinished=true}); add_table(112, 57, 10, STONE)
    add_table(110, 59, 10, STONE); add_table(111, 59, 10, nil)
    I.draw_tables()
    eq('a hidden table is not drawn and does not join', row(110, 112, 55), 'S-S')
    eq('an unfinished table keeps the game\'s picture and does not join', row(110, 112, 57), 'SSS')
    eq('a table without an item does not join', row(110, 111, 59), 'SS')
end

do  -- the edges of the view
    fresh()
    add_table(99, 55, 10, STONE); add_table(100, 55, 10, STONE)                  -- neighbour just off the left edge
    add_table(124, 56, 10, STONE); add_table(125, 56, 10, STONE)                 -- ... off the right edge
    add_table(98, 57, 10, STONE); add_table(100, 57, 10, STONE)                  -- two off: not a neighbour
    add_table(110, 49, 10, STONE); add_table(111, 49, 10, STONE)                 -- above the view
    add_table(110, 67, 10, STONE); add_table(111, 67, 10, STONE)                 -- below the view
    add_table(124, 66, 10, STONE); add_table(123, 66, 10, STONE)                 -- last row, last columns
    local before = {}
    for i = 0, DIM_X * DIM_Y - 1 do before[i] = W.gps.main_viewport.screentexpos_building_one[i] end
    I.draw_tables()
    eq('joins a neighbour off the left edge', kind(100, 55), 'R')
    eq('joins a neighbour off the right edge', kind(124, 56), 'L')
    eq('two tiles off is no neighbour', kind(100, 57), 'S')
    eq('bottom right corner', row(123, 124, 66), 'LR')
    local changed, n = 0, 0
    for i = 0, DIM_X * DIM_Y - 1 do
        n = n + 1
        if W.gps.main_viewport.screentexpos_building_one[i] ~= before[i] then changed = changed + 1 end
    end
    eq('only the four cells in view changed', changed, 4)
    local vp = W.gps.main_viewport.screentexpos_building_one
    check('nothing written outside the layer', vp[-1] == nil and vp[DIM_X * DIM_Y] == nil and vp[-DIM_Y + 5] == nil)
end

do  -- levels below
    fresh()
    for depth = 1, 8 do add_table(110, 55, 10 - depth, STONE); add_table(111, 55, 10 - depth, STONE) end
    add_table(110, 57, 1, STONE); add_table(111, 57, 1, STONE)       -- nine down: not drawn by the game
    add_table(110, 59, 11, STONE); add_table(111, 59, 11, STONE)     -- above the view
    add_table(113, 55, 10, STONE); add_table(114, 55, 9, STONE)      -- side by side on the screen, a level apart
    I.draw_tables()
    for depth = 1, 8 do eq('joined ' .. depth .. ' below', row(110, 111, 55, depth), 'LR') end
    eq('main level untouched by lower tables', cell(110, 55), 0)
    eq('tables on different levels do not join', kind(113, 55) .. kind(114, 55, 1), 'SS')
    W.gps.lower_viewport[3] = nil
    I.draw_tables()       -- a missing lower layer is skipped
    W.gps.lower_viewport[2] = viewport(10, 10)
    I.draw_tables()       -- and so is one of another size
end

do  -- trouble: a broken table, refused textures, a missing template
    fresh()
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE)
    add_table(113, 55, 10, STONE, {broken=true})
    local ok, err = pcall(I.draw_tables)
    check('a broken table is reported', not ok and tostring(err):find('broken table'), err)
    eq('and the others are drawn', row(110, 111, 55), 'LR')

    fresh()
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE)
    W.refuse_textures = true
    I.draw_tables()
    eq('without a texture the game\'s picture stays', row(110, 111, 55), 'SS')
    W.refuse_textures = false
    I.draw_tables()
    eq('and it is asked for again', row(110, 111, 55), 'LR')

    fresh()
    add_table(110, 55, 10, {0, 9}); add_table(111, 55, 10, {0, 9})
    I.draw_tables()
    eq('a material without a colour is drawn in the default palette', row(110, 111, 55), 'LR')
    local r = rgba(pixels(cell(110, 55))[10 * 32 + 16 + 1])
    check('default palette', r >= 9 and r <= 17, r)

    new_world()
    m = load_script('/nonexistent')
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE)
    check('a missing template is said', W.printed and W.printed:find('could not read'), W.printed)
    m.internal.draw_tables()
    eq('and tables keep the game\'s picture', row(110, 111, 55), 'SS')
end

-- ---- tables one above the other -------------------------------------------------------------------
do
    fresh()
    local T = I.template()
    local function same(a, b) for i = 1, 1024 do if a[i] ~= b[i] then return false end end return true end
    local function at(t, x, y) return t[y * 32 + x + 1] end
    local function opaque_top(c) return c ~= I.CLEAR and c ~= I.SHADOW end
    for class = 0, 3 do
        local name = ({[0]='wood', 'stone', 'metal', 'glass'})[class]
        local lone = I.compose(class, 0, 0)
        local top = I.compose(class, 0, 3, {n=false, s=true, high=0, low=0, k=0})
        local bottom = I.compose(class, 0, 3, {n=true, s=false, high=0, low=0, k=1})
        local ok = true
        for y = 26, 31 do for x = 3, 28 do ok = ok and opaque_top(at(top, x, y)) and at(top, x, y) ~= 0 end end
        check(name .. ': with a table to the south the legs make way for table top', ok)
        ok = true
        local a0, a1 = 3, 18
        if class >= 2 then a0, a1 = 2, 20 end
        for y = 26, 31 do
            local ref = a0 + (y - a0) % (a1 - a0 + 1)      -- the surface row shown there
            ok = ok and at(top, 0, y) == at(lone, 0, ref) and at(top, 30, y) == at(lone, 30, ref)
        end
        check(name .. ': and the sides of the top run on down', ok)
        ok = true
        for x = 0, 31 do ok = ok and at(top, x, 0) == at(lone, x, 0) end
        check(name .. ': the top of a column keeps its upper edge', ok)
        ok = true
        for x = 3, 28 do ok = ok and at(bottom, x, 0) ~= 0 and opaque_top(at(bottom, x, 0)) end
        check(name .. ': with a table to the north the upper edge makes way', ok)
        ok = true
        for y = 26, 31 do for x = 0, 31 do ok = ok and at(bottom, x, y) == at(lone, x, y) end end
        check(name .. ': the bottom of a column keeps its legs', ok)
        -- the surface is the strip, gone through again and again, shifted each time
        local c = T[class]
        local i0, i1 = 3, 18
        local shift = 80
        if class >= 2 then i0, i1, shift = 2, 20, 19 end
        local h, len = i1 - i0 + 1, I.phases() * 32
        ok = true
        for k = 0, 2 do
            local t = I.compose(class, 2, 3, {n=true, s=true, high=2, low=2, k=k})
            for y = 0, 31 do
                local d = k * 32 + y - i0
                local q, r = d // h, d % h
                if class == 0 and r == 13 then r = 8 end      -- wood: the pale streak is left out
                for x = 0, 31 do
                    ok = ok and at(t, x, y) == c.strip[(i0 + r - c.r0) * len + (3 * 32 + q * shift + x) % len + 1]
                end
            end
        end
        check(name .. ': the inside of a deep table is the strip, row after row', ok)
    end
    -- wood and stone: a deep tile shows, on its surface rows, what the same tile shows in a plain row
    for class = 0, 1 do
        local ok = true
        for y = 0, 17 do
            local deep = I.compose(class, 2, I.phase_at(7, 0), {n=true, s=true, high=2, low=2, k=y % 16})
            local flat = I.compose(class, 2, I.phase_at(7, y))
            for row = 3, 18 do for x = 0, 31 do
                ok = ok and (at(deep, x, row) == at(flat, x, row) or class == 0 and row == 16)
            end end
        end
        check('class ' .. class .. ': deep and plain tiles show the same surface', ok)
    end
    do  -- wood: no row of a deep tile is the long pale streak (sprite row 16: seventeen 7s in a row)
        local deep = I.compose(0, 2, 0, {n=true, s=true, high=2, low=2, k=0})
        local longest = 0
        for y = 0, 31 do
            local run = 0
            for x = 0, 31 do
                run = at(deep, x, y) == 7 and run + 1 or 0
                if run > longest then longest = run end
            end
        end
        check('wood: no long pale streak in a deep tile', longest < 12, longest)
    end
    -- an inner corner: joined to the east, table to the north, nothing to the north-east
    local corner = I.compose(1, 1, 0, {n=true, s=false, high=0, low=1, k=1})
    eq('inner corner: the outline reaches the tile\'s edge in the first row', at(corner, 31, 0), 0)
    eq('inner corner: and only there', at(corner, 31, 1) ~= 0 and at(corner, 30, 1) ~= 0, true)

    for class = 0, 3 do
        for k = 0, 15 do
            local t = I.compose(class, 1, 0, {n=true, s=false, high=0, low=1, k=k})
            if at(t, 31, 0) ~= 0 then check('class ' .. class .. ' inner corner closed at depth ' .. k, false) end
        end
        -- the same below: joined to the west, table to the south, nothing to the south-west
        local t = I.compose(class, 3, 0, {n=false, s=true, high=3, low=0, k=0})
        eq('class ' .. class .. ': lower inner corner, west', at(t, 0, 25), 0)
        check('class ' .. class .. ': lower inner corner, west: only that pixel', at(t, 1, 25) ~= 0)
        t = I.compose(class, 1, 0, {n=false, s=true, high=1, low=0, k=0})
        eq('class ' .. class .. ': lower inner corner, east', at(t, 31, 25), 0)
        t = I.compose(class, 2, 0, {n=false, s=true, high=2, low=2, k=0})
        check('class ' .. class .. ': no corner inside a block', at(t, 0, 25) ~= 0 and at(t, 31, 25) ~= 0)
    end
    -- metal and glass: the surface of a tile is the same whatever the table's shape, and the rows
    -- carry on from one tile to the one below it, also across the 19-tile cycle
    for class = 2, 3 do
        local h, len = 19, PH * 32
        local function surf(x, y, v)      -- strip position of pixel 5 of surface row 0, via equality of tiles
            return I.compose(class, 2, (I.phase_at(x, 0) + 19 * (y // 19)) % PH, v)
        end
        for _, y in ipairs{0, 1, 18, 19, 37, 38, 100} do
            local k = y % 19
            local arm = surf(40, y, {n=false, s=false, high=2, low=2, k=k})
            local deep = surf(40, y, {n=true, s=true, high=2, low=2, k=k})
            local ok = true
            for py = 2, 20 do for px = 0, 31 do if at(arm, px, py) ~= at(deep, px, py) then ok = false end end end
            check('class ' .. class .. ': arm and deep tile agree at row ' .. y, ok)
            -- the tile below, shifted back by the slant, continues this one: its row 0 is what
            -- this tile's row 32 would be
            local below = surf(40, y + 1, {n=true, s=true, high=2, low=2, k=(y + 1) % 19})
            local d = k * 32 + 32 - 2
            local q, r = d // h, d % h
            local phase = (I.phase_at(40, 0) + 19 * (y // 19)) % PH
            local strip = I.template()[class].strip
            local r0 = I.template()[class].r0
            local same_row = true
            for px = 0, 31 do
                if at(below, px, 0) ~= strip[(2 + r - r0) * len + (phase * 32 + q * 19 + px) % len + 1] then same_row = false end
            end
            check('class ' .. class .. ': row ' .. y .. ' carries on into the tile below', same_row)
        end
    end
    -- which picture each tile of a shape gets
    local function vert(n, s, high, low, k) return {n=n, s=s, high=high, low=low, k=k} end
    local function is(name, x, y, mat, piece, v, ky)
        local tint = I.material_tint(mat[1], mat[2])
        eq(name, cell(x, y) ~= 7 and same(pixels(cell(x, y)), I.paint_tile(tint, piece, I.phase_at(x, y - ky), v)), true)
    end
    -- metal and glass: every joined tile is counted down from map row 0, 19 tiles to a cycle
    local function isg(name, x, y, piece, n, s, high, low)
        local tint = I.material_tint(GLASS[1], GLASS[2])
        local want = I.paint_tile(tint, piece, (I.phase_at(x, 0) + 19 * (y // 19)) % PH, vert(n, s, high, low, y % 19))
        eq(name, cell(x, y) ~= 7 and same(pixels(cell(x, y)), want), true)
    end
    add_table(110, 59, 10, GLASS); add_table(110, 60, 10, GLASS); add_table(110, 61, 10, GLASS)   -- a column
    add_table(113, 59, 10, GLASS); add_table(113, 60, 10, STONE)                                  -- glass over stone
    -- an L of stone: 116,56 / 116,57 / 116,58 117,58
    add_table(116, 56, 10, STONE); add_table(116, 57, 10, STONE); add_table(116, 58, 10, STONE); add_table(117, 58, 10, STONE)
    -- a T of glass: 119..121,60 and 120,61
    for x = 119, 121 do add_table(x, 60, 10, GLASS) end
    add_table(120, 61, 10, GLASS)
    -- a block of glass, two by two
    for x = 119, 120 do for y = 56, 57 do add_table(x, y, 10, GLASS) end end
    -- a column that starts above the view (the view's first row is 50)
    add_table(105, 48, 10, GLASS); add_table(105, 49, 10, GLASS); add_table(105, 50, 10, GLASS)
    I.draw_tables()
    isg('column: top', 110, 59, 0, false, true, 0, 0)
    isg('column: middle', 110, 60, 0, true, true, 0, 0)
    isg('column: bottom', 110, 61, 0, true, false, 0, 0)
    eq('glass over stone does not join', cell(113, 59) .. ':' .. cell(113, 60), '7:7')
    is('L: top of the upright', 116, 56, STONE, 0, vert(false, true, 0, 0, 56 % 16), 56)
    is('L: corner', 116, 58, STONE, 1, vert(true, false, 0, 1, 58 % 16), 58)
    is('L: foot is a plain right end', 117, 58, STONE, 3, nil, 0)
    isg('T: left arm has no leg at the stem', 119, 60, 1, false, false, 1, 0)
    isg('T: middle of the bar', 120, 60, 2, false, true, 2, 0)
    isg('T: stem', 120, 61, 0, true, false, 0, 0)
    isg('block: top left', 119, 56, 1, false, true, 1, 1)
    isg('block: bottom right', 120, 57, 3, true, false, 3, 3)
    isg('a column from above the view fits the map pattern', 105, 50, 0, true, false, 0, 0)
    do  -- wood: the arms of a T lose the pale streak too; a plain row keeps it
        local WOOD = {420, 7}
        for x = 100, 104 do add_table(x, 64, 10, WOOD) end
        add_table(102, 65, 10, WOOD)
        for x = 107, 111 do add_table(x, 64, 10, WOOD) end
        I.draw_tables()
        local function streak(x, y)
            local px, col = pixels(cell(x, y)), I.tint_colours(I.material_tint(420, 7))
            local longest, run = 0, 0
            for i = 0, 31 do
                run = px[16 * 32 + i + 1] == col[7] and run + 1 or 0
                if run > longest then longest = run end
            end
            return longest
        end
        local worst, best = 0, 0
        for x = 100, 104 do worst = math.max(worst, streak(x, 64)) end
        for x = 107, 111 do best = math.max(best, streak(x, 64)) end
        check('wood T: no pale streak along the bar', worst < 12, worst)
        check('wood row: the pale streak stays', best >= 12, best)
    end
    local tiles = W.next_handle
    I.draw_tables()
    eq('deep tables: a second frame paints nothing new', W.next_handle, tiles)
end

do  -- found by review
    fresh()
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, {0, 5})                 -- same colour and class
    add_table(110, 57, 10, {-1, -1}); add_table(111, 57, 10, {-1, -1})            -- negative material numbers
    add_table(99, 59, 10, STONE, {unrevealed=true}); add_table(100, 59, 10, STONE)
    for x = 105, 108 do add_table(x, 61, 10, STONE); add_table(x, 63, 10, STONE) end
    add_table(110, 49, 10, STONE); add_table(110, 67, 10, STONE)                  -- above and below the view
    I.draw_tables()
    eq('stones of one colour but another kind do not join', row(110, 111, 55), 'SS')
    eq('negative material numbers', row(110, 111, 57), 'LR')
    local r = rgba(pixels(cell(110, 57))[10 * 32 + 16 + 1])
    check('and they keep their colour', r >= 30 + 9 and r <= 30 + 17, r)
    eq('an unrevealed table off the edge does not join', kind(100, 59), 'S')
    -- each tile shows the stretch of the strip for its place on the map
    local function same(a, b) for i = 1, 1024 do if a[i] ~= b[i] then return false end end return true end
    local tint = I.material_tint(0, 0)
    for x = 106, 107 do for y = 61, 63, 2 do
        check('phase of ' .. x .. ',' .. y, same(pixels(cell(x, y)), I.paint_tile(tint, 2, I.phase_at(x, y))))
    end end
    check('neighbours differ', not same(pixels(cell(106, 61)), pixels(cell(107, 61))))
    check('rows differ', not same(pixels(cell(106, 61)), pixels(cell(106, 63))))
    local before = cell(106, 61)
    W.window_x = W.window_x - 1      -- scrolling does not change a tile's picture
    W.gps.main_viewport = viewport(DIM_X, DIM_Y)
    for _, b in ipairs(W.tables) do
        local sx, sy = b.centerx - W.window_x, b.centery - W.window_y
        if b.z == 10 and sx >= 0 and sx < DIM_X and sy >= 0 and sy < DIM_Y then W.gps.main_viewport.screentexpos_building_one[sx * DIM_Y + sy] = 7 end
    end
    I.draw_tables()
    eq('the same tile after scrolling', cell(106, 61), before)
    local n = 0
    for i, v in pairs(W.gps.main_viewport.screentexpos_building_one) do if i < 0 or i >= DIM_X * DIM_Y then n = n + 1 end end
    eq('nothing written outside the layer', n, 0)

    -- a lower layer of another size is left alone
    fresh()
    add_table(110, 55, 9, STONE); add_table(111, 55, 9, STONE)
    W.gps.lower_viewport[0].dim_x = DIM_X + 1
    I.draw_tables()
    eq('a lower layer of another size is not drawn in', row(110, 111, 55, 1), 'SS')

    -- textures that are not ready
    fresh()
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE)
    W.refuse_textures = 'zero'
    I.draw_tables()
    eq('handle 0 is no texture', row(110, 111, 55), 'SS')
    W.refuse_textures = false; W.no_texpos = true
    I.draw_tables()
    eq('texpos 0 is no texture', row(110, 111, 55), 'SS')
    W.no_texpos = false
    I.draw_tables()
    eq('drawn once the texture is there', row(110, 111, 55), 'LR')

    -- the world goes: tiles are painted anew for the next one
    local painted = W.next_handle
    local handlers = 0
    for key, handler in pairs(m.dfhack.onStateChange) do handlers = handlers + 1; handler(m.SC_WORLD_UNLOADED) end
    eq('one state handler', handlers, 1)
    W.descriptors.colors[0].palette.color = palette(70)
    I.draw_tables()
    check('repainted after the world was unloaded', W.next_handle > painted)
    r = rgba(pixels(cell(110, 55))[10 * 32 + 16 + 1])
    check('in the new world\'s colour', r >= 70 + 9, r)
end

do  -- what is remembered between frames, and when it is thrown away
    -- the game fills the layer anew every frame: its picture for every table it shows
    local function game_draws()
        local cells = W.gps.main_viewport.screentexpos_building_one
        for i = 0, DIM_X * DIM_Y - 1 do cells[i] = 0 end
        for _, b in ipairs(W.tables) do
            local sx, sy = b.centerx - W.window_x, b.centery - W.window_y
            if b.z == W.window_z and not b.gone and not b.not_shown and sx >= 0 and sx < DIM_X and sy >= 0 and sy < DIM_Y then
                cells[sx * DIM_Y + sy] = 7
            end
        end
    end
    local function frame() game_draws(); I.draw_tables() end

    fresh()
    local asked = 0
    local function counted(b)
        local stage = b.getBuildStage
        function b:getBuildStage() asked = asked + 1; return stage(self) end
        return b
    end
    for x = 110, 112 do counted(add_table(x, 55, 10, STONE)) end
    frame()
    eq('drawn', row(110, 112, 55), 'LMR')
    local after_first, painted = asked, W.next_handle
    for _ = 1, 20 do frame() end
    eq('drawn again every frame', row(110, 112, 55), 'LMR')
    eq('later frames do not ask the game about finished tables', asked, after_first)
    eq('and paint nothing', W.next_handle, painted)

    -- a table being built joins when it is finished, without any new building
    fresh()
    add_table(110, 55, 10, STONE)
    local late = add_table(111, 55, 10, STONE, {unfinished=true})
    frame(); frame()
    eq('not joined while it is built', row(110, 111, 55), 'SS')
    function late:getBuildStage() return 1 end
    frame()
    eq('joined the frame it is finished', row(110, 111, 55), 'LR')

    -- a table is taken away
    fresh()
    for x = 110, 112 do add_table(x, 55, 10, STONE) end
    frame()
    W.tables[3].gone = true; table.remove(W.tables, 3)
    frame()
    eq('the others close up the frame a table is removed', row(110, 112, 55), 'LR-')

    -- one is removed and another built in the same frame: the count is the same
    fresh()
    for x = 110, 112 do add_table(x, 55, 10, STONE) end
    frame()
    W.tables[3].gone = true; table.remove(W.tables, 3)
    add_table(110, 57, 10, STONE)
    frame()
    eq('a swap of tables is seen', row(110, 112, 55) .. kind(110, 57), 'LR-S')

    -- the game starts and stops showing a table
    fresh()
    add_table(110, 55, 10, STONE); local mid = add_table(111, 55, 10, STONE); add_table(112, 55, 10, STONE)
    mid.not_shown = true
    frame(); frame()
    eq('a table not shown splits the row', row(110, 112, 55), 'S-S')
    mid.not_shown = false
    frame()
    eq('joined the frame it is shown', row(110, 112, 55), 'LMR')
    mid.not_shown = true
    frame()
    eq('split again the frame it is not', row(110, 112, 55), 'S-S')
    eq('and its cell is left empty', cell(111, 55), 0)

    -- a neighbour off the edge is revealed: seen at the next look around
    fresh()
    add_table(99, 55, 10, STONE, {unrevealed=true}); add_table(100, 55, 10, STONE)
    frame()
    eq('unrevealed off the edge: no join', kind(100, 55), 'S')
    W.unrevealed = {}
    for _ = 1, 31 do frame() end
    eq('revealed off the edge: joined within 31 frames', kind(100, 55), 'R')

    -- the camera moves and comes back
    fresh()
    for x = 110, 112 do add_table(x, 55, 10, STONE) end
    frame()
    local was = cell(111, 55)
    W.window_y = W.window_y + 3; frame()
    eq('after a scroll the tiles are at their new cells', row(110, 112, 55), 'LMR')
    eq('with the same picture', cell(111, 55), was)
    eq('and nothing at the old cells', W.gps.main_viewport.screentexpos_building_one[(111 - W.window_x) * DIM_Y + (55 - 50)], 0)
    W.window_z = 11; frame()
    eq('nothing drawn on a level without tables', W.gps.main_viewport.screentexpos_building_one[(111 - W.window_x) * DIM_Y + (55 - W.window_y)], 0)
    W.window_z = 10; frame()
    eq('back on the level', row(110, 112, 55), 'LMR')

    -- the map is given another size on screen
    W.gps.main_viewport = viewport(DIM_X, DIM_Y - 2)
    local cells = W.gps.main_viewport.screentexpos_building_one
    for x = 110, 112 do cells[(x - W.window_x) * (DIM_Y - 2) + (55 - W.window_y)] = 7 end
    I.draw_tables()
    local got = ''
    for x = 110, 112 do got = got .. (cells[(x - W.window_x) * (DIM_Y - 2) + (55 - W.window_y)] ~= 7 and 'x' or '-') end
    eq('a view of another size: cells worked out anew', got, 'xxx')
    local stray = 0
    for i in pairs(cells) do if i < 0 or i >= DIM_X * (DIM_Y - 2) then stray = stray + 1 end end
    eq('and nothing written outside it', stray, 0)

    -- `long-tables reload` (a later run of the script) reaches the copy that draws
    fresh()
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE)
    frame()
    local old = cell(110, 55)
    m.tile_handles = {}; m.GENERATION = m.GENERATION + 1
    frame()
    check('repainted after a reload', cell(110, 55) ~= old and cell(110, 55) ~= 7)

    -- `singles` takes effect at once
    m.draw_singles = 'only'; frame()
    eq('singles only', row(110, 111, 55), 'ss')
    m.draw_singles = false; frame()
    eq('singles off', row(110, 111, 55), 'LR')

    -- a material changed under a table (not something the game does) is seen in the end
    local item = W.tables[2].contained_items[0].item
    function item:getMaterial() return 3 end
    for _ = 1, 601 do frame() end
    eq('a changed material is seen within 601 frames', row(110, 111, 55), 'SS')

    -- no tables at all, then some
    fresh()
    frame()
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE)
    frame()
    eq('the first tables of a fortress', row(110, 111, 55), 'LR')
    W.tables = {}
    frame()
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE)
    frame()
    eq('and after all were removed', row(110, 111, 55), 'LR')
end


do  -- found by review of the remembering: each of these fails if one of its checks is taken out
    local function game_draws()
        for depth = 0, 8 do
            local vp = depth == 0 and W.gps.main_viewport or W.gps.lower_viewport[depth - 1]
            if vp then
                local cells = vp.screentexpos_building_one
                for i = 0, vp.dim_x * vp.dim_y - 1 do cells[i] = 0 end
            end
        end
        for _, b in ipairs(W.tables) do
            local depth = W.window_z - b.z
            local sx, sy = b.centerx - W.window_x, b.centery - W.window_y
            local vp = depth == 0 and W.gps.main_viewport or depth >= 1 and depth <= 8 and W.gps.lower_viewport[depth - 1]
            if vp and not b.not_shown and sx >= 0 and sx < vp.dim_x and sy >= 0 and sy < vp.dim_y then
                vp.screentexpos_building_one[sx * vp.dim_y + sy] = 7
            end
        end
    end
    local function frame() game_draws(); I.draw_tables() end

    fresh()   -- A
    add_table(99, 55, 10, STONE); add_table(100, 55, 10, STONE)
    frame()
    eq('joined to a neighbour off the edge', kind(100, 55), 'R')
    table.remove(W.tables, 1)
    frame()
    eq('the neighbour off the edge is removed: seen that frame', kind(100, 55), 'S')

    fresh()   -- B
    add_table(110, 55, 10, STONE); add_table(111, 57, 10, STONE, {unfinished=true})
    frame()
    table.remove(W.tables, 1)
    check('a removal before an unfinished table: no error', (pcall(frame)))

    fresh()   -- C
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE); add_table(120, 60, 10, STONE)
    frame()
    table.remove(W.tables, 3); add_table(109, 55, 10, STONE)
    frame()
    eq('swap: the new table joins that frame', row(109, 111, 55), 'LMR')

    fresh()   -- D
    for x = 98, 127 do add_table(x, 55, 10, STONE) end
    frame()
    local was = cell(110, 55)
    W.window_x = W.window_x + 1; frame()
    eq('full-width row scrolled sideways: same tile, same picture', cell(110, 55), was)

    fresh()   -- E
    for y = 40, 76 do add_table(110, y, 10, STONE) end
    frame()
    was = cell(110, 58)
    W.window_y = W.window_y + 1; frame()
    eq('full-height column scrolled: same tile, same picture', cell(110, 58), was)

    fresh()   -- F
    add_table(110, 66, 10, STONE); add_table(111, 66, 10, STONE)
    W.gps.main_viewport = viewport(DIM_X, 10)
    I.draw_tables()
    W.gps.main_viewport = viewport(DIM_X, DIM_Y)
    frame()
    eq('a bigger view brings tables in: drawn that frame', row(110, 111, 66), 'LR')

    fresh()   -- G
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE); add_table(110, 55, 7, STONE); add_table(111, 55, 7, STONE)
    frame()
    eq('both levels', row(110, 111, 55) .. row(110, 111, 55, 3), 'LRLR')
    W.gps.lower_viewport[2] = nil
    frame()
    eq('the main level is still drawn the frame a lower layer goes', row(110, 111, 55), 'LR')

    fresh()   -- H
    local a, b = add_table(110, 55, 10, STONE), add_table(111, 55, 10, STONE)
    a.not_shown, b.not_shown = true, true
    frame()
    a.not_shown, b.not_shown = false, false
    frame()
    eq('a level with no table shown: joined the frame they are shown', row(110, 111, 55), 'LR')

    fresh()   -- I
    add_table(99, 55, 9, STONE, {unrevealed=true}); add_table(100, 55, 9, STONE)
    frame()
    eq('an unrevealed table off the edge a level down does not join', kind(100, 55, 1), 'S')

    fresh()   -- J
    add_table(110, 66, 10, GLASS); add_table(110, 67, 10, GLASS)
    frame()
    check('a table below the view joins the last row', cell(110, 66) ~= 7)

    fresh()   -- K
    local WOOD = {420, 7}
    for x = 104, 100, -1 do add_table(x, 64, 10, WOOD) end
    add_table(102, 65, 10, WOOD)
    frame()
    local worst = 0
    for x = 100, 104 do
        local px, col = pixels(cell(x, 64)), I.tint_colours(I.material_tint(420, 7))
        local run = 0
        for i = 0, 31 do
            run = px[16 * 32 + i + 1] == col[7] and run + 1 or 0
            if run > worst then worst = run end
        end
    end
    check('wood T listed east to west: no pale streak along the bar', worst < 12, worst)

    fresh()   -- L
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE)
    m.dfhack.textures.createTile = function() error('boom') end
    local ok, err = pcall(frame)
    check('a texture that raises is reported', not ok and tostring(err):find('boom'), err)

    fresh()   -- M: the reload command itself, with the old copy still drawing
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE)
    frame()
    local old = cell(110, 55)
    m.dfhack_flags = {module=false}
    m.qerror = error
    local out = print
    m.print = function() end
    assert(loadfile(SCRIPT, 't', m))('reload')
    frame()      -- I is still the first copy
    check('repainted after the reload command', cell(110, 55) ~= old and cell(110, 55) ~= 7)

    fresh()   -- a dwarf takes a table apart: its build stage drops before it is gone
    add_table(110, 55, 10, STONE); add_table(111, 55, 10, STONE)
    local going = add_table(112, 55, 10, STONE)
    frame()
    function going:getBuildStage() return 0 end
    going.jobs = vec{{job_type=68}, {job_type=9}}
    for _ = 1, 601 do frame() end
    eq('a table being taken apart stays joined, also after the tables are read again', row(110, 112, 55), 'LMR')
    going.jobs = vec{{job_type=68}}
    frame()
    eq('if the removal is called off half way it is a table being built, at once', row(110, 112, 55), 'LRS')
    going.jobs = vec{{job_type=9}}
    for _ = 1, 601 do frame() end
    eq('taken up again it joins again (when the tables are next read)', row(110, 112, 55), 'LMR')
    function going:getBuildStage() return 1 end
    going.jobs = vec{}
    local before = m.STATS.indexes
    frame()
    eq('called off and whole again: still joined', row(110, 112, 55), 'LMR')
    check('and the tables are read again once, not every frame', (function() frame(); frame(); return m.STATS.indexes == before + 1 end)())
    table.remove(W.tables, 3)
    frame()
    eq('and gone is gone', row(110, 112, 55), 'LR-')

    fresh()   -- every table as a lone one: wood one above the other too
    add_table(110, 55, 10, WOOD); add_table(110, 56, 10, WOOD); add_table(113, 55, 10, WOOD)
    m.draw_singles = 'only'
    frame()
    local function same(a, b) for i = 1, 1024 do if a[i] ~= b[i] then return false end end return true end
    check('singles only: wood above wood is the lone table', same(pixels(cell(110, 55)), pixels(cell(113, 55))))
    m.draw_singles = false

    fresh()   -- a lower layer that is not there when the view is worked out, and then is
    add_table(110, 55, 9, STONE); add_table(111, 55, 9, STONE)
    local kept = W.gps.lower_viewport[0]
    W.gps.lower_viewport[0] = nil
    frame()
    W.gps.lower_viewport[0] = kept
    frame()
    eq('a lower layer that comes back is drawn in that frame', row(110, 111, 55, 1), 'LR')
end

do  -- wood: whether a bar loses its pale streak does not depend on where the camera is
    fresh()
    local WOOD = {420, 7}
    for x = 100, 140 do add_table(x, 60, 10, WOOD) end
    add_table(140, 61, 10, WOOD)        -- the stem, far to the east of the view
    for x = 100, 140 do add_table(x, 64, 10, WOOD) end      -- a plain row
    local function streak(x, y)
        local px, col = pixels(cell(x, y)), I.tint_colours(I.material_tint(420, 7))
        local longest, run = 0, 0
        for i = 0, 31 do
            run = px[16 * 32 + i + 1] == col[7] and run + 1 or 0
            if run > longest then longest = run end
        end
        return longest
    end
    I.draw_tables()
    local worst, best = 0, 0
    for x = 101, 123 do worst = math.max(worst, streak(x, 60)); best = math.max(best, streak(x, 64)) end
    check('wood L, stem far off the view: no pale streak along the bar', worst < 12, worst)
    check('wood row beside it keeps the streak', best >= 12, best)
    eq('the margin is one row', I.MARGIN, 1)
end

print(('%d checks, %d failed'):format(count, failures))
os.exit(failures == 0 and 0 or 1)
