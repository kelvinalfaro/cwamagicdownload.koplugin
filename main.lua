local Dispatcher = require("dispatcher")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local function optionalRequire(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    return nil
end
local CenterContainer = optionalRequire("ui/widget/container/centercontainer")
local FrameContainer = optionalRequire("ui/widget/container/framecontainer")
local VerticalGroup = optionalRequire("ui/widget/verticalgroup")
local VerticalSpan = optionalRequire("ui/widget/verticalspan")
local TextBoxWidget = optionalRequire("ui/widget/textboxwidget")
local ProgressWidget = optionalRequire("ui/widget/progresswidget")
local Blitbuffer = optionalRequire("ffi/blitbuffer")
local Font = optionalRequire("ui/font")
local Size = optionalRequire("ui/size")
local Device = optionalRequire("device")
local logger = require("logger")
local socketutil = require("socketutil")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local CwaMagicDownload = WidgetContainer:extend{
    name = "cwamagicdownload",
    version = "0.9.5",
    settings = nil,
    is_syncing = false,
    progress_widget = nil,
}

local BUILTIN_SHELVES = {
    {
        id = "builtin:/opds/unreadbooks",
        name = "Unread Books",
        path = "/opds/unreadbooks",
        folder = "Unread Books",
        default_filter = "unread",
    },
    {
        id = "builtin:/opds/readbooks",
        name = "Read Books",
        path = "/opds/readbooks",
        folder = "Read Books",
        default_filter = "read",
    },
    {
        id = "builtin:/opds/new",
        name = "OPDS Recently Added",
        path = "/opds/new",
        folder = "OPDS Recently Added",
        default_filter = "all",
    },
}

CwaMagicDownload.default_settings = {
    server = nil,
    username = nil,
    password = nil,
    shelf_id = nil,
    selected_shelves = nil,
    available_shelves = nil,
    available_regular_shelves = nil,
    limit = 25,
    format_order = { "epub", "kepub", "pdf" },
    download_root = nil,
    auto_sync = false,
    read_filter = "unread",
    shelf_filters = nil,
    prune_unmatched = false,
    dedupe_across_shelves = true,
    show_shelf_icons = false,
}

local READ_FILTERS = {
    { id = "unread", name = "Unread only" },
    { id = "read", name = "Read only" },
    { id = "all", name = "All books" },
}

local function shellQuote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function trim(value)
    return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function joinUrl(base, path)
    base = (base or ""):gsub("/+$", "")
    path = path or ""
    if path:match("^https?://") then
        return path
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end
    local origin = base:match("^(https?://[^/]+)")
    local base_path = origin and base:sub(#origin + 1) or ""
    if origin and base_path ~= "" and path:sub(1, #base_path + 1) == base_path .. "/" then
        return origin .. path
    end
    return base .. path
end

local function joinPath(left, right)
    left = (left or ""):gsub("/+$", "")
    right = (right or ""):gsub("^/+", "")
    return left .. "/" .. right
end

local function isSafeChildPath(root, path)
    root = (root or ""):gsub("/+$", "")
    path = (path or ""):gsub("/+$", "")
    return root ~= "" and root ~= "/" and path:sub(1, #root + 1) == root .. "/"
end

local function readFile(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local content = fh:read("*a")
    fh:close()
    return content
end

local function fileExists(path)
    local fh = io.open(path, "rb")
    if fh then
        fh:close()
        return true
    end
    return false
end

local function getCacheDir()
    local data_dir = DataStorage:getDataDir()
    local cache_dir = data_dir and joinPath(data_dir, "cache") or "/tmp"
    os.execute("mkdir -p " .. shellQuote(cache_dir))
    return cache_dir
end

local function cachePath(name)
    return joinPath(getCacheDir(), "cwamagicdownload-" .. name)
end

local function findCurl()
    local data_dir = DataStorage:getDataDir()
    local koreader_root = data_dir and data_dir:gsub("/[^/]+$", "")
    local candidates = {}
    if koreader_root then
        table.insert(candidates, joinPath(koreader_root, "curl"))
    end
    table.insert(candidates, "/system/bin/curl")
    table.insert(candidates, "/usr/bin/curl")
    for _, path in ipairs(candidates) do
        if path and fileExists(path) then
            return path
        end
    end
    return nil
end

local function decodeEntities(text)
    text = text or ""
    local entities = {
        amp = "&",
        lt = "<",
        gt = ">",
        quot = '"',
        apos = "'",
        ["#39"] = "'",
    }
    text = text:gsub("&([#%w]+);", function(entity)
        if entities[entity] then return entities[entity] end
        local decimal = entity:match("^#(%d+)$")
        if decimal then
            local codepoint = tonumber(decimal)
            if codepoint and codepoint < 128 then
                return string.char(codepoint)
            end
        end
        return "&" .. entity .. ";"
    end)
    return trim(text)
end

local function safeFilename(title, ext)
    local name = decodeEntities(title)
    name = name:gsub("[/\\:*?\"<>|%c]", " ")
    name = name:gsub("%s+", " ")
    name = trim(name)
    if name == "" then name = "Untitled" end
    if #name > 120 then name = name:sub(1, 120):gsub("%s+$", "") end
    return name .. "." .. ext
end

local function safeFolderName(title)
    local name = decodeEntities(title or "")
    name = name:gsub("%s*%b()%s*$", "")
    name = name:gsub("[/\\:*?\"<>|%c]", " ")
    name = name:gsub("%s+", " ")
    name = trim(name)
    if name == "" then name = "Shelf" end
    if #name > 80 then name = name:sub(1, 80):gsub("%s+$", "") end
    return name
end

local function getHrefFormat(href)
    return (href or ""):match("/([^/%?]+)/?%??[^/]*$")
end

local function getBookIdFromHref(href)
    return (href or ""):match("/download/(%d+)/")
end

local function sidecarPathForBook(path)
    return (path or ""):gsub("%.[^%.%/]+$", ".sdr")
end

local function localBookIsComplete(path)
    local sidecar_path = sidecarPathForBook(path)
    if sidecar_path == path then return false end
    local ext = (path or ""):match("%.([^%.%/]+)$")
    if not ext then return false end
    local metadata = readFile(joinPath(sidecar_path, "metadata." .. ext .. ".lua")) or ""
    if metadata:match('%["status"%]%s*=%s*"complete"') then return true end
    local percent = tonumber(metadata:match('%["percent_finished"%]%s*=%s*([%d%.]+)'))
    return percent and percent >= 0.999
end

local function opdsTimestampToTouch(timestamp)
    local year, month, day, hour, min, sec = (timestamp or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not year then return nil end
    return ("%s%s%s.%s%s%s"):format(year, month, day, hour, min, sec)
end

local function chooseLink(links, format_order)
    for _, wanted in ipairs(format_order or {}) do
        for _, link in ipairs(links) do
            if link.format == wanted then
                return link
            end
        end
    end
    return links[1]
end

local function parseNextPath(xml)
    return (xml or ""):match('<link%s+rel="next".-href="([^"]+)"')
        or (xml or ""):match('<link.-href="([^"]+)".-rel="next"')
end

local function filterAllowsBook(filter, book_id, read_ids)
    if filter == "all" then return true end
    local is_read = book_id and read_ids and read_ids[book_id] == true
    if filter == "read" then return is_read end
    return not is_read
end

local function parseEntries(xml, format_order)
    local books = {}
    for entry in (xml or ""):gmatch("<entry>(.-)</entry>") do
        local title = decodeEntities(entry:match("<title>(.-)</title>"))
        local updated = entry:match("<updated>(.-)</updated>")
        local links = {}
        for link in entry:gmatch("<link%s.-/>") do
            if link:find("http://opds%-spec%.org/acquisition", 1, false) then
                local href = link:match('href="([^"]+)"')
                if href then
                    local format = getHrefFormat(href) or "bin"
                    table.insert(links, {
                        href = href,
                        format = format,
                        mtime = link:match('mtime="([^"]+)"'),
                    })
                end
            end
        end
        local selected = chooseLink(links, format_order)
        if selected and title and title ~= "" then
            table.insert(books, {
                id = getBookIdFromHref(selected.href),
                title = title,
                href = selected.href,
                format = selected.format,
                timestamp = selected.mtime or updated,
            })
        end
    end
    return books
end

local function parseShelfIndex(xml, kind, route)
    local shelves = {}
    for entry in (xml or ""):gmatch("<entry>(.-)</entry>") do
        local title = decodeEntities(entry:match("<title>(.-)</title>"))
        local href = entry:match('href="([^"]*/opds/' .. route .. '/%d+)"')
            or entry:match("<id>(/[^<]*/opds/" .. route .. "/%d+)</id>")
        if title and title ~= "" and href then
            local path = href:gsub("^/books", "")
            local shelf = {
                id = kind .. ":" .. path,
                name = title,
                path = path,
                folder = safeFolderName(title),
            }
            table.insert(shelves, shelf)
        end
    end
    return shelves
end

local function parseReadIds(xml)
    local ids = {}
    for href in (xml or ""):gmatch('href="([^"]+/opds/download/%d+/[^"]*)"') do
        local id = getBookIdFromHref(href)
        if id then ids[id] = true end
    end
    return ids
end

local function appendShelves(target, shelves, seen)
    for _, shelf in ipairs(shelves or {}) do
        if shelf.id and not seen[shelf.id] then
            table.insert(target, shelf)
            seen[shelf.id] = true
        end
    end
end

local function allShelves(settings)
    local shelves = {}
    local seen = {}
    appendShelves(shelves, settings and settings.available_shelves or nil, seen)
    appendShelves(shelves, settings and settings.available_regular_shelves or nil, seen)
    appendShelves(shelves, BUILTIN_SHELVES, seen)
    return shelves
end

local function getShelfById(settings, id)
    for _, shelf in ipairs(allShelves(settings)) do
        if shelf.id == id then return shelf end
    end
    return allShelves(settings)[1]
end

local function selectedShelfCount(settings)
    local count = 0
    for _, shelf in ipairs(allShelves(settings)) do
        if settings.selected_shelves and settings.selected_shelves[shelf.id] then
            count = count + 1
        end
    end
    return count
end

local function getReadFilterById(id)
    for _, filter in ipairs(READ_FILTERS) do
        if filter.id == id then return filter end
    end
    return READ_FILTERS[1]
end

local function getHomeDir()
    return G_reader_settings:readSetting("home_dir") or "/storage/emulated/0/Books"
end

function CwaMagicDownload:init()
    self.settings = G_reader_settings:readSetting("cwamagicdownload", self.default_settings)
    if not self.settings.password then
        local cwa = G_reader_settings:readSetting("cwasync", {})
        self.settings.password = cwa.password
        self.settings.username = cwa.username or self.settings.username
        self.settings.server = cwa.server or self.settings.server
    end
    self:migrateSelectedShelves()
    self.ui.menu:registerToMainMenu(self)
    if self.settings.auto_sync then
        UIManager:scheduleIn(5, function()
            self:syncSelectedShelf()
        end)
    end
end

function CwaMagicDownload:migrateSelectedShelves()
    if type(self.settings.selected_shelves) ~= "table" then
        self.settings.selected_shelves = {}
    end
    if next(self.settings.selected_shelves) == nil then
        local old_id_map = {
            read_2026 = "magic:/opds/magicshelf/25",
            recently_added = "magic:/opds/magicshelf/1",
            yet_to_read = "magic:/opds/magicshelf/3",
            opds_unread = "builtin:/opds/unreadbooks",
            opds_new = "builtin:/opds/new",
        }
        local selected_id = old_id_map[self.settings.shelf_id or ""] or self.settings.shelf_id
        if not selected_id then
            selected_id = "builtin:/opds/unreadbooks"
        end
        self.settings.selected_shelves[selected_id] = true
    end
    if type(self.settings.shelf_filters) ~= "table" then
        self.settings.shelf_filters = {}
    end
end

local function hasDiscoveredShelves(settings)
    return (settings.available_shelves and #settings.available_shelves > 0)
        or (settings.available_regular_shelves and #settings.available_regular_shelves > 0)
end

local function hasShelfGroup(shelves)
    return shelves and #shelves > 0
end

function CwaMagicDownload:getShelfFilter(shelf)
    return self.settings.shelf_filters
        and shelf
        and self.settings.shelf_filters[shelf.id]
        or shelf and shelf.default_filter
        or self.settings.read_filter
        or "unread"
end

function CwaMagicDownload:setShelfFilter(shelf, filter)
    self.settings.shelf_filters = self.settings.shelf_filters or {}
    if not filter then
        self.settings.shelf_filters[shelf.id] = nil
    else
        self.settings.shelf_filters[shelf.id] = filter
    end
    G_reader_settings:saveSetting("cwamagicdownload", self.settings)
end

function CwaMagicDownload:getShelfFilterLabel(shelf)
    local filter_id = self:getShelfFilter(shelf)
    local filter = getReadFilterById(filter_id)
    if self.settings.shelf_filters and self.settings.shelf_filters[shelf.id] then
        return filter.name
    end
    if shelf and shelf.default_filter then
        return T(_("Feed default: %1"), filter.name)
    end
    return T(_("Global default: %1"), filter.name)
end

function CwaMagicDownload:getShelfFilterShortLabel(shelf)
    if self.settings.shelf_filters and self.settings.shelf_filters[shelf.id] then
        return getReadFilterById(self:getShelfFilter(shelf)).name
    end
    if shelf and shelf.default_filter then
        return _("Feed default")
    end
    return _("Default")
end

function CwaMagicDownload:getShelfDisplayName(shelf)
    local name = shelf.name or ""
    name = name:gsub("%s*%((Magic)%)$", "")
    name = name:gsub("%s*%((Regular)%)$", "")
    if not self.settings.show_shelf_icons then
        name = name:gsub("^[^%w]+%s+", "")
    end
    return name
end

function CwaMagicDownload:groupShelvesForMenu()
    local magic, regular, builtin = {}, {}, {}
    for _, shelf in ipairs(allShelves(self.settings)) do
        if shelf.id:match("^regular:") then
            table.insert(regular, shelf)
        elseif shelf.id:match("^builtin:") then
            table.insert(builtin, shelf)
        else
            table.insert(magic, shelf)
        end
    end
    return magic, regular, builtin
end

function CwaMagicDownload:onDispatcherRegisterActions()
    Dispatcher:registerAction("cwamagicdownload_sync", {
        category = "none",
        event = "CwaMagicDownloadSync",
        title = _("CWA Magic Downloads: sync selected shelf"),
        general = true,
    })
end

function CwaMagicDownload:onCwaMagicDownloadSync()
    self:syncSelectedShelf()
end

function CwaMagicDownload:addToMainMenu(menu_items)
    menu_items.cwamagicdownload = {
        text = _("CWA Magic Downloads"),
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Sync selected shelves (%1)"), selectedShelfCount(self.settings))
                end,
                callback = function()
                    self:syncSelectedShelf()
                end,
            },
            {
                text = _("Shelves to sync"),
                sub_item_table_func = function()
                    return self:getShelfMenuItems()
                end,
            },
            {
                text = _("Per-shelf read filters"),
                sub_item_table_func = function()
                    return self:getShelfFilterMenuItems()
                end,
            },
            {
                text = _("Refresh shelf list from CWA"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:refreshShelfList(true)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
            {
                text_func = function()
                    return T(_("Read status filter: %1"), getReadFilterById(self.settings.read_filter).name)
                end,
                sub_item_table = self:getReadFilterMenuItems(),
            },
            {
                text = _("Remove books that no longer match"),
                checked_func = function()
                    return self.settings.prune_unmatched
                end,
                help_text = _("When enabled, sync deletes files from this plugin's selected shelf folder if they no longer match the current shelf and read-status filter."),
                callback = function()
                    self.settings.prune_unmatched = not self.settings.prune_unmatched
                    G_reader_settings:saveSetting("cwamagicdownload", self.settings)
                end,
            },
            {
                text = _("Skip duplicates across selected shelves"),
                checked_func = function()
                    return self.settings.dedupe_across_shelves
                end,
                help_text = _("When enabled, each book is downloaded into only the first selected shelf that matches it during a sync run."),
                callback = function()
                    self.settings.dedupe_across_shelves = not self.settings.dedupe_across_shelves
                    G_reader_settings:saveSetting("cwamagicdownload", self.settings)
                end,
            },
            {
                text = _("Show shelf icons"),
                checked_func = function()
                    return self.settings.show_shelf_icons
                end,
                help_text = _("When disabled, leading emoji/icons are hidden from shelf names because some devices render them as question marks."),
                callback = function()
                    self.settings.show_shelf_icons = not self.settings.show_shelf_icons
                    G_reader_settings:saveSetting("cwamagicdownload", self.settings)
                end,
            },
            {
                text = _("Sync when KOReader starts"),
                checked_func = function()
                    return self.settings.auto_sync
                end,
                callback = function()
                    self.settings.auto_sync = not self.settings.auto_sync
                    G_reader_settings:saveSetting("cwamagicdownload", self.settings)
                end,
            },
            {
                text_func = function()
                    return T(_("Limit: %1 books"), self.settings.limit or 25)
                end,
                keep_menu_open = true,
                tap_input_func = function()
                    return {
                        title = _("Maximum books to download"),
                        input = tostring(self.settings.limit or 25),
                        callback = function(input)
                            local value = tonumber(input)
                            if value and value > 0 then
                                self.settings.limit = math.floor(value)
                                G_reader_settings:saveSetting("cwamagicdownload", self.settings)
                            end
                        end,
                    }
                end,
            },
            {
                text_func = function()
                    return T(_("Download folder: %1"), self.settings.download_root or getHomeDir())
                end,
                keep_menu_open = true,
                tap_input_func = function()
                    return {
                        title = _("Download root folder"),
                        input = self.settings.download_root or getHomeDir(),
                        callback = function(input)
                            input = trim(input)
                            self.settings.download_root = input ~= "" and input or nil
                            G_reader_settings:saveSetting("cwamagicdownload", self.settings)
                        end,
                    }
                end,
            },
            {
                text = _("Server login"),
                keep_menu_open = true,
                callback = function()
                    self:showLoginDialog()
                end,
            },
            {
                text = T(_("Plugin version: %1"), self.version),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Downloads books from selected Calibre-Web-Automated OPDS Magic Shelves into KOReader folders."),
                    })
                end,
            },
        },
    }
end

function CwaMagicDownload:getShelfFilterChoiceItems(shelf)
    local items = {}
    table.insert(items, {
        text_func = function()
            if shelf and shelf.default_filter then
                return T(_("Use feed default (%1)"), getReadFilterById(shelf.default_filter).name)
            end
            return T(_("Use global default (%1)"), getReadFilterById(self.settings.read_filter).name)
        end,
        checked_func = function()
            return not (self.settings.shelf_filters and self.settings.shelf_filters[shelf.id])
        end,
        callback = function()
            self.settings.shelf_filters = self.settings.shelf_filters or {}
            self.settings.shelf_filters[shelf.id] = nil
            G_reader_settings:saveSetting("cwamagicdownload", self.settings)
        end,
    })
    for _, filter in ipairs(READ_FILTERS) do
        table.insert(items, {
            text = filter.name,
            checked_func = function()
                return self.settings.shelf_filters and self.settings.shelf_filters[shelf.id] == filter.id
            end,
            callback = function()
                self:setShelfFilter(shelf, filter.id)
            end,
        })
    end
    return items
end

function CwaMagicDownload:getShelfFilterMenuItems()
    if not hasDiscoveredShelves(self.settings) then
        self:refreshShelfList(false)
    end

    local function filterItems(shelves)
        local items = {}
        for _, shelf in ipairs(shelves) do
            table.insert(items, {
                text_func = function()
                    return self:getShelfDisplayName(shelf) .. ": " .. self:getShelfFilterShortLabel(shelf)
                end,
                sub_item_table_func = function()
                    return self:getShelfFilterChoiceItems(shelf)
                end,
            })
        end
        if #items == 0 then
            table.insert(items, {
                text = _("No shelves found. Refresh shelf list from CWA."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:refreshShelfList(true)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            })
        end
        return items
    end

    return {
        {
            text = _("Magic shelves"),
            sub_item_table_func = function()
                local current_magic = self:groupShelvesForMenu()
                if not hasShelfGroup(current_magic) then
                    self:refreshShelfList(false)
                    current_magic = self:groupShelvesForMenu()
                end
                return filterItems(current_magic)
            end,
        },
        {
            text = _("Regular shelves"),
            sub_item_table_func = function()
                local _, current_regular = self:groupShelvesForMenu()
                if not hasShelfGroup(current_regular) then
                    self:refreshShelfList(false)
                    _, current_regular = self:groupShelvesForMenu()
                end
                return filterItems(current_regular)
            end,
        },
        {
            text = _("Built-in OPDS feeds"),
            sub_item_table_func = function()
                local _, _, current_builtin = self:groupShelvesForMenu()
                return filterItems(current_builtin)
            end,
        },
    }
end

function CwaMagicDownload:getShelfMenuItems()
    if not hasDiscoveredShelves(self.settings) then
        self:refreshShelfList(false)
    end

    local function shelfItems(shelves)
        local items = {}
        for _, shelf in ipairs(shelves) do
            table.insert(items, {
                text_func = function()
                    local checked = self.settings.selected_shelves and self.settings.selected_shelves[shelf.id] == true
                    local mark = checked and "[x] " or "[ ] "
                    return mark .. self:getShelfDisplayName(shelf)
                end,
                checked_func = function()
                    return self.settings.selected_shelves and self.settings.selected_shelves[shelf.id] == true
                end,
                callback = function()
                    self.settings.selected_shelves = self.settings.selected_shelves or {}
                    self.settings.selected_shelves[shelf.id] = not self.settings.selected_shelves[shelf.id]
                    G_reader_settings:saveSetting("cwamagicdownload", self.settings)
                end,
            })
        end
        if #items == 0 then
            table.insert(items, {
                text = _("No shelves found. Refresh shelf list from CWA."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:refreshShelfList(true)
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            })
        end
        return items
    end

    return {
        {
            text = _("Refresh shelf list from CWA"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:refreshShelfList(true)
                if touchmenu_instance then
                    touchmenu_instance.item_table = self:getShelfMenuItems()
                    touchmenu_instance:updateItems()
                end
            end,
            separator = true,
        },
        {
            text = _("Magic shelves"),
            sub_item_table_func = function()
                local current_magic = self:groupShelvesForMenu()
                if not hasShelfGroup(current_magic) then
                    self:refreshShelfList(false)
                    current_magic = self:groupShelvesForMenu()
                end
                return shelfItems(current_magic)
            end,
        },
        {
            text = _("Regular shelves"),
            sub_item_table_func = function()
                local _, current_regular = self:groupShelvesForMenu()
                if not hasShelfGroup(current_regular) then
                    self:refreshShelfList(false)
                    _, current_regular = self:groupShelvesForMenu()
                end
                return shelfItems(current_regular)
            end,
        },
        {
            text = _("Built-in OPDS feeds"),
            sub_item_table_func = function()
                local _, _, current_builtin = self:groupShelvesForMenu()
                return shelfItems(current_builtin)
            end,
        },
    }
end

function CwaMagicDownload:getFlatShelfMenuItems()
    local items = {}
    for _, shelf in ipairs(allShelves(self.settings)) do
        table.insert(items, {
            text = shelf.name,
            checked_func = function()
                return self.settings.selected_shelves and self.settings.selected_shelves[shelf.id] == true
            end,
            callback = function()
                self.settings.selected_shelves = self.settings.selected_shelves or {}
                self.settings.selected_shelves[shelf.id] = not self.settings.selected_shelves[shelf.id]
                G_reader_settings:saveSetting("cwamagicdownload", self.settings)
            end,
        })
    end
    return items
end

function CwaMagicDownload:getReadFilterMenuItems()
    local items = {}
    for _, filter in ipairs(READ_FILTERS) do
        table.insert(items, {
            text = filter.name,
            checked_func = function()
                return self.settings.read_filter == filter.id
            end,
            callback = function()
                self.settings.read_filter = filter.id
                G_reader_settings:saveSetting("cwamagicdownload", self.settings)
            end,
        })
    end
    return items
end

function CwaMagicDownload:showLoginDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("CWA Magic Downloads"),
        fields = {
            {
                text = self.settings.server or "",
                hint = _("Server URL"),
            },
            {
                text = self.settings.username or "",
                hint = _("Username"),
            },
            {
                text = self.settings.password or "",
                hint = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        self.settings.server = trim(fields[1])
                        self.settings.username = trim(fields[2])
                        self.settings.password = fields[3]
                        G_reader_settings:saveSetting("cwamagicdownload", self.settings)
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function CwaMagicDownload:showMessage(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 5,
    })
end

function CwaMagicDownload:showProgress(text, pct)
    if not (CenterContainer and FrameContainer and VerticalGroup and VerticalSpan
            and TextBoxWidget and ProgressWidget and Blitbuffer and Font and Size
            and Device and Device.screen) then
        self:showMessage(text, 3)
        return
    end

    if self.progress_widget then
        UIManager:close(self.progress_widget)
        self.progress_widget = nil
    end

    local ok, widget = pcall(function()
        local screen = Device.screen
        local dialog_width = math.floor(screen:getWidth() * 0.82)
        local inner_width = dialog_width - 2 * Size.padding.large
        local bar_height = screen:scaleBySize(18)

        local content = VerticalGroup:new{
            align = "left",
            TextBoxWidget:new{
                text = text or "",
                width = inner_width,
                face = Font:getFace("cfont", 22),
            },
            VerticalSpan:new{ height = Size.padding.default },
            ProgressWidget:new{
                width = inner_width,
                height = bar_height,
                percentage = pct or 0,
                bordercolor = Blitbuffer.COLOR_BLACK,
                bgcolor = Blitbuffer.COLOR_WHITE,
                fillcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }

        local frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = Size.radius.window,
            padding = Size.padding.large,
            content,
        }

        return CenterContainer:new{
            dimen = screen:getSize(),
            frame,
        }
    end)

    if not ok then
        logger.warn("CWA Magic Downloads: progress widget failed", widget)
        self:showMessage(text, 3)
        return
    end

    self.progress_widget = widget
    UIManager:show(self.progress_widget)
    UIManager:forceRePaint()
end

function CwaMagicDownload:closeProgress()
    if self.progress_widget then
        UIManager:close(self.progress_widget)
        self.progress_widget = nil
    end
end

function CwaMagicDownload:getAuth()
    return (self.settings.username or "") .. ":" .. (self.settings.password or "")
end

function CwaMagicDownload:fetchUrlToFileWithLua(url, out_file, max_time)
    local ltn12_ok, ltn12 = pcall(require, "ltn12")
    local http_ok, http = pcall(require, "socket.http")
    local https_ok, https = pcall(require, "ssl.https")
    local socket_ok, socket = pcall(require, "socket")
    local client = url:match("^https://") and https or http
    if not ltn12_ok or not socket_ok or (url:match("^https://") and not https_ok) or (url:match("^http://") and not http_ok) then
        logger.warn("CWA Magic Downloads: no curl and Lua HTTP client unavailable", url)
        return false
    end

    local fh = io.open(out_file, "wb")
    if not fh then
        logger.warn("CWA Magic Downloads: could not open output file", out_file)
        return false
    end

    socketutil:set_timeout(max_time or socketutil.LARGE_BLOCK_TIMEOUT, max_time or socketutil.LARGE_TOTAL_TIMEOUT)
    local request_ok, code, headers, status = pcall(function()
        return socket.skip(1, client.request({
        url = url,
        method = "GET",
        headers = {
            ["Accept-Encoding"] = "identity",
        },
        user = self.settings.username,
        password = self.settings.password,
        sink = ltn12.sink.file(fh),
        }))
    end)
    socketutil:reset_timeout()
    if request_ok and tonumber(code) and tonumber(code) >= 200 and tonumber(code) < 300 then
        return true
    end
    os.execute("rm -f " .. shellQuote(out_file))
    logger.warn("CWA Magic Downloads: Lua HTTP fetch failed", url, request_ok and code or status, headers)
    return false
end

function CwaMagicDownload:fetchUrlToFile(url, out_file, max_time)
    if self:fetchUrlToFileWithLua(url, out_file, max_time) then
        return true
    end

    local curl = findCurl()
    if not curl then
        return false
    end

    local cmd = table.concat({
        shellQuote(curl), "-fsSL",
        "--connect-timeout 20",
        "--max-time", tostring(max_time or 120),
        "-u", shellQuote(self:getAuth()),
        "-o", shellQuote(out_file),
        shellQuote(url),
    }, " ")
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end

function CwaMagicDownload:refreshShelfList(show_result)
    if not self.settings.password or not self.settings.username or not self.settings.server then
        if show_result then self:showMessage(_("Set the CWA server login first.")) end
        return false
    end
    if NetworkMgr:willRerunWhenOnline(function() self:refreshShelfList(show_result) end) then
        return true
    end

    local magic_file = cachePath("magic-shelves.xml")
    local regular_file = cachePath("regular-shelves.xml")
    local magic_url = joinUrl(self.settings.server, "/opds/magicshelfindex")
    local regular_url = joinUrl(self.settings.server, "/opds/shelfindex")
    if not self:fetchUrlToFile(magic_url, magic_file, 120) then
        if show_result then self:showMessage(_("Could not fetch the CWA Magic Shelf list.")) end
        return false
    end
    if not self:fetchUrlToFile(regular_url, regular_file, 120) then
        if show_result then self:showMessage(_("Could not fetch the CWA regular shelf list.")) end
        return false
    end

    local magic_shelves = parseShelfIndex(readFile(magic_file) or "", "magic", "magicshelf")
    local regular_shelves = parseShelfIndex(readFile(regular_file) or "", "regular", "shelf")
    if #magic_shelves == 0 and #regular_shelves == 0 then
        if show_result then self:showMessage(_("No CWA shelves were found.")) end
        return false
    end

    self.settings.available_shelves = magic_shelves
    self.settings.available_regular_shelves = regular_shelves
    self:migrateSelectedShelves()
    G_reader_settings:saveSetting("cwamagicdownload", self.settings)
    if show_result then
        self:showMessage(T(_("Found %1 magic and %2 regular CWA shelves. Reopen this menu to see the updated list."),
            #magic_shelves, #regular_shelves), 6)
    end
    return true
end

function CwaMagicDownload:loadReadIds()
    local read_ids = {}
    local next_path = "/opds/readbooks"
    local page = 0
    local feed_file = cachePath("read.xml")

    while next_path and page < 100 do
        page = page + 1
        local url = joinUrl(self.settings.server, next_path)
        if not self:fetchUrlToFile(url, feed_file, 120) then
            logger.warn("CWA Magic Downloads: failed to fetch read status feed", url)
            return nil
        end
        local xml = readFile(feed_file) or ""
        for id, value in pairs(parseReadIds(xml)) do
            read_ids[id] = value
        end
        next_path = parseNextPath(xml)
    end

    return read_ids
end

function CwaMagicDownload:collectShelfBooks(shelf, read_ids, seen_book_ids)
    local selected = {}
    local limit = self.settings.limit or 25
    local next_path = shelf.path
    local page = 0
    local feed_file = cachePath("feed.xml")
    local read_filter = self:getShelfFilter(shelf)
    local duplicate_count = 0

    while next_path and page < 100 and #selected < limit do
        page = page + 1
        local url = joinUrl(self.settings.server, next_path)
        if not self:fetchUrlToFile(url, feed_file, 120) then
            logger.warn("CWA Magic Downloads: failed to fetch shelf feed", url)
            return nil, page == 1 and _("Could not fetch the shelf feed. Check Wi-Fi and login.") or nil
        end

        local xml = readFile(feed_file) or ""
        for _, book in ipairs(parseEntries(xml, self.settings.format_order)) do
            if filterAllowsBook(read_filter, book.id, read_ids) then
                if seen_book_ids and book.id and seen_book_ids[book.id] then
                    duplicate_count = duplicate_count + 1
                else
                    table.insert(selected, book)
                    if #selected >= limit then break end
                end
            end
        end
        next_path = parseNextPath(xml)
    end

    return selected, nil, duplicate_count
end

function CwaMagicDownload:pruneUnmatchedFiles(target_dir, wanted_files)
    local list_file = cachePath("files.txt")
    os.execute("find " .. shellQuote(target_dir) .. " -maxdepth 1 -type f > " .. shellQuote(list_file))
    local files = readFile(list_file) or ""
    local pruned = 0
    for path in files:gmatch("[^\r\n]+") do
        local filename = path:match("([^/]+)$")
        if filename and not filename:match("%.part$") and not wanted_files[filename] then
            os.execute("rm -f " .. shellQuote(path))
            local sidecar_path = sidecarPathForBook(path)
            if sidecar_path ~= path and isSafeChildPath(target_dir, sidecar_path) then
                os.execute("rm -rf " .. shellQuote(sidecar_path))
            end
            pruned = pruned + 1
        end
    end
    return pruned
end

function CwaMagicDownload:pruneDeselectedShelfFolders()
    if not self.settings.prune_unmatched then return 0 end
    local selected = self.settings.selected_shelves or {}
    local root = self.settings.download_root or getHomeDir()
    local removed = 0

    for _, shelf in ipairs(allShelves(self.settings)) do
        if selected[shelf.id] == false then
            local target_dir = joinPath(root, shelf.folder)
            if isSafeChildPath(root, target_dir) then
                os.execute("rm -rf " .. shellQuote(target_dir))
                removed = removed + 1
            else
                logger.warn("CWA Magic Downloads: refused to remove unsafe shelf folder", target_dir)
            end
        end
    end

    return removed
end

function CwaMagicDownload:applyBookTimestamp(book, out_path)
    local touch_time = opdsTimestampToTouch(book.timestamp)
    if touch_time then
        os.execute("touch -t " .. shellQuote(touch_time) .. " " .. shellQuote(out_path))
        return true
    end
    return false
end

function CwaMagicDownload:syncSelectedShelf()
    if self.is_syncing then
        self:showMessage(_("CWA Magic Downloads is already syncing. Please wait."), 4)
        return
    end
    self.is_syncing = true
    local count = selectedShelfCount(self.settings)
    self:showProgress(T(_("Syncing %1 shelves\nPreparing..."), count), 0)
    UIManager:scheduleIn(0.25, function()
        local ok, err = pcall(function()
            self:syncSelectedShelfNow()
        end)
        if not ok then
            self.is_syncing = false
            self:closeProgress()
            logger.warn("CWA Magic Downloads: sync failed unexpectedly", err)
            self:showMessage(_("CWA Magic Downloads failed. Check the KOReader log for details."), 8)
        end
    end)
end

function CwaMagicDownload:syncOneShelf(shelf, read_ids, seen_book_ids, on_progress)
    local root = self.settings.download_root or getHomeDir()
    local target_dir = joinPath(root, shelf.folder)
    os.execute("mkdir -p " .. shellQuote(target_dir))

    local books, err, duplicates = self:collectShelfBooks(shelf, read_ids, seen_book_ids)
    if not books then
        return { failed = 1, message = err or _("Could not fetch the shelf feed. Check Wi-Fi and login.") }
    end
    if #books == 0 then
        return { empty = 1, folder = target_dir }
    end

    local downloaded, skipped, failed, pruned, retimed = 0, 0, 0, 0, 0
    local kept_books = {}
    local wanted_files = {}
    for _, book in ipairs(books) do
        local filename = safeFilename(book.title, book.format)
        local out_path = joinPath(target_dir, filename)
        if self:getShelfFilter(shelf) == "unread" and localBookIsComplete(out_path) then
            logger.dbg("CWA Magic Downloads: pruning locally completed unread-filtered book", out_path)
        else
            table.insert(kept_books, book)
        end
    end

    if #kept_books == 0 then
        if self.settings.prune_unmatched then
            pruned = self:pruneUnmatchedFiles(target_dir, wanted_files)
        end
        return { empty = 1, pruned = pruned, folder = target_dir }
    end

    for i, book in ipairs(kept_books) do
        if seen_book_ids and book.id then
            seen_book_ids[book.id] = true
        end
        local filename = safeFilename(book.title, book.format)
        wanted_files[filename] = true
        local out_path = joinPath(target_dir, filename)
        local already_exists = fileExists(out_path)
        if on_progress then
            on_progress(i, #kept_books, book.title, not already_exists)
        end
        if already_exists then
            if self:applyBookTimestamp(book, out_path) then
                retimed = retimed + 1
            end
            skipped = skipped + 1
        else
            local tmp_path = out_path .. ".part"
            local book_url = joinUrl(self.settings.server, book.href)
            if self:fetchUrlToFile(book_url, tmp_path, 300) then
                os.execute("mv " .. shellQuote(tmp_path) .. " " .. shellQuote(out_path))
                self:applyBookTimestamp(book, out_path)
                downloaded = downloaded + 1
            else
                failed = failed + 1
                os.execute("rm -f " .. shellQuote(tmp_path))
                logger.warn("CWA Magic Downloads: failed to download", book_url, ok)
            end
        end
    end

    if self.settings.prune_unmatched then
        pruned = self:pruneUnmatchedFiles(target_dir, wanted_files)
    end

    return {
        downloaded = downloaded,
        skipped = skipped,
        failed = failed,
        pruned = pruned,
        retimed = retimed,
        duplicates = duplicates or 0,
        folder = target_dir,
    }
end

function CwaMagicDownload:syncSelectedShelfNow()
    if NetworkMgr:willRerunWhenOnline(function() self:syncSelectedShelf() end) then
        self.is_syncing = false
        self:closeProgress()
        return
    end
    if not self.settings.password or not self.settings.username or not self.settings.server then
        self:closeProgress()
        self:showMessage(_("Set the CWA server login first."))
        self.is_syncing = false
        return
    end

    self:showProgress(_("Refreshing shelf list..."), 0)
    self:refreshShelfList(false)
    local selected_shelves = {}
    for _, shelf in ipairs(allShelves(self.settings)) do
        if self.settings.selected_shelves and self.settings.selected_shelves[shelf.id] then
            table.insert(selected_shelves, shelf)
        end
    end
    if #selected_shelves == 0 then
        self:closeProgress()
        self:showMessage(_("Select at least one shelf to sync."))
        self.is_syncing = false
        return
    end

    local read_ids = {}
    local needs_read_ids = false
    for _, shelf in ipairs(selected_shelves) do
        if self:getShelfFilter(shelf) ~= "all" then
            needs_read_ids = true
            break
        end
    end
    if needs_read_ids then
        self:showProgress(_("Fetching read status..."), 0.03)
        read_ids = self:loadReadIds()
        if not read_ids then
            self:closeProgress()
            self:showMessage(_("Could not fetch read status. Check Wi-Fi and login."))
            self.is_syncing = false
            return
        end
    end

    local seen_book_ids = self.settings.dedupe_across_shelves and {} or nil
    local totals = { downloaded = 0, skipped = 0, failed = 0, pruned = 0, removed_folders = 0, retimed = 0, empty = 0, duplicates = 0 }
    local messages = {}
    local total_shelves = #selected_shelves
    for si, shelf in ipairs(selected_shelves) do
        local shelf_base = 0.06 + (si - 1) / total_shelves * 0.94
        local shelf_top = 0.06 + si / total_shelves * 0.94
        local shelf_name = self:getShelfDisplayName(shelf)

        self:showProgress(T(_("Shelf %1 / %2: %3\nFetching book list..."), si, total_shelves, shelf_name), shelf_base)

        local result = self:syncOneShelf(shelf, read_ids, seen_book_ids, function(bi, total_books, title, is_downloading)
            local book_pct = shelf_base + (bi / total_books) * (shelf_top - shelf_base)
            local short_title = #title > 38 and (title:sub(1, 35) .. "...") or title
            local action = is_downloading and _("Downloading") or _("Already present")
            self:showProgress(
                T(_("Shelf %1 / %2: %3\n%4 %5 / %6\n%7"),
                    si, total_shelves, shelf_name, action, bi, total_books, short_title),
                book_pct)
        end)
        for key, value in pairs(totals) do
            totals[key] = value + (result[key] or 0)
        end
        if result.message then
            table.insert(messages, shelf_name .. ": " .. result.message)
        end
    end
    self:showProgress(_("Finishing up..."), 0.99)
    totals.removed_folders = self:pruneDeselectedShelfFolders()

    G_reader_settings:saveSetting("cwamagicdownload", self.settings)
    self.is_syncing = false
    self:closeProgress()
    local message = T(_("%1 shelves complete\nDownloaded: %2\nSkipped: %3\nDuplicates: %4\nRetimed: %5\nRemoved files: %6\nRemoved folders: %7\nEmpty: %8\nFailed: %9"),
        #selected_shelves, totals.downloaded, totals.skipped, totals.duplicates, totals.retimed, totals.pruned, totals.removed_folders, totals.empty, totals.failed)
    if #messages > 0 then
        message = message .. "\n" .. table.concat(messages, "\n")
    end
    self:showMessage(message, 14)
end

return CwaMagicDownload
