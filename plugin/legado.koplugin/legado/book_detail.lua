-- Book detail page for bookshelf entries.
--
-- This is deliberately a KOReader widget instead of a WebView.  The Android
-- detail page is a scrollable cover/header/summary page with actions; the
-- Kindle equivalent keeps that information architecture while delegating all
-- typography and reader presentation to KOReader.

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Content = require("legado/content")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen
local unpack_values = table.unpack or unpack

local BookDetail = ButtonDialog:extend{
    title = _("Book details"),
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    book = nil,
    source = nil,
    cover_path = nil,
    progress_text = nil,
    on_read = nil,
    on_chapters = nil,
    on_change_source = nil,
    on_refresh = nil,
    on_close = nil,
    width_factor = 0.98,
    dismissable = true,
}

local function value_text(value)
    local value_type = type(value)
    if value == nil or value_type == "string" then return value or "" end
    return tostring(value)
end

local function trim(value)
    return (value_text(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function truncate_utf8(value, max_bytes)
    value = value_text(value)
    if #value <= max_bytes then return value end
    local result = value:sub(1, max_bytes)
    while #result > 0 do
        local byte = result:byte(#result)
        if not byte or byte < 128 or byte >= 192 then break end
        result = result:sub(1, -2)
    end
    return result .. "…"
end

local function clean_intro(value)
    local text = Content.process(value, { remove_same_title = false })
    return truncate_utf8(text, 3200)
end

local function line(label, value, width)
    value = trim(value)
    if value == "" then return nil end
    return TextBoxWidget:new{
        text = T(_("%1: %2"), label, value),
        width = width,
        face = Font:getFace("x_smallinfofont"),
        height_adjust = true,
        alignment = "left",
    }
end

local function placeholder_cover(book, width, height)
    local text = truncate_utf8(book and book.name or _("No cover"), 48)
    local label = TextBoxWidget:new{
        text = text,
        width = width - 2 * Size.padding.default,
        height = height - 2 * Size.padding.default,
        height_adjust = true,
        alignment = "center",
        face = Font:getFace("x_smallinfofont"),
    }
    local centered = CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        label,
    }
    return FrameContainer:new{
        padding = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        centered,
    }
end

function BookDetail:init()
    self.book = type(self.book) == "table" and self.book or {}
    local screen_width = Screen:getWidth()
    self.width = self.width or math.floor(
        math.min(screen_width, Screen:getHeight()) * self.width_factor
    )

    local title_width = self.width - 2 * Size.border.window
        - 2 * Size.padding.button - 2 * (Size.padding.default + Size.margin.default)
    title_width = math.max(Screen:scaleBySize(240), title_width)
    local cover_width = math.min(
        Screen:scaleBySize(150),
        math.floor(title_width * 0.27)
    )
    local cover_height = math.floor(cover_width * 1.40)
    local text_width = math.max(
        Screen:scaleBySize(180),
        title_width - cover_width - Size.span.horizontal_default
    )

    local cover
    if type(self.cover_path) == "string" and self.cover_path ~= "" then
        cover = FrameContainer:new{
            padding = 0,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            ImageWidget:new{
                file = self.cover_path,
                file_do_cache = false,
                width = cover_width - 2 * Size.border.thin,
                height = cover_height - 2 * Size.border.thin,
                scale_factor = 0,
            },
        }
    else
        cover = placeholder_cover(self.book, cover_width, cover_height)
    end

    local name = trim(self.book.name)
    local author = trim(self.book.author)
    local source_name = trim(
        self.source and self.source.bookSourceName
            or self.book.originName or self.book.sourceName
    )
    local details = {
        TextBoxWidget:new{
            text = name ~= "" and name or _("Unnamed book"),
            width = text_width,
            face = Font:getFace("tfont"),
            bold = true,
            height_adjust = true,
            alignment = "left",
        },
        VerticalSpan:new{ width = Size.span.vertical_small },
        TextBoxWidget:new{
            text = author ~= "" and author or _("Unknown author"),
            width = text_width,
            face = Font:getFace("x_smallinfofont"),
            height_adjust = true,
            alignment = "left",
        },
    }
    for _, item in ipairs({
        line(_("Source"), source_name, text_width),
        line(_("Kind"), self.book.kind, text_width),
        line(_("Last chapter"), self.book.lastChapter, text_width),
        line(_("Updated"), self.book.updateTime, text_width),
        line(_("Word count"), self.book.wordCount, text_width),
        line(_("Progress"), self.progress_text, text_width),
    }) do
        if item then
            details[#details + 1] = VerticalSpan:new{ width = Size.span.vertical_small }
            details[#details + 1] = item
        end
    end

    local header = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = 0,
        HorizontalGroup:new{
            align = "top",
            cover,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            VerticalGroup:new{
                align = "left",
                unpack_values(details),
            },
        },
    }
    header.not_focusable = true

    local intro = clean_intro(self.book.intro)
    if intro == "" then intro = _("No introduction available.") end
    local intro_width = title_width - 2 * Size.padding.default
    local intro_body = TextBoxWidget:new{
        text = intro,
        width = intro_width,
        height = math.floor(Screen:getHeight() * 0.20),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        face = Font:getFace("x_smallinfofont"),
        alignment = "left",
    }
    local intro_panel = FrameContainer:new{
        padding = Size.padding.default,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            TextWidget:new{
                text = _("Introduction"),
                face = Font:getFace("smallinfofontbold"),
                padding = 0,
            },
            VerticalSpan:new{ width = Size.span.vertical_small },
            intro_body,
        },
    }
    intro_panel.not_focusable = true
    intro_panel.separator = true

    self.buttons = {
        {
            {
                text = _("Continue reading"),
                enabled = self.on_read ~= nil,
                callback = function() self:dispatch("read") end,
            },
            {
                text = _("Chapter list"),
                enabled = self.on_chapters ~= nil,
                callback = function() self:dispatch("chapters") end,
            },
        },
        {
            {
                text = _("Change source"),
                enabled = self.on_change_source ~= nil,
                callback = function() self:dispatch("change_source") end,
            },
            {
                text = _("Refresh book information"),
                enabled = self.on_refresh ~= nil,
                callback = function() self:dispatch("refresh") end,
            },
        },
        {
            {
                text = _("Close"),
                callback = function() self:onClose() end,
            },
        },
    }
    self._added_widgets = { header, intro_panel }
    self.tap_close_callback = function()
        if self.on_close then self.on_close(self) end
    end
    ButtonDialog.init(self)

    -- ButtonDialog normally centers a small rounded popup. Details are a
    -- complete page, so give it a square full-screen white surface and keep
    -- the existing button dialog centered horizontally but aligned to the
    -- top. This also prevents the previous KOReader page from showing below
    -- the dialog on devices with a tall screen.
    if self.movable and self.movable[1] then
        self.movable[1].radius = 0
        self.movable[1].bordersize = 0
    end
    local dialog_center = self[1]
    dialog_center.ignore = "height"
    self[1] = FrameContainer:new{
        dimen = Screen:getSize(),
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        dialog_center,
    }
end

function BookDetail:dispatch(action)
    local callback = self["on_" .. action]
    if self.on_close then self.on_close(self) end
    UIManager:close(self)
    if callback then callback(self) end
end

return BookDetail
