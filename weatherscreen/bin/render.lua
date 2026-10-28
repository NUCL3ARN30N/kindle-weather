--[[
Weather screensaver renderer.

Turns an Open-Meteo forecast (JSON) into a grayscale PNG sized for the
Kindle screen. Runs on KOReader's LuaJIT and only borrows its FreeType,
PNG and JSON modules, so it must be started from inside the KOReader
directory (setupkoenv.lua resolves its libraries relative to the cwd).

Everything is configured through environment variables:
  WS_JSON   forecast JSON            WS_OUT    output PNG
  WS_W/H    screen size in px        WS_FONTS  KOReader fonts directory
  WS_ROT    quarter turns clockwise from the layout to the screen (0-3);
            the layout is landscape when the turned screen is wider than tall
  WS_LABEL  location title           WS_BATT   battery percent (optional)
  WS_NOW    unix time override       WS_STALE  seconds until data counts as old

E-ink notes: white background, all fills use the 16 native gray levels
(multiples of 0x11), strokes are >= 2px, and the final image is
quantized to those 16 levels so the GC16 waveform shows it without
dithering noise.
--]]

local ffi = require("ffi")
local floor, ceil, max, min, abs, sqrt = math.floor, math.ceil, math.max, math.min, math.abs, math.sqrt

local env = os.getenv
local FONTS = env("WS_FONTS") or "fonts"
local JSON_FILE = env("WS_JSON") or "weather.json"
local OUT_FILE = env("WS_OUT") or "weather.png"
local W = tonumber(env("WS_W")) or 1072
local H = tonumber(env("WS_H")) or 1448
local ROT = (tonumber(env("WS_ROT")) or 0) % 4
local LABEL = env("WS_LABEL") or "WEATHER"
local BATT = tonumber(env("WS_BATT"))
local NOW = tonumber(env("WS_NOW")) or os.time()
local STALE = tonumber(env("WS_STALE")) or 7200

dofile("setupkoenv.lua")
local FT = require("ffi/freetype")
local Png = require("ffi/png")
local json = require("dkjson")

-- Everything is drawn on a logical canvas: the screen as the reader sees it.
-- For odd rotations that's the framebuffer view turned sideways; finish()
-- turns it back into place.
local VW, VH = W, H
if ROT % 2 == 1 then W, H = H, W end
local LANDSCAPE = W > H

-- Layouts are designed on the 1072x1448 Kindle (11th gen) and scaled to fit
-- other screens (e.g. 1236x1648 Paperwhite 5), centered.
local DW, DH = 1072, 1448
if LANDSCAPE then DW, DH = 1448, 1072 end
local K = min(W / DW, H / DH)
local OX, OY = (W - DW * K) / 2, (H - DH * K) / 2
local function X(v) return OX + v * K end
local function Y(v) return OY + v * K end

-- Gray levels (0 = black, 15 = white) mapped to 8-bit.
local function gray(level) return level * 17 end
local BLACK, INK, MID, SOFT, LINE, PALE, WASH, WHITE =
    gray(0), gray(3), gray(6), gray(9), gray(11), gray(13), gray(14), gray(15)

---------------------------------------------------------------------------
-- Canvas
---------------------------------------------------------------------------

local buf = ffi.new("uint8_t[?]", W * H)
ffi.fill(buf, W * H, 255)

local function blend(x, y, c, a)
    if x < 0 or y < 0 or x >= W or y >= H or a <= 0 then return end
    local i = y * W + x
    if a >= 1 then
        buf[i] = c
    else
        local b = buf[i]
        buf[i] = b + (c - b) * a + 0.5
    end
end

-- Anti-aliased fill of a signed distance field over a device-space box.
local function shade(x0, y0, x1, y1, c, sdf)
    x0, y0 = max(0, floor(x0)), max(0, floor(y0))
    x1, y1 = min(W - 1, ceil(x1)), min(H - 1, ceil(y1))
    for y = y0, y1 do
        local py = y + 0.5
        for x = x0, x1 do
            local d = sdf(x + 0.5, py)
            if d < 0.5 then
                blend(x, y, c, d <= -0.5 and 1 or 0.5 - d)
            end
        end
    end
end

-- Coverage mask, so overlapping stroke segments (polylines, dashes) are
-- composited once and joints don't get darker AA seams.
local mask = ffi.new("float[?]", W * H)
local mx0, my0, mx1, my1

local function mask_shade(x0, y0, x1, y1, sdf)
    x0, y0 = max(0, floor(x0)), max(0, floor(y0))
    x1, y1 = min(W - 1, ceil(x1)), min(H - 1, ceil(y1))
    mx0, my0 = min(mx0 or x0, x0), min(my0 or y0, y0)
    mx1, my1 = max(mx1 or x1, x1), max(my1 or y1, y1)
    for y = y0, y1 do
        local py = y + 0.5
        for x = x0, x1 do
            local d = sdf(x + 0.5, py)
            if d < 0.5 then
                local a = d <= -0.5 and 1 or 0.5 - d
                local i = y * W + x
                if a > mask[i] then mask[i] = a end
            end
        end
    end
end

local function mask_flush(c)
    if not mx0 then return end
    for y = my0, my1 do
        for x = mx0, mx1 do
            local i = y * W + x
            local a = mask[i]
            if a > 0 then
                blend(x, y, c, a)
                mask[i] = 0
            end
        end
    end
    mx0, my0, mx1, my1 = nil, nil, nil, nil
end

local function capsule_sdf(ax, ay, bx, by, r)
    local dx, dy = bx - ax, by - ay
    local ll = dx * dx + dy * dy
    return function(px, py)
        local t = ll > 0 and ((px - ax) * dx + (py - ay) * dy) / ll or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local qx, qy = ax + t * dx - px, ay + t * dy - py
        return sqrt(qx * qx + qy * qy) - r
    end
end

-- Strokes a device-space polyline {x1, y1, x2, y2, ...}. With dash = {on, off}
-- only the "on" stretches are drawn, measured along the line.
local function stroke(pts, width, c, dash)
    local r = width / 2
    local walked = 0
    for i = 1, #pts - 3, 2 do
        local ax, ay, bx, by = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
        local len = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
        local pieces = { { 0, 1 } }
        if dash then
            pieces = {}
            local period = dash[1] + dash[2]
            local s = 0
            while s < len do
                local phase = (walked + s) % period
                local e
                if dash[1] - phase > 1e-6 then
                    e = min(len, s + dash[1] - phase)
                    pieces[#pieces + 1] = { s / len, e / len }
                else
                    e = s + period - phase
                end
                s = max(e, s + 1e-3) -- float rounding must not stall the walk
            end
        end
        for _, p in ipairs(pieces) do
            local sx, sy = ax + (bx - ax) * p[1], ay + (by - ay) * p[1]
            local ex, ey = ax + (bx - ax) * p[2], ay + (by - ay) * p[2]
            mask_shade(min(sx, ex) - r - 1, min(sy, ey) - r - 1, max(sx, ex) + r + 1, max(sy, ey) + r + 1,
                capsule_sdf(sx, sy, ex, ey, r))
        end
        walked = walked + len
    end
    mask_flush(c)
end

-- Design-space helpers ------------------------------------------------------

local function line(x0, y0, x1, y1, width, c, dash)
    stroke({ X(x0), Y(y0), X(x1), Y(y1) }, width * K, c, dash and { dash[1] * K, dash[2] * K })
end

local function rect(x, y, w, h, c)
    local x0, y0, x1, y1 = floor(X(x) + 0.5), floor(Y(y) + 0.5), floor(X(x + w) + 0.5), floor(Y(y + h) + 0.5)
    for yy = max(0, y0), min(H, y1) - 1 do
        ffi.fill(buf + yy * W + max(0, x0), max(0, min(W, x1) - max(0, x0)), c)
    end
end

local function rrect_sdf(cx, cy, hw, hh, r)
    return function(px, py)
        local qx, qy = abs(px - cx) - hw + r, abs(py - cy) - hh + r
        local ox, oy = max(qx, 0), max(qy, 0)
        return sqrt(ox * ox + oy * oy) + min(max(qx, qy), 0) - r
    end
end

local function round_rect(x, y, w, h, r, c, border)
    local x0, y0, x1, y1 = X(x), Y(y), X(x + w), Y(y + h)
    local sdf = rrect_sdf((x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2, r * K)
    if border then
        local half = border * K / 2
        shade(x0 - 1, y0 - 1, x1 + 1, y1 + 1, c, function(px, py) return abs(sdf(px, py) + half) - half end)
    else
        shade(x0 - 1, y0 - 1, x1 + 1, y1 + 1, c, sdf)
    end
end

local function circle(cx, cy, r, c, ring)
    local x, y, rr = X(cx), Y(cy), r * K
    if ring then
        local half = ring * K / 2
        shade(x - rr - 1, y - rr - 1, x + rr + 1, y + rr + 1, c, function(px, py)
            return abs(sqrt((px - x) ^ 2 + (py - y) ^ 2) - rr + half) - half
        end)
    else
        shade(x - rr - 1, y - rr - 1, x + rr + 1, y + rr + 1, c, function(px, py)
            return sqrt((px - x) ^ 2 + (py - y) ^ 2) - rr
        end)
    end
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------

local FONT_FILES = {
    regular = FONTS .. "/noto/NotoSans-Regular.ttf",
    bold = FONTS .. "/noto/NotoSans-Bold.ttf",
    icons = FONTS .. "/nerdfonts/symbols.ttf",
}

local faces, glyphs = {}, {}

local function face(name, size)
    local px = max(6, floor(size * K + 0.5))
    local key = name .. px
    if not faces[key] then
        faces[key] = FT.newFaceSize(FONT_FILES[name], px)
    end
    return faces[key], key
end

local function glyph(f, key, cp)
    local gk = key .. ":" .. cp
    local g = glyphs[gk]
    if not g then
        local r = f:renderGlyph(cp, false)
        g = {
            w = r.bb:getWidth(), h = r.bb:getHeight(),
            stride = tonumber(r.bb.stride),
            data = ffi.cast("uint8_t*", r.bb.data),
            bb = r.bb, -- keeps data alive
            l = r.l, t = r.t, ax = r.ax,
        }
        glyphs[gk] = g
    end
    return g
end

local function codepoints(s)
    local cps = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local b, n = ch:byte(1), #ch
        local cp = n == 1 and b or n == 2 and b % 32 or n == 3 and b % 16 or b % 8
        for i = 2, n do cp = cp * 64 + ch:byte(i) % 64 end
        cps[#cps + 1] = cp
    end
    return cps
end

-- Lays out a string; returns device-space width and a draw(x, baseline, color).
local function shape(font, size, s, tracking)
    local f, key = face(font, size)
    local cps = codepoints(s)
    local track = (tracking or 0) * K
    local pen, placed = 0, {}
    for i, cp in ipairs(cps) do
        local g = glyph(f, key, cp)
        placed[i] = { g = g, x = pen }
        pen = pen + g.ax + (i < #cps and track or 0)
        if i < #cps then pen = pen + f:getKerning(cp, cps[i + 1]) end
    end
    return pen, function(dx, dy, c)
        for _, p in ipairs(placed) do
            local g = p.g
            local gx, gy = floor(dx + p.x + 0.5) + g.l, floor(dy + 0.5) - g.t
            for j = 0, g.h - 1 do
                local row = g.data + j * g.stride
                for i = 0, g.w - 1 do
                    local v = row[i]
                    if v > 0 then blend(gx + i, gy + j, c, v / 255) end
                end
            end
        end
    end
end

-- Draws text at design coords (x, baseline y). align: "left" | "center" | "right".
local function text(font, size, s, x, y, c, align, tracking)
    local w, draw = shape(font, size, s, tracking)
    local dx = X(x)
    if align == "center" then dx = dx - w / 2 elseif align == "right" then dx = dx - w end
    draw(dx, Y(y), c)
    return w / K
end

local function text_width(font, size, s, tracking)
    return (shape(font, size, s, tracking)) / K
end

-- Draws an icon glyph centered on its ink box at design coords (cx, cy).
local function icon(cp, size, cx, cy, c)
    local f, key = face("icons", size)
    local g = glyph(f, key, cp)
    local gx = floor(X(cx) - g.w / 2 + 0.5)
    local gy = floor(Y(cy) - g.h / 2 + 0.5)
    for j = 0, g.h - 1 do
        local row = g.data + j * g.stride
        for i = 0, g.w - 1 do
            local v = row[i]
            if v > 0 then blend(gx + i, gy + j, c, v / 255) end
        end
    end
end

---------------------------------------------------------------------------
-- Weather vocabulary
---------------------------------------------------------------------------

-- WMO weather code -> label, day icon, night icon (Nerd Font weather glyphs).
local WMO = {
    [0] = { "Clear", 0xE30D, 0xE32B },
    [1] = { "Mainly clear", 0xE30C, 0xE379 },
    [2] = { "Partly cloudy", 0xE302, 0xE37E },
    [3] = { "Overcast", 0xE312 },
    [45] = { "Fog", 0xE313 },
    [48] = { "Freezing fog", 0xE313 },
    [51] = { "Light drizzle", 0xE31B },
    [53] = { "Drizzle", 0xE31B },
    [55] = { "Heavy drizzle", 0xE31B },
    [56] = { "Freezing drizzle", 0xE3AD },
    [57] = { "Freezing drizzle", 0xE3AD },
    [61] = { "Light rain", 0xE318 },
    [63] = { "Rain", 0xE318 },
    [65] = { "Heavy rain", 0xE318 },
    [66] = { "Freezing rain", 0xE3AD },
    [67] = { "Freezing rain", 0xE3AD },
    [71] = { "Light snow", 0xE31A },
    [73] = { "Snow", 0xE31A },
    [75] = { "Heavy snow", 0xE31A },
    [77] = { "Snow grains", 0xE31A },
    [80] = { "Light showers", 0xE319 },
    [81] = { "Showers", 0xE319 },
    [82] = { "Heavy showers", 0xE319 },
    [85] = { "Snow showers", 0xE31A },
    [86] = { "Snow showers", 0xE31A },
    [95] = { "Thunderstorm", 0xE31D },
    [96] = { "Thunderstorm, hail", 0xE31D },
    [99] = { "Thunderstorm, hail", 0xE31D },
}

local function wmo(code, night)
    local w = WMO[code] or { "—", 0xE374 }
    return w[1], (night and w[3]) or w[2]
end

local function uv_class(uv)
    if uv < 3 then return "low" elseif uv < 6 then return "moderate" elseif uv < 8 then return "high"
    elseif uv < 11 then return "very high" else return "extreme" end
end

local ICON = {
    feels = 0xE350, humidity = 0xE373, wind = 0xE34B,
    sunrise = 0xE34C, sunset = 0xE34D, uv = 0xE30D, drop = 0xE371,
}

local function deg(v) return string.format("%d°", floor(v + 0.5)) end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

local data
do
    local fh = io.open(JSON_FILE, "rb")
    if fh then
        local ok, obj = pcall(json.decode, fh:read("*a"))
        fh:close()
        if ok and type(obj) == "table" and obj.current and obj.hourly and obj.daily then data = obj end
    end
end


local function finish()
    for i = 0, W * H - 1 do
        local v = buf[i]
        buf[i] = floor(v / 17 + 0.5) * 17
    end
    local out = buf
    if ROT ~= 0 then
        out = ffi.new("uint8_t[?]", VW * VH)
        for y = 0, H - 1 do
            local row = y * W
            for x = 0, W - 1 do
                local d
                if ROT == 1 then d = x * VW + (H - 1 - y)
                elseif ROT == 2 then d = (H - 1 - y) * VW + (W - 1 - x)
                else d = (W - 1 - x) * VW + y end
                out[d] = buf[row + x]
            end
        end
    end
    local ok, err = Png.encodeToFile(OUT_FILE, out, VW, VH, 1)
    if not ok then
        io.stderr:write("render: PNG write failed: ", tostring(err), "\n")
        os.exit(1)
    end
end

if not data then
    local cy = DH / 2
    text("bold", 30, LABEL:upper(), DW / 2, cy - 84, BLACK, "center", 5)
    icon(0xE33D, 200, DW / 2, cy + 96, MID)
    text("bold", 46, "No weather data yet", DW / 2, cy + 286, BLACK, "center")
    text("regular", 32, "It will appear after the next update over Wi-Fi.", DW / 2, cy + 346, MID, "center")
    finish()
    return
end

local cur, hourly, daily = data.current, data.hourly, data.daily
local OFF = data.utc_offset_seconds or 0
local function ltime(fmt, t) return os.date("!" .. fmt, t + OFF) end
local is_night = cur.is_day == 0
local stale = NOW - cur.time > STALE

---------------------------------------------------------------------------
-- Sections. Each takes its box in design coordinates so the portrait and
-- landscape layouts at the bottom can arrange them differently.
---------------------------------------------------------------------------

local function header(x0, x1, y)
    text("bold", 28, LABEL:upper(), x0, y, BLACK, "left", 5)
    local datestr = ltime("%a %d %b", NOW):gsub(" 0", " ")
    text("regular", 28, datestr, x1, y, MID, "right")
end

-- Icon + temperature centered on cx with the given baseline, then the
-- condition and high/low lines below.
local function hero(cx, base, temp_size, icon_size, cond_y, cond_size, hl_y, hl_size)
    local cond, cond_icon = wmo(cur.weather_code, is_night)
    local temp_str = deg(cur.temperature_2m)
    local gap = icon_size * 0.19
    local tw = text_width("regular", temp_size, temp_str)
    local gx = cx - (icon_size + gap + tw) / 2
    icon(cond_icon, icon_size, gx + icon_size / 2, base - temp_size * 0.355, BLACK)
    text("regular", temp_size, temp_str, gx + icon_size + gap, base, BLACK, "left")
    text("bold", cond_size, cond, cx, cond_y, BLACK, "center")
    local hl = string.format("H %s     L %s", deg(daily.temperature_2m_max[1]), deg(daily.temperature_2m_min[1]))
    text("regular", hl_size, hl, cx, hl_y, MID, "center")
end

local function tiles(x0, y0, w, cols, th, gap)
    local uv = floor((daily.uv_index_max[1] or 0) + 0.5)
    local list = {
        { ICON.feels, "FEELS LIKE", deg(cur.apparent_temperature), "" },
        { ICON.humidity, "HUMIDITY", tostring(floor(cur.relative_humidity_2m + 0.5)), "%" },
        { ICON.wind, "WIND", tostring(floor(cur.wind_speed_10m + 0.5)), " km/h" },
        { ICON.sunrise, "SUNRISE", ltime("%H:%M", daily.sunrise[1]), "" },
        { ICON.sunset, "SUNSET", ltime("%H:%M", daily.sunset[1]), "" },
        { ICON.uv, "UV INDEX", tostring(uv), " " .. uv_class(uv) },
    }
    local tw = (w - (cols - 1) * gap) / cols
    for i, t in ipairs(list) do
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        local x, y = x0 + col * (tw + gap), y0 + row * (th + gap)
        local mid = y + th / 2
        round_rect(x, y, tw, th, 20, WASH)
        icon(t[1], 46, x + 46, mid, BLACK)
        text("bold", 20, t[2], x + 88, mid - 13, MID, "left", 2)
        local vw = text("bold", 40, t[3], x + 88, mid + 33, BLACK, "left")
        if t[4] ~= "" then
            text("regular", 26, t[4], x + 88 + vw, mid + 33, INK, "left")
        end
    end
end

-- Hourly series for today (00-24h).
local day0 = daily.time[1]
local hrs, temps, feels, precip = {}, {}, {}, {}
for i, t in ipairs(hourly.time) do
    local h = (t - day0) / 3600
    if h >= 0 and h <= 24 then
        hrs[#hrs + 1] = h
        temps[#temps + 1] = hourly.temperature_2m[i]
        feels[#feels + 1] = hourly.apparent_temperature[i]
        precip[#precip + 1] = hourly.precipitation[i] or 0
    end
end

-- Hourly precipitation is the sum over the preceding hour, so the value at
-- index i + 1 belongs to the bar between hours i and i + 1.
local pmax = 0
for i = 2, #precip do pmax = max(pmax, precip[i]) end

-- Monotone cubic (Fritsch-Carlson): smooth, never overshoots the data.
local function monotone(xs, ys)
    local n, d, m = #xs, {}, {}
    for k = 1, n - 1 do d[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k]) end
    m[1], m[n] = d[1], d[n - 1]
    for k = 2, n - 1 do m[k] = (d[k - 1] * d[k] <= 0) and 0 or (d[k - 1] + d[k]) / 2 end
    for k = 1, n - 1 do
        if d[k] == 0 then
            m[k], m[k + 1] = 0, 0
        else
            local a, b = m[k] / d[k], m[k + 1] / d[k]
            local s = a * a + b * b
            if s > 9 then
                local t = 3 / sqrt(s)
                m[k], m[k + 1] = t * a * d[k], t * b * d[k]
            end
        end
    end
    return function(x)
        local k = 1
        while k < n - 1 and x > xs[k + 1] do k = k + 1 end
        local h = xs[k + 1] - xs[k]
        local t = max(0, min(1, (x - xs[k]) / h))
        local t2, t3 = t * t, t * t * t
        return (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * m[k + 1]
    end
end

-- Today chart: temperature, feels-like, precipitation, now marker.
-- title_y is the title baseline; ctop..cbot is the plot area.
local function chart(x0, x1, title_y, ctop, cbot)
    local cx0, cx1 = x0 + 64, x1

    text("bold", 22, "TODAY", x0, title_y, BLACK, "left", 4)
    do -- legend, right-aligned
        local x, ly = x1, title_y - 8
        local rain = pmax > 0 and string.format("Rain  %.1f mm max", pmax) or "No rain"
        x = x - text("regular", 22, rain, x, title_y, MID, "right") - 12
        rect(x - 22, title_y - 18, 22, 20, SOFT)
        x = x - 22 - 34
        x = x - text("regular", 22, "Feels like", x, title_y, MID, "right") - 12
        line(x - 44, ly, x, ly, 4, MID, { 10, 7 })
        x = x - 44 - 34
        x = x - text("regular", 22, "Temp", x, title_y, MID, "right") - 12
        line(x - 44, ly, x, ly, 6, BLACK)
    end

    if #hrs < 2 then return end
    local lo, hi = math.huge, -math.huge
    for i = 1, #temps do
        lo, hi = min(lo, temps[i], feels[i]), max(hi, temps[i], feels[i])
    end
    local step = 1
    for _, s in ipairs({ 1, 2, 5, 10, 20 }) do
        step = s
        if (ceil(hi / s) - floor(lo / s)) <= 4 then break end
    end
    local vlo, vhi = floor(lo / step) * step, ceil(hi / step) * step
    if vhi == vlo then vhi = vlo + step end

    local data_top = ctop + 60 -- room for the "now" bubble
    local function hx(h) return cx0 + (cx1 - cx0) * h / 24 end
    local function ty(v) return cbot - 12 - (cbot - 12 - data_top) * (v - vlo) / (vhi - vlo) end

    local temp_at = monotone(hrs, temps)
    local feels_at = monotone(hrs, feels)

    -- Area under the temperature curve, one device column at a time.
    local dx0, dx1 = floor(X(cx0)), floor(X(hx(hrs[#hrs])))
    local dbot = floor(Y(cbot))
    for x = dx0, dx1 - 1 do
        local h = ((x + 0.5 - OX) / K - cx0) / (cx1 - cx0) * 24
        local yv = Y(ty(temp_at(h)))
        local yi = floor(yv)
        blend(x, yi, WASH, 1 - (yv - yi))
        for y = yi + 1, dbot - 1 do blend(x, y, WASH, 1) end
    end

    -- Horizontal grid + temperature labels.
    for v = vlo, vhi, step do
        local y = ty(v)
        line(cx0, y, cx1, y, 2, LINE, { 4, 8 })
        text("regular", 22, deg(v), cx0 - 14, y + 8, MID, "right")
    end

    -- Precipitation bars (scaled to at least 2 mm so drizzle stays small).
    if pmax > 0 then
        local scale = (cbot - ctop) * 0.38 / max(pmax, 2)
        local bw = (cx1 - cx0) / 24 * 0.62
        for i = 1, #hrs - 1 do
            local p = precip[i + 1]
            if p > 0 then
                local bh = max(3, p * scale)
                rect(hx(hrs[i] + 0.5) - bw / 2, cbot - bh, bw, bh, SOFT)
            end
        end
    end

    -- Axis + hour labels.
    line(cx0, cbot, cx1, cbot, 2, SOFT)
    for h = 0, 24, 3 do
        line(hx(h), cbot, hx(h), cbot + 10, 2, SOFT)
        text("regular", 22, string.format("%02d", h), hx(h), cbot + 40, MID, "center")
    end

    -- Curves: sample every ~3 device px.
    local function curve(fn)
        local pts = {}
        local n = max(48, floor((X(cx1) - X(cx0)) / 3))
        local hend = hrs[#hrs]
        for i = 0, n do
            local h = hend * i / n
            pts[#pts + 1] = X(hx(h))
            pts[#pts + 1] = Y(ty(fn(h)))
        end
        return pts
    end
    stroke(curve(feels_at), 4 * K, MID, { 12 * K, 9 * K })
    stroke(curve(temp_at), 6 * K, BLACK)

    -- Now marker.
    local hnow = (NOW - day0) / 3600
    if hnow >= 0 and hnow <= hrs[#hrs] then
        local nx = hx(hnow)
        local ny = ty(temp_at(hnow))
        for y = ny + 22, cbot - 4, 12 do circle(nx, y, 2.4, INK) end
        circle(nx, ny, 12, WHITE)
        circle(nx, ny, 12, BLACK, 5)
        local label = deg(cur.temperature_2m) .. "  " .. ltime("%H:%M", NOW)
        local lw = text_width("bold", 24, label) + 28
        local bx = max(cx0 - 40, min(cx1 + 20 - lw, nx - lw / 2))
        round_rect(bx, ny - 64, lw, 40, 20, BLACK)
        text("bold", 24, label, bx + lw / 2, ny - 35, WHITE, "center")
    end
end

-- 7-day strip. sz holds font/icon sizes and their offsets from wtop.
local function week(x0, x1, wtop, wbot, sz)
    line(x0, wtop, x1, wtop, 2, LINE)
    local ndays = min(7, #daily.time)
    local colw = (x1 - x0) / ndays
    for i = 1, ndays do
        local x = x0 + (i - 1) * colw
        local cxm = x + colw / 2
        if i == 1 then
            round_rect(x + 4, wtop + 14, colw - 8, wbot - wtop - 14, 20, WASH)
        end
        local name = i == 1 and "Today" or ltime("%a", daily.time[i])
        text("bold", sz.day, name, cxm, wtop + sz.day_y, BLACK, "center")
        local _, dicon = wmo(daily.weather_code[i], false)
        icon(dicon, sz.icon, cxm, wtop + sz.icon_y, BLACK)
        text("bold", sz.max, deg(daily.temperature_2m_max[i]), cxm, wtop + sz.max_y, BLACK, "center")
        text("regular", sz.min, deg(daily.temperature_2m_min[i]), cxm, wtop + sz.min_y, MID, "center")
        local pp = daily.precipitation_probability_max and daily.precipitation_probability_max[i]
        if type(pp) == "number" and pp > 0 then
            local s = string.format("%d%%", pp)
            local sw = text_width("regular", sz.pp, s)
            icon(ICON.drop, sz.pp * 0.8, cxm - sw / 2 - 6, wtop + sz.pp_y - sz.pp * 0.36, MID)
            text("regular", sz.pp, s, cxm + 8, wtop + sz.pp_y, MID, "center")
        end
    end
end

local function footer(cx, y)
    local foot = { "Updated " .. ltime("%H:%M", cur.time) }
    if BATT then foot[#foot + 1] = string.format("Battery %d%%", BATT) end
    foot[#foot + 1] = "Open-Meteo"
    if stale then
        text("bold", 24, "OFFLINE  ·  last update " .. ltime("%a %H:%M", cur.time), cx, y, BLACK, "center", 2)
    else
        text("regular", 24, table.concat(foot, "   ·   "), cx, y, MID, "center", 1)
    end
end

---------------------------------------------------------------------------
-- Layouts
---------------------------------------------------------------------------

local M = 60 -- page margin

if LANDSCAPE then
    -- Two columns like a dashboard: now on the left, today + week on the right.
    local split = 648
    local lx0, lx1, rx0, rx1 = M, split - 32, split + 32, DW - M
    header(M, DW - M, 76)
    line(split, 116, split, 1000, 2, LINE)
    hero((lx0 + lx1) / 2, 322, 210, 160, 404, 46, 456, 34)
    tiles(lx0, 506, lx1 - lx0, 2, 128, 20)
    chart(rx0, rx1, 150, 172, 512)
    week(rx0, rx1, 600, 924, {
        day = 26, day_y = 54, icon = 58, icon_y = 116, max = 34, max_y = 200,
        min = 28, min_y = 242, pp = 20, pp_y = 286,
    })
    footer(DW / 2, 1044)
else
    header(M, DW - M, 84)
    hero(DW / 2, 345, 250, 190, 428, 52, 484, 38)
    tiles(M, 528, DW - 2 * M, 3, 106, 20)
    chart(M, DW - M, 818, 850, 1060)
    week(M, DW - M, 1112, 1376, {
        day = 28, day_y = 58, icon = 64, icon_y = 112, max = 36, max_y = 190,
        min = 30, min_y = 230, pp = 22, pp_y = 263,
    })
    footer(DW / 2, 1420)
end

finish()
