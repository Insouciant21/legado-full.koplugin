local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")

local ShelfRows = InputContainer:extend{}

function ShelfRows:init()
    self.rows = {}
    self.ges_events = {
        TapBook = { GestureRange:new{ ges = "tap", range = self.viewport } },
        HoldBook = { GestureRange:new{ ges = "hold", range = self.viewport } },
    }
end

function ShelfRows:makeRow(item)
    local width = self.dimen.w - 2 * Size.padding.fullscreen
    local progress = TextWidget:new{
        text = item.mandatory,
        face = self.progress_face,
        bold = item.bold,
        max_width = math.floor(width * 0.4),
    }
    local title = TextBoxWidget:new{
        text = item.text:gsub("\n", " · "),
        face = self.title_face,
        bold = item.bold,
        width = math.max(1, width - progress:getSize().w - Size.span.horizontal_default),
        height = self.row_height - 2 * Size.span.vertical_default - Size.line.medium,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = BD.mirroredUILayout() and "right" or "left",
    }
    return { title = title, progress = progress }
end

local function freeRow(row)
    row.title:free(true)
    row.progress:free()
end

function ShelfRows:free()
    for row_index, row in pairs(self.rows) do freeRow(row) end
    self.rows = {}
end

function ShelfRows:paintTo(bb, x, y)
    self.painted_top = y
    local offset = self.viewport.y - y
    local first = math.max(1, math.floor(offset / self.row_height) + 1)
    local last = math.min(#self.items, math.ceil((offset + self.viewport.h) / self.row_height))
    for row_index, row in pairs(self.rows) do
        if row_index < first or row_index > last then
            freeRow(row)
            self.rows[row_index] = nil
        end
    end

    local left = x + Size.padding.fullscreen
    local right = x + self.dimen.w - Size.padding.fullscreen
    local mirrored = BD.mirroredUILayout()
    for row_index = first, last do
        local row = self.rows[row_index] or self:makeRow(self.items[row_index])
        self.rows[row_index] = row
        local top = y + (row_index - 1) * self.row_height
        local title_size = row.title:getSize()
        local progress_size = row.progress:getSize()
        local title_x = mirrored and right - title_size.w or left
        local progress_x = mirrored and left or right - progress_size.w
        row.title:paintTo(bb, title_x, top + math.floor((self.row_height - title_size.h) / 2))
        row.progress:paintTo(bb, progress_x, top + math.floor((self.row_height - progress_size.h) / 2))
        bb:paintRect(left, top + self.row_height - Size.line.medium, right - left,
            Size.line.medium, Blitbuffer.COLOR_GRAY)
    end
end

function ShelfRows:bookAt(position)
    if self.painted_top then
        return self.items[math.floor((position.y - self.painted_top) / self.row_height) + 1]
    end
end

function ShelfRows:onTapBook(args, gesture)
    local item = self:bookAt(gesture.pos)
    if item then self.on_select(item) end
    return item ~= nil
end

function ShelfRows:onHoldBook(args, gesture)
    local item = self:bookAt(gesture.pos)
    if item then self.on_hold(item) end
    return item ~= nil
end

return ShelfRows
