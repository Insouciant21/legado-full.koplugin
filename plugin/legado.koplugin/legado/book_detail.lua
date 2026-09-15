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
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
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
    title = nil,
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
    on_delete = nil,
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
    -- Keep a generous safety limit, but let the detail page's scroll area
    -- decide how much is visible. The previous 3200-byte cut made ordinary
    -- book introductions look incomplete before the user could scroll.
    return truncate_utf8(text, 12000)
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
    -- The plugin catalog is loaded by _meta.lua. Resolve the title when the
    -- widget is instantiated, after that catalog is available; resolving it
    -- in the class declaration leaves only this title untranslated.
    self.title = _("Book details")
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
    local intro_height = math.floor(Screen:getHeight() * 0.38)
    -- A vertical scrollbar shrinks ScrollableContainer's crop width by
    -- ScrollableContainer:getScrollbarWidth(). Give the text the same inner
    -- width up front so long introductions never create a useless horizontal
    -- scrollbar beside the vertical one.
    local intro_content_width = math.max(
        Screen:scaleBySize(120),
        intro_width - ScrollableContainer:getScrollbarWidth()
    )
    local intro_body = TextBoxWidget:new{
        text = intro,
        width = intro_content_width,
        height_adjust = true,
        face = Font:getFace("x_smallinfofont"),
        alignment = "left",
    }
    local intro_scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = intro_width, h = intro_height },
        show_parent = self,
        intro_body,
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
            intro_scroll,
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
                text = _("Delete from bookshelf"),
                enabled = self.on_delete ~= nil,
                callback = function() self:dispatch("delete") end,
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

    -- ButtonDialog normally puts the added widgets above the button table and
    -- makes the button table scroll when the whole dialog is too tall. A book
    -- detail page has a different interaction contract: the header and
    -- introduction may scroll, but all six actions must remain fixed at the
    -- bottom so the user can always reach Close/Delete/Change source.
    local button_size = self.buttontable:getSize()
    local edge_padding = Size.padding.buttontable + Size.margin.default
    local content_height = math.max(
        Screen:scaleBySize(160),
        Screen:getHeight() - button_size.h - Size.line.medium - 2 * edge_padding
    )
    -- Leave room for ScrollableContainer's scrollbar gutter. Without this,
    -- a vertical scrollbar also creates a needless horizontal scrollbar.
    local content_width = math.max(
        button_size.w,
        self.title_group:getSize().w
    ) + ScrollableContainer:getScrollbarWidth()
    local content_scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = content_width, h = content_height },
        show_parent = self,
        self.title_group,
    }
    self.cropping_widget = content_scroll
    local separator = LineWidget:new{
        background = Blitbuffer.COLOR_GRAY,
        dimen = Geom:new{ w = content_width, h = Size.line.medium },
    }
    local page = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = edge_padding },
        content_scroll,
        separator,
        self.buttontable,
        VerticalSpan:new{ width = edge_padding },
    }
    local screen_size = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.movable = FrameContainer:new{
        dimen = screen_size,
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = screen_size,
            page,
        },
    }
    self[1] = self.movable
end

-- ButtonDialog normally invalidates only its movable popup rectangle.  The
-- details page deliberately paints a full-screen surface, so leaving the
-- default dirty rectangle in place can expose stale text from the menu below
-- (for example, a bookshelf's "Page 2 of 2" footer).
function BookDetail:onShow()
    UIManager:setDirty(self, function()
        return "full", Screen:getSize()
    end)
end

function BookDetail:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "full", Screen:getSize()
    end)
end

function BookDetail:dispatch(action)
    local callback = self["on_" .. action]
    if self.on_close then self.on_close(self) end
    UIManager:close(self)
    if callback then callback(self) end
end

return BookDetail
