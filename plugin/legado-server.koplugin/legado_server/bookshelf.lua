local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local MenuPage = require("legado_server/menu_page")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local ShelfRows = require("legado_server/shelf_rows")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local T = require("ffi/util").template
local _ = require("gettext")
local C_ = _.pgettext
local Screen = Device.screen

local Tab = Button:extend{ bordersize = 0, radius = 0 }

function Tab:paintTo(bb, x, y)
    Button.paintTo(self, bb, x, y)
    local line = self.tab_active and Size.line.thick or Size.line.thin
    local color = self.tab_active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY
    bb:paintRect(x, y + self.dimen.h - line, self.dimen.w, line, color)
end

local Header = VerticalGroup:extend{}

function Header:getHeight()
    return self:getSize().h
end

function Header:generateVerticalLayout()
    local layout = self[1]:generateVerticalLayout()
    for tab_index, tab in ipairs(self[2]) do
        layout[#layout + 1] = { tab }
    end
    return layout
end

local function makeHeader(shelf, width)
    local groups = {
        { "all", C_("Bookshelf tab", "All") },
        { "read", C_("Bookshelf tab", "Read") },
        { "unread", C_("Bookshelf tab", "Unread") },
        { "reading", C_("Bookshelf tab", "Reading") },
    }
    local row = HorizontalGroup:new{}
    shelf.tab_buttons = {}
    for tab_index, group in ipairs(groups) do
        local name, label = group[1], group[2]
        local tab = Tab:new{
            text = T("%1 (%2)", label, #shelf.items_by_group[name]),
            width = math.floor(width * tab_index / #groups) - math.floor(width * (tab_index - 1) / #groups),
            height = Size.item.height_default,
            tab_active = shelf.selected_group == name,
            show_parent = shelf,
            callback = function() shelf:selectGroup(name) end,
        }
        row[#row + 1] = tab
        shelf.tab_buttons[name] = tab
    end
    return Header:new{
        TitleBar:new{
            width = width,
            title = _("My Books"),
            subtitle = _("Tap to resume · Hold for chapters"),
            align = "center",
            fullscreen = true,
            close_callback = function() shelf:onClose() end,
            show_parent = shelf,
        },
        row,
    }
end

local function selectTab(shelf, name)
    if name == shelf.selected_group then return false end
    shelf.tab_buttons[shelf.selected_group].tab_active = false
    shelf.tab_buttons[name].tab_active = true
    shelf.selected_group = name
    return true
end

if not Device:isTouchDevice() then
    local Bookshelf = MenuPage:extend{
        items_per_page = 12,
        items_max_lines = 3,
        selected_group = "reading",
    }

    function Bookshelf:init()
        if self.custom_title_bar then self.custom_title_bar:free() end
        self.custom_title_bar = makeHeader(self, Screen:getWidth())
        self.item_table = self.items_by_group[self.selected_group]
        MenuPage.init(self)
    end

    function Bookshelf:selectGroup(name)
        if selectTab(self, name) then self:switchItemTable(nil, self.items_by_group[name]) end
    end

    return Bookshelf
end

local Bookshelf = InputContainer:extend{
    covers_fullscreen = true,
    selected_group = "reading",
}

function Bookshelf:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    local header = makeHeader(self, self.dimen.w)
    local size = G_reader_settings:readSetting("items_font_size") or MenuPage.getItemFontSize(12)
    self.title_face = Font:getFace("smallinfofont", size)
    self.progress_face = Font:getFace("infont", math.max(8, size - 4))
    local sample = TextBoxWidget:new{
        text = "A\nA",
        width = Screen:scaleBySize(80),
        face = self.title_face,
    }
    self.row_height = sample:getSize().h + 2 * Size.span.vertical_default + Size.line.medium
    sample:free(true)
    self.content = VerticalGroup:new{ header }
    self.viewport_height = self.dimen.h - header:getSize().h
    self:populateList()
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        margin = 0,
        bordersize = 0,
        self.content,
    }
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
end

function Bookshelf:populateList()
    local previous = self.content[2]
    if self.scroll then self.scroll:onCloseWidget() end
    if previous then previous:free() end
    self.scroll = nil
    local viewport = Geom:new{ w = self.dimen.w, h = self.viewport_height }
    local items = self.items_by_group[self.selected_group]
    if #items == 0 then
        self.content[2] = CenterContainer:new{
            dimen = viewport,
            TextWidget:new{ text = _("No items"), face = self.title_face },
        }
    else
        local height = #items * self.row_height
        local gutter = height > viewport.h and ScrollableContainer:getScrollbarWidth() or 0
        self.scroll = ScrollableContainer:new{
            dimen = viewport,
            swipe_full_view = false,
            show_parent = self,
            ShelfRows:new{
                dimen = Geom:new{ w = viewport.w - gutter, h = height },
                viewport = viewport,
                items = items,
                row_height = self.row_height,
                title_face = self.title_face,
                progress_face = self.progress_face,
                on_select = function(item) self:onMenuSelect(item) end,
                on_hold = function(item) self:onMenuHold(item) end,
            },
        }
        self.content[2] = self.scroll
    end
    self.content:resetLayout()
end

function Bookshelf:selectGroup(name)
    if not selectTab(self, name) then return end
    self:populateList()
    UIManager:setDirty(self, "ui", self.dimen)
end

function Bookshelf:onScreenResize()
    self:onCloseWidget()
    self:init()
    UIManager:setDirty(self, "ui", self.dimen)
end

function Bookshelf:onCloseWidget()
    if self.scroll then self.scroll:onCloseWidget() end
    self:free()
    self.scroll = nil
end

function Bookshelf:onClose()
    UIManager:close(self, "ui", self.dimen)
    return true
end

return Bookshelf
