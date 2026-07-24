--[[--
@module koplugin.coverprogress

v1.01

Writes the current book cover, overlaid with reading progress, to a single
fixed path. An external screensaver app points at that path and picks up the
new contents on lock.


Derived from KOReader's built-in coverimage.koplugin.
]]

local Device = require("device")

-- The stock coverimage plugin restricts itself to devices with a known
-- external screensaver. This one runs anywhere, which makes a Kobo or the
-- desktop emulator usable as a stand-in for testing other screen shapes.

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

------------------------------------------------------------------------------
-- Tunables
------------------------------------------------------------------------------

local function defaultPath()
    if Device:isAndroid() then
        return "/storage/emulated/0/cover.jpg"
    end
    -- Kobo: /mnt/onboard/.adds/koreader/cover.jpg
    return DataStorage:getDataDir() .. "/cover.jpg"
end

-- Set both to 0 to use KOReader's screen size. On Android this can be the app
-- window rather than the panel, in which case the screensaver app upscales.
-- Also handy for previewing another device's geometry: a Bigme B7 is
-- 1264 x 1680, a HiBreak Pro BW is 824 x 1648.
local TARGET_W = 0
local TARGET_H = 0

local DEBOUNCE_SECONDS   = 5
local JPEG_QUALITY       = 95
local GRAYSCALE          = true

local DEFAULT_MODE       = "margin"  -- "margin" | "below" | "overlay" | "kobo"
local DEFAULT_BACKGROUND = "auto"    -- "white" | "black" | "auto"

-- below / overlay
local FIT_TO_COVER     = true   -- align the bar/box to the cover, not the screen
local BAND_HEIGHT_PCT  = 8      -- % of output height
local BAND_RULE        = false  -- hairline above the band ("below" mode only)
local BAR_THICKNESS    = 10     -- unscaled px
local PCT_FONT_SIZE    = 20
local PAD              = 16     -- unscaled px

-- overlay: compact block anchored to the cover's bottom-right
local OVERLAY_BAR_W_PCT   = 42   -- % of cover width for bar + percentage
local OVERLAY_INSET       = 14   -- unscaled px in from the cover's edges
local OVERLAY_FIND_QUIET  = true -- search upward for a strip free of lettering
local OVERLAY_SEARCH_PCT  = 22   -- how far up to look, % of cover height
local OVERLAY_CANDIDATES  = 10
local OVERLAY_SAMPLE_STEP = 4
local OVERLAY_LOW_BIAS    = 0.03 -- preference for staying near the bottom

-- Pixels below this 8-bit grey count as dark, for both the overlay
-- polarity check and the auto background decision.
local LUMA_THRESHOLD   = 128

-- Auto background: if more than this fraction of the cover is dark, go
-- black. Counting dark pixels beats averaging them, because covers are
-- often bimodal (pale stock plus heavy black artwork) and the mean lands
-- misleadingly mid-grey.
-- Separate, lower threshold for the auto decision. Measured: the periwinkle
-- on the Karamazov cover is luma 116, so a 128 cut-off counts every purple
-- block as dark and flips a plainly light cover to black. 110 keeps mid
-- colours on the light side. Do not raise this past ~130: pale cover stock
-- often sits around 140 and would suddenly all count as dark.
local AUTO_BG_LUMA       = 110
local AUTO_BG_DARK_RATIO = 50   -- percent dark before going black; menu-adjustable
local AUTO_BG_STEP       = 8

-- kobo
local KOBO_HEADER      = "Sleeping"
local KOBO_BOX_Y_PCT   = 58     -- box top, % of output height
local KOBO_MARGIN      = 10     -- unscaled px from the cover's left edge
local KOBO_FRAME       = 10     -- white card margin outside the ruled border
local KOBO_PAD         = 18     -- unscaled px inside the border
local KOBO_LINE_GAP    = 9
local KOBO_MIN_W       = 150    -- unscaled px, so short text still reads as a card
local KOBO_HEAD_SIZE   = 24
local KOBO_BODY_SIZE   = 17
-- Kobo sets its sleep screen in a serif. Falls back to the default sans if
-- this font is not present in the build.
local KOBO_SERIF       = "./fonts/noto/NotoSerif-Regular.ttf"

------------------------------------------------------------------------------

local CoverProgress = WidgetContainer:extend{
    name = "coverprogress",
    is_doc_only = true,
}

local function getExtension(filename)
    local _dir, name = util.splitFilePathName(filename)
    return util.getFileNameSuffix(name):lower()
end

-- Mean 8-bit grey of a region. Subsampled; returns nil if it can't read.
local function sampleLuma(bb, x, y, w, h, step)
    step = step or 8
    local ok, mean = pcall(function()
        local max_x, max_y = bb:getWidth() - 1, bb:getHeight() - 1
        local sum, n = 0, 0
        for py = math.max(y, 0), math.min(y + h - 1, max_y), step do
            for px = math.max(x, 0), math.min(x + w - 1, max_x), step do
                sum = sum + bb:getPixel(px, py):getColor8().a
                n = n + 1
            end
        end
        if n == 0 then return nil end
        return sum / n
    end)
    if ok then return mean end
    return nil
end

-- A JPEG that lost its end-of-image marker still decodes, but the missing
-- rows come out as a grey band. Cheap to check, so check.
local function fileLooksComplete(path, fmt)
    local f = io.open(path, "rb")
    if not f then return false end
    local size = f:seek("end")
    if size < 1024 then
        f:close()
        return false
    end
    if fmt ~= "jpg" and fmt ~= "jpeg" then
        f:close()
        return true
    end
    f:seek("set", size - 2)
    local tail = f:read(2)
    f:close()
    return tail == string.char(0xFF, 0xD9)
end

-- Mean and standard deviation of a region's luminance. The deviation is the
-- useful part: it distinguishes flat areas (paper, solid ink) from lettering
-- and detail, regardless of how light or dark they are.
local function sampleStats(bb, x, y, w, h, step)
    step = step or 4
    local ok, mean, sd = pcall(function()
        local max_x, max_y = bb:getWidth() - 1, bb:getHeight() - 1
        local sum, sumsq, n = 0, 0, 0
        for py = math.max(y, 0), math.min(y + h - 1, max_y), step do
            for px = math.max(x, 0), math.min(x + w - 1, max_x), step do
                local v = bb:getPixel(px, py):getColor8().a
                sum = sum + v
                sumsq = sumsq + v * v
                n = n + 1
            end
        end
        if n == 0 then return nil end
        local m = sum / n
        return m, math.sqrt(math.max(0, sumsq / n - m * m))
    end)
    if ok and mean then return mean, sd end
    return nil, nil
end

-- Font files vary between builds and platforms, so try the preferred face and
-- quietly fall back to the interface default rather than erroring.
local function pickFace(preferred, size)
    if preferred then
        local ok, face = pcall(Font.getFace, Font, preferred, size)
        if ok and face then return face end
    end
    return Font:getFace("cfont", size)
end

local function paintOutline(bb, x, y, w, h, thickness, color)
    bb:paintRect(x, y, w, thickness, color)
    bb:paintRect(x, y + h - thickness, w, thickness, color)
    bb:paintRect(x, y, thickness, h, color)
    bb:paintRect(x + w - thickness, y, thickness, h, color)
end

function CoverProgress:init()
    self.output_path = G_reader_settings:readSetting("coverprogress_path", defaultPath())
    self.enabled = G_reader_settings:isTrue("coverprogress_enabled")
    self.debounce = G_reader_settings:readSetting("coverprogress_debounce", DEBOUNCE_SECONDS)
    self.background = G_reader_settings:readSetting("coverprogress_background", DEFAULT_BACKGROUND)
    self.mode = G_reader_settings:readSetting("coverprogress_mode", DEFAULT_MODE)
    self.auto_ratio = G_reader_settings:readSetting("coverprogress_auto_ratio", AUTO_BG_DARK_RATIO)

    self.base_bb = nil

    self.render_callback = function()
        self:safeRender()
    end

    self.ui.menu:registerToMainMenu(self)
end

------------------------------------------------------------------------------
-- Geometry and colour
------------------------------------------------------------------------------

-- Resolves "auto" to whatever the last cover analysis decided.
function CoverProgress:resolvedBackground()
    if self.background == "auto" then
        return self.auto_choice or "white"
    end
    return self.background
end

function CoverProgress:getColors()
    if self:resolvedBackground() == "black" then
        return Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    end
    return Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
end

-- Counts dark pixels rather than averaging them: covers are frequently
-- bimodal, and a mean sits mid-grey for artwork that is plainly light or
-- plainly dark to the eye.
function CoverProgress:decideAutoBackground(bb, w, h)
    local ok, ratio = pcall(function()
        local dark, n = 0, 0
        for y = 0, h - 1, AUTO_BG_STEP do
            for x = 0, w - 1, AUTO_BG_STEP do
                if bb:getPixel(x, y):getColor8().a < AUTO_BG_LUMA then
                    dark = dark + 1
                end
                n = n + 1
            end
        end
        if n == 0 then return nil end
        return dark / n
    end)
    if ok and ratio then
        self.last_dark_ratio = ratio
        logger.info("CoverProgress: cover is",
            string.format("%.0f%%", ratio * 100), "dark (threshold",
            tostring(self.auto_ratio) .. "%)")
        return (ratio * 100) > self.auto_ratio and "black" or "white"
    end
    self.last_dark_ratio = nil
    return "white"
end

function CoverProgress:getTargetSize()
    if TARGET_W > 0 and TARGET_H > 0 then
        return TARGET_W, TARGET_H
    end
    return Screen:getWidth(), Screen:getHeight()
end

-- Horizontal extent that overlays should occupy: the cover itself when it is
-- narrower than the screen, otherwise the full width.
function CoverProgress:getContentSpan(t_w)
    local r = self.cover_rect
    if FIT_TO_COVER and r and r.w > 0 and r.w <= t_w then
        return r.x, r.w
    end
    return 0, t_w
end

function CoverProgress:getBandHeight(t_h)
    return math.floor(t_h * BAND_HEIGHT_PCT / 100)
end

------------------------------------------------------------------------------
-- Base image
------------------------------------------------------------------------------

function CoverProgress:buildBase()
    self:freeBase()

    local cover_bb = FileManagerBookInfo:getCoverImage(self.ui.document)
    if not cover_bb then
        logger.dbg("CoverProgress: no cover image for", self.ui.document.file)
        return false
    end

    local t_w, t_h = self:getTargetSize()

    -- "below" reserves the band before scaling, so the cover can never
    -- extend under it regardless of screen aspect ratio.
    -- "below" reserves the band before scaling, which raises the cover so the
    -- band never sits on artwork -- necessary on screens wide enough that the
    -- cover would otherwise reach the bottom edge.
    -- "margin" scales to the full height and leaves the cover centred, letting
    -- the band fall into the letterbox a tall screen already produces.
    local avail_h = t_h
    if self.mode == "below" then
        avail_h = t_h - self:getBandHeight(t_h)
    end

    local i_w, i_h = cover_bb:getWidth(), cover_bb:getHeight()
    local scale = math.min(t_w / i_w, avail_h / i_h)
    local s_w, s_h = math.floor(i_w * scale), math.floor(i_h * scale)

    -- NOTE: scaleBlitBuffer frees the source. Do not free cover_bb after this.
    cover_bb = RenderImage:scaleBlitBuffer(cover_bb, s_w, s_h)

    if self.background == "auto" then
        self.auto_choice = self:decideAutoBackground(cover_bb, s_w, s_h)
    end

    local bg = self:getColors()
    local base = Blitbuffer.new(t_w, t_h, cover_bb:getType())
    base:fill(bg)
    local off_x = math.floor((t_w - s_w) / 2)
    local off_y = math.floor((avail_h - s_h) / 2)
    base:blitFrom(cover_bb, off_x, off_y, 0, 0, s_w, s_h)
    cover_bb:free()

    -- Remember the placed rectangle. On a screen wider than the cover the
    -- artwork is pillarboxed, and a full-width bar would run out over the
    -- empty margins.
    self.cover_rect = { x = off_x, y = off_y, w = s_w, h = s_h }

    self.base_bb = base
    logger.dbg("CoverProgress: base built", t_w .. "x" .. t_h, self.mode)
    return true
end

function CoverProgress:freeBase()
    if self.base_bb then
        self.base_bb:free()
        self.base_bb = nil
    end
    self.cover_rect = nil
    -- The look changed, so the next render must write even at the same percent.
    self.last_sig = nil
end

------------------------------------------------------------------------------
-- Progress and stats
------------------------------------------------------------------------------

-- doc_settings exists but its backing table is nil during teardown and parts
-- of setup, so check before touching it. This is what FlushSettings tripped on.
function CoverProgress:docSettings()
    local ds = self.ui and self.ui.doc_settings
    if ds and ds.data then return ds end
    return nil
end

function CoverProgress:getPercent()
    local ok, pct = pcall(function()
        if self.ui.rolling then
            local pos = self.ui.document:getCurrentPos()
            local full = self.ui.document:getFullHeight()
            if full and full > 0 then
                return pos / full
            end
        elseif self.ui.paging then
            local page = self.ui.view.state.page
            local total = self.ui.document:getPageCount()
            if total and total > 0 then
                return page / total
            end
        end
        return nil
    end)

    if ok and pct then
        return math.min(math.max(pct, 0), 1)
    end

    local ds = self:docSettings()
    if ds then
        local got, stored = pcall(ds.readSetting, ds, "percent_finished")
        if got and type(stored) == "number" then return stored end
    end
    return 0
end

-- "7 hours to go" / "45 minutes to go", or nil if statistics aren't available.
-- "7 hours to go" / "45 minutes to go", or nil if statistics are unavailable.
--
-- The statistics plugin exposes no getAvgTimePerPage() accessor; the value
-- lives on the plain field `avg_time` (seconds per page), maintained live for
-- the open book. Durations are already capped at the plugin's max_sec when
-- recorded, so idle time does not inflate it. Remaining pages are derived the
-- same way SimpleUI does it: total pages scaled by the unread fraction.
function CoverProgress:getTimeToGo(pct)
    local ok, seconds, formatted = pcall(function()
        local stats = self.ui.statistics
        if not stats then return nil end
        if stats.settings and stats.settings.is_enabled == false then return nil end

        local total = self.ui.document:getPageCount()
        if not total or total <= 0 then return nil end
        local remaining = math.floor(total * (1 - pct))
        if remaining <= 0 then return nil end

        local avg = stats.avg_time
        -- `avg ~= avg` is the NaN test the statistics plugin uses on this field.
        if type(avg) == "number" and avg == avg and avg > 0 then
            return remaining * avg, nil
        end

        -- Fall back to the plugin's own formatter, which returns a string.
        if type(stats.getTimeForPages) == "function" then
            local got, str = pcall(stats.getTimeForPages, stats, remaining)
            if got and type(str) == "string" and str ~= "" then
                return nil, str
            end
        end
        return nil
    end)

    if not ok then return nil end
    if formatted then return T(_("%1 to go"), formatted) end
    if not seconds or seconds <= 0 then
        logger.dbg("CoverProgress: no time estimate (statistics enabled? enough pages read?)")
        return nil
    end

    if seconds < 3600 then
        local mins = math.max(1, math.floor(seconds / 60 + 0.5))
        return T(_("%1 minutes to go"), mins)
    end
    local hours = math.floor(seconds / 3600 + 0.5)
    if hours == 1 then
        return _("1 hour to go")
    end
    return T(_("%1 hours to go"), hours)
end

function CoverProgress:drawBand(bb, pct)
    local t_w, t_h = bb:getWidth(), bb:getHeight()
    local bg, fg = self:getColors()

    local band_h = self:getBandHeight(t_h)
    local band_y = t_h - band_h
    local pad = Screen:scaleBySize(PAD)

    -- Band spans the full width; its contents align to the cover.
    bb:paintRect(0, band_y, t_w, band_h, bg)
    if BAND_RULE then
        bb:paintRect(0, band_y, t_w, Screen:scaleBySize(1), fg)
    end

    local span_x, span_w = self:getContentSpan(t_w)

    local label = TextWidget:new{
        text = string.format("%d%%", math.floor(pct * 100 + 0.5)),
        face = Font:getFace("cfont", PCT_FONT_SIZE),
        bold = true,
        fgcolor = fg,
    }
    local label_size = label:getSize()
    local label_x = span_x + span_w - pad - label_size.w
    label:paintTo(bb, label_x, band_y + math.floor((band_h - label_size.h) / 2))
    label:free()

    local bar_h = Screen:scaleBySize(BAR_THICKNESS)
    local bar_x = span_x + pad
    local bar_w = label_x - pad - bar_x
    local bar_y = band_y + math.floor((band_h - bar_h) / 2)
    if bar_w > 0 then
        local t = Screen:scaleBySize(1)
        paintOutline(bb, bar_x, bar_y, bar_w, bar_h, t, fg)
        local fill_w = math.floor((bar_w - 2 * t) * pct)
        if fill_w > 0 then
            bb:paintRect(bar_x + t, bar_y + t, fill_w, bar_h - 2 * t, fg)
        end
    end
end

------------------------------------------------------------------------------
-- Mode: overlay
------------------------------------------------------------------------------

function CoverProgress:drawOverlay(bb, pct)
    local t_w, t_h = bb:getWidth(), bb:getHeight()
    local _bg, theme_fg = self:getColors()

    local span_x, span_w = self:getContentSpan(t_w)
    local inset = Screen:scaleBySize(OVERLAY_INSET)
    local gap = Screen:scaleBySize(8)
    local bar_h = Screen:scaleBySize(BAR_THICKNESS)

    local text = string.format("%d%%", math.floor(pct * 100 + 0.5))
    local face = Font:getFace("cfont", PCT_FONT_SIZE)

    -- Measure first; the colour is chosen once the position is known.
    local probe = TextWidget:new{ text = text, face = face, bold = true }
    local label_w = probe:getSize().w
    local label_h = probe:getSize().h
    probe:free()

    local block_w = math.floor(span_w * OVERLAY_BAR_W_PCT / 100)
    local min_w = label_w + gap + Screen:scaleBySize(40)
    if block_w < min_w then block_w = math.min(min_w, span_w - 2 * inset) end
    local block_h = math.max(bar_h, label_h)
    local block_x = span_x + span_w - inset - block_w

    -- Bottom of the artwork, not of the screen.
    local r = self.cover_rect
    local cover_bottom = (r and math.min(r.y + r.h, t_h)) or t_h
    local cover_top = (r and r.y) or 0

    local y = cover_bottom - inset - block_h
    local mean

    if OVERLAY_FIND_QUIET then
        -- Cover art usually has the title and author set in the lower third,
        -- and a bar laid across them reads as a strikethrough. Walk upward a
        -- little and settle on the flattest strip: low standard deviation
        -- means no lettering or detail, whichever shade it happens to be.
        local limit = math.max(cover_top, y - math.floor((cover_bottom - cover_top) * OVERLAY_SEARCH_PCT / 100))
        local step = math.max(1, math.floor((y - limit) / OVERLAY_CANDIDATES))
        local best_score
        for cy = y, limit, -step do
            local m, sd = sampleStats(bb, block_x, cy, block_w, block_h, OVERLAY_SAMPLE_STEP)
            if m then
                -- Nudge towards the bottom so a marginally flatter strip
                -- higher up does not drag the bar into the middle of the art.
                local score = sd + (y - cy) * OVERLAY_LOW_BIAS
                if not best_score or score < best_score then
                    best_score, y, mean = score, cy, m
                end
            end
        end
    end

    if not mean then
        mean = sampleStats(bb, block_x, y, block_w, block_h, OVERLAY_SAMPLE_STEP)
    end

    -- One colour for the bar and the percentage. Sampling them separately
    -- gives a black number beside a white bar, which just looks broken.
    local fg = theme_fg
    if mean then
        fg = (mean < LUMA_THRESHOLD) and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    end

    local label = TextWidget:new{ text = text, face = face, bold = true, fgcolor = fg }
    label:paintTo(bb, block_x + block_w - label_w, y + math.floor((block_h - label_h) / 2))
    label:free()

    local bar_w = block_w - label_w - gap
    local bar_y = y + math.floor((block_h - bar_h) / 2)
    if bar_w > 0 then
        local t = Screen:scaleBySize(2)
        paintOutline(bb, block_x, bar_y, bar_w, bar_h, t, fg)
        local fill_w = math.floor((bar_w - 2 * t) * pct)
        if fill_w > 0 then
            bb:paintRect(block_x + t, bar_y + t, fill_w, bar_h - 2 * t, fg)
        end
    end
end
------------------------------------------------------------------------------
-- Mode: kobo
------------------------------------------------------------------------------

function CoverProgress:drawKoboBox(bb, pct)
    local t_w, t_h = bb:getWidth(), bb:getHeight()
    local bg, fg = self:getColors()

    local head_face = pickFace(KOBO_SERIF, KOBO_HEAD_SIZE)
    local body_face = pickFace(KOBO_SERIF, KOBO_BODY_SIZE)

    local lines = {}

    if KOBO_HEADER and KOBO_HEADER ~= "" then
        table.insert(lines, { text = KOBO_HEADER, face = head_face, rule_after = true })
    end

    local progress_text = T(_("%1% read"), math.floor(pct * 100 + 0.5))
    local ttg = self:getTimeToGo(pct)
    if ttg then
        -- Raw UTF-8 bytes for the middle dot; \u{} escapes are not portable
        -- across every LuaJIT build.
        progress_text = progress_text .. " \xC2\xB7 " .. ttg
    end
    table.insert(lines, { text = progress_text, face = body_face })

    -- Measure
    local pad = Screen:scaleBySize(KOBO_PAD)
    local frame = Screen:scaleBySize(KOBO_FRAME)
    local gap = Screen:scaleBySize(KOBO_LINE_GAP)
    local rule_h = Screen:scaleBySize(1)
    local content_w, content_h = 0, 0

    for i, line in ipairs(lines) do
        line.widget = TextWidget:new{
            text = line.text,
            face = line.face,
            fgcolor = fg,
        }
        local size = line.widget:getSize()
        line.w, line.h = size.w, size.h
        if size.w > content_w then content_w = size.w end
        content_h = content_h + size.h
        if i < #lines then content_h = content_h + gap end
        if line.rule_after then content_h = content_h + rule_h + gap end
    end

    if content_w < Screen:scaleBySize(KOBO_MIN_W) then
        content_w = Screen:scaleBySize(KOBO_MIN_W)
    end

    -- Kobo's sleep screen sets the ruled panel inside a plain white card, so
    -- the border floats rather than butting up against the artwork.
    local inner_w = content_w + 2 * pad
    local inner_h = content_h + 2 * pad
    local box_w = inner_w + 2 * frame
    local box_h = inner_h + 2 * frame

    local span_x, span_w = self:getContentSpan(t_w)
    local box_x = span_x + Screen:scaleBySize(KOBO_MARGIN)
    local box_y = math.floor(t_h * KOBO_BOX_Y_PCT / 100)

    if box_w > span_w then box_w = span_w end
    if box_x + box_w > t_w then box_x = math.max(0, t_w - box_w) end
    if box_y + box_h > t_h then box_y = math.max(0, t_h - box_h - frame) end

    -- White card, then the ruled panel inset within it.
    bb:paintRect(box_x, box_y, box_w, box_h, bg)
    paintOutline(bb, box_x + frame, box_y + frame, inner_w, inner_h,
        Screen:scaleBySize(1), fg)

    local x = box_x + frame + pad
    local y = box_y + frame + pad
    for i, line in ipairs(lines) do
        line.widget:paintTo(bb, x, y)
        line.widget:free()
        y = y + line.h
        if line.rule_after then
            y = y + gap
            bb:paintRect(x, y, content_w, rule_h, fg)
            y = y + rule_h
        end
        if i < #lines then y = y + gap end
    end
end
------------------------------------------------------------------------------
-- Render + write
------------------------------------------------------------------------------

function CoverProgress:render(force)
    if not self.enabled then return end
    if not self.base_bb then
        if not self:buildBase() then return end
    end
    local ds = self:docSettings()
    if ds then
        local got, excluded = pcall(ds.isTrue, ds, "exclude_cover_image")
        if got and excluded then return end
    end

    local pct = self:getPercent()

    -- Skip the encode when nothing visible has changed since the last write.
    -- On this device roughly 20 page flips make one whole percent, so without
    -- this the same image is re-encoded and rewritten twenty times over.
    -- The signature is the displayed percent plus, in Kobo mode, the time
    -- string (which can tick down while the percent holds). A forced call
    -- (open, suspend, close, background/mode change) always writes.
    local sig = tostring(math.floor(pct * 100 + 0.5))
    if self.mode == "kobo" then
        sig = sig .. "|" .. tostring(self:getTimeToGo(pct) or "")
    end
    if not force and sig == self.last_sig then
        return
    end

    local t_w, t_h = self.base_bb:getWidth(), self.base_bb:getHeight()

    -- Fresh copy each time; drawing onto the base would stack overlays.
    local out = Blitbuffer.new(t_w, t_h, self.base_bb:getType())
    out:blitFrom(self.base_bb, 0, 0, 0, 0, t_w, t_h)

    if self.mode == "overlay" then
        self:drawOverlay(out, pct)
    elseif self.mode == "kobo" then
        self:drawKoboBox(out, pct)
    else
        -- "margin" and "below" share a renderer; they differ only in whether
        -- buildBase reserved room for the band beforehand.
        self:drawBand(out, pct)
    end

    local fmt = getExtension(self.output_path)
    if fmt ~= "jpg" and fmt ~= "jpeg" and fmt ~= "png" and fmt ~= "bmp" then
        fmt = "jpg"
    end

    local tmp = self.output_path .. ".tmp"
    local ok = out:writeToFile(tmp, fmt, JPEG_QUALITY, GRAYSCALE)
    out:free()

    if not ok then
        logger.warn("CoverProgress: write failed", tmp)
        return
    end

    if not fileLooksComplete(tmp, fmt) then
        logger.warn("CoverProgress: incomplete write, discarding", tmp)
        os.remove(tmp)
        return
    end

    local renamed, err = os.rename(tmp, self.output_path)
    if not renamed then
        logger.warn("CoverProgress: rename failed", err)
        os.remove(tmp)
        return
    end

    self.last_sig = sig
    logger.dbg("CoverProgress: wrote", self.output_path, string.format("%.1f%%", pct * 100))
end

function CoverProgress:scheduleRender()
    if not self.enabled then return end
    UIManager:unschedule(self.render_callback)
    UIManager:scheduleIn(self.debounce, self.render_callback)
end

-- A screensaver plugin must never be able to break the reader, so errors are
-- contained here rather than propagating out of an event handler.
function CoverProgress:safeRender(force)
    local ok, err = pcall(self.render, self, force)
    if not ok then
        logger.warn("CoverProgress: render failed:", err)
    end
end

-- force = true bypasses the change guard, for writes that must happen even at
-- an unchanged percentage (book open/close, suspend, background or mode change).
function CoverProgress:renderNow(force)
    UIManager:unschedule(self.render_callback)
    self:safeRender(force)
end

function CoverProgress:rebuild()
    if not self.enabled then return end
    local ok, err = pcall(self.buildBase, self)
    if not ok then
        logger.warn("CoverProgress: buildBase failed:", err)
        return
    end
    self:renderNow()
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

function CoverProgress:onReaderReady()
    self.closing = false
    self:rebuild()
end

function CoverProgress:onPageUpdate()
    self:scheduleRender()
end

function CoverProgress:onPosUpdate()
    self:scheduleRender()
end

function CoverProgress:onFlushSettings()
    -- FlushSettings also fires while the document is being torn down, when
    -- there is nothing meaningful left to read. onCloseDocument covers that
    -- case, so skip rather than racing it.
    if self.closing or not self:docSettings() then return end
    self:renderNow(true)
end

function CoverProgress:onSuspend()
    self:renderNow(true)
end

function CoverProgress:onCloseDocument()
    self:renderNow(true)
    self.closing = true
    UIManager:unschedule(self.render_callback)
    self:freeBase()
end

function CoverProgress:onSetRotationMode()
    self:rebuild()
end

------------------------------------------------------------------------------
-- Menu
------------------------------------------------------------------------------

function CoverProgress:menuEntryMode(mode, label, help, separator)
    return {
        text = label,
        help_text = help,
        separator = separator,
        checked_func = function()
            return self.mode == mode
        end,
        callback = function()
            if self.mode == mode then return end
            self.mode = mode
            G_reader_settings:saveSetting("coverprogress_mode", mode)
            -- "below" changes the cover scale, so a full rebuild is needed.
            self:rebuild()
        end,
    }
end

function CoverProgress:menuEntryBackground(color, label, separator)
    return {
        text_func = function()
            if color == "auto" and self.background == "auto" then
                if self.last_dark_ratio then
                    return T(_("%1 (now: %2, cover %3% dark)"), label,
                        self:resolvedBackground(),
                        string.format("%.0f", self.last_dark_ratio * 100))
                end
                return T(_("%1 (now: %2)"), label, self:resolvedBackground())
            end
            return label
        end,
        separator = separator,
        help_text = color == "auto"
            and _("Picks white or black per book by counting how much of the cover is dark.")
            or nil,
        checked_func = function()
            return self.background == color
        end,
        callback = function()
            if self.background == color then return end
            self.background = color
            G_reader_settings:saveSetting("coverprogress_background", color)
            self:rebuild()
        end,
    }
end

function CoverProgress:addToMainMenu(menu_items)
    menu_items.coverprogress = {
        sorting_hint = "screen",
        text = _("Cover screensaver (with progress)"),
        checked_func = function()
            return self.enabled
        end,
        sub_item_table = {
            {
                text = _("Enabled"),
                checked_func = function()
                    return self.enabled
                end,
                callback = function()
                    self.enabled = not self.enabled
                    G_reader_settings:saveSetting("coverprogress_enabled", self.enabled)
                    if self.enabled then
                        self:rebuild()
                    else
                        UIManager:unschedule(self.render_callback)
                    end
                end,
                separator = true,
            },
            self:menuEntryMode("margin", _("Progess bar in the margin"),
                _("Leaves the cover centred at full size and puts the bar in the empty band below it. Best on tall screens such as phones, where a portrait cover cannot reach the bottom edge.")),
            self:menuEntryMode("below", _("Progress bar below cover"),
                _("Shrinks and raises the cover to make room for the bar underneath. Use on wider screens such as tablets, where the cover would otherwise run to the bottom edge.")),
            self:menuEntryMode("overlay", _("Progress bar overlays cover"),
                _("Full-bleed cover with a compact bar drawn on top, placed to avoid lettering and coloured black or white to suit whatever sits beneath it.")),
            self:menuEntryMode("kobo", _("Kobo style box"),
                _("Full-bleed cover with a small bordered card showing percentage read and time remaining. No progress bar."), true),
            self:menuEntryBackground("white", _("White background, black text")),
            self:menuEntryBackground("black", _("Black background, white text")),
            self:menuEntryBackground("auto", _("Auto background")),
            {
                text_func = function()
                    return T(_("Auto: go black above %1% dark"), self.auto_ratio)
                end,
                enabled_func = function()
                    return self.background == "auto"
                end,
                help_text = _("Raise this to favour white backgrounds, lower it to favour black. The current cover's measurement is shown on the Auto background entry above."),
                keep_menu_open = true,
                separator = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        value = self.auto_ratio,
                        value_min = 10,
                        value_max = 90,
                        value_step = 5,
                        default_value = AUTO_BG_DARK_RATIO,
                        title_text = _("Darkness threshold"),
                        info_text = _("Percentage of the cover that must be dark before a black background is used."),
                        ok_text = _("Set"),
                        callback = function(spin)
                            self.auto_ratio = spin.value
                            G_reader_settings:saveSetting("coverprogress_auto_ratio", spin.value)
                            self:rebuild()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Output: %1"), self.output_path)
                end,
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("Writing to:\n%1\n\nEdit coverprogress_path in settings.reader.lua to change."),
                            self.output_path),
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("Update delay: %1 s"), self.debounce)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        value = self.debounce,
                        value_min = 0,
                        value_max = 60,
                        default_value = DEBOUNCE_SECONDS,
                        title_text = _("Seconds after last page turn"),
                        ok_text = _("Set"),
                        callback = function(spin)
                            self.debounce = spin.value
                            G_reader_settings:saveSetting("coverprogress_debounce", spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
            {
                text = _("Update now"),
                keep_menu_open = true,
                callback = function()
                    self:buildBase()
                    self:renderNow(true)
                    UIManager:show(InfoMessage:new{
                        text = T(_("Wrote %1"), self.output_path),
                        timeout = 2,
                    })
                end,
            },
        },
    }
end

return CoverProgress
