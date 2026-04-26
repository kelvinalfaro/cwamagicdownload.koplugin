local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local CwaMagicDownload = WidgetContainer:extend{
    name = "cwamagicdownload",
    version = "0.7.0",
    settings = nil,
    is_syncing = false,
}

local BUILTIN_SHELVES = {
    {
        id = "builtin:/opds/unreadbooks",
        name = "Unread Books",
        path = "/opds/unreadbooks",
        folder = "Unread Books",
    },
    {
        id = "builtin:/opds/new",
        name = "OPDS Recently Added",
        path = "/opds/new",
        folder = "OPDS Recently Added",
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
    prune_unmatched = false,
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

local function opdsTimestampToTouch(timestamp)
    local year, month, day, hour, min, sec = (timestamp or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not year then return nil end
    return ("%s%s%s%s%s.%s"):format(year, month, day, hour, min, sec)
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
                sub_item_table = self:getShelfMenuItems(),
            },
            {
                text = _("Refresh shelf list from CWA"),
                keep_menu_open = true,
                callback = function()
                    self:refreshShelfList(true)
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

function CwaMagicDownload:getShelfMenuItems()
    local function shelfItems(shelves)
        local items = {}
        for _, shelf in ipairs(shelves) do
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

    local magic, regular, builtin = self:groupShelvesForMenu()
    return {
        {
            text = _("Refresh shelf list from CWA"),
            keep_menu_open = true,
            callback = function()
                self:refreshShelfList(true)
            end,
            separator = true,
        },
        {
            text = _("Magic shelves"),
            sub_item_table = shelfItems(magic),
        },
        {
            text = _("Regular shelves"),
            sub_item_table = shelfItems(regular),
        },
        {
            text = _("Built-in OPDS feeds"),
            sub_item_table = shelfItems(builtin),
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

function CwaMagicDownload:getAuth()
    return (self.settings.username or "") .. ":" .. (self.settings.password or "")
end

function CwaMagicDownload:fetchUrlToFile(url, out_file, max_time)
    local cmd = table.concat({
        "/system/bin/curl -fsSL",
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

    local magic_file = "/data/data/org.koreader.launcher/cache/cwamagicdownload-magic-shelves.xml"
    local regular_file = "/data/data/org.koreader.launcher/cache/cwamagicdownload-regular-shelves.xml"
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
    local feed_file = "/data/data/org.koreader.launcher/cache/cwamagicdownload-read.xml"

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

function CwaMagicDownload:collectShelfBooks(shelf, read_ids)
    local selected = {}
    local limit = self.settings.limit or 25
    local next_path = shelf.path
    local page = 0
    local feed_file = "/data/data/org.koreader.launcher/cache/cwamagicdownload-feed.xml"
    local read_filter = self.settings.read_filter or "unread"

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
                table.insert(selected, book)
                if #selected >= limit then break end
            end
        end
        next_path = parseNextPath(xml)
    end

    return selected
end

function CwaMagicDownload:pruneUnmatchedFiles(target_dir, wanted_files)
    local list_file = "/data/data/org.koreader.launcher/cache/cwamagicdownload-files.txt"
    os.execute("find " .. shellQuote(target_dir) .. " -maxdepth 1 -type f > " .. shellQuote(list_file))
    local files = readFile(list_file) or ""
    local pruned = 0
    for path in files:gmatch("[^\r\n]+") do
        local filename = path:match("([^/]+)$")
        if filename and not filename:match("%.part$") and not wanted_files[filename] then
            os.execute("rm -f " .. shellQuote(path))
            pruned = pruned + 1
        end
    end
    return pruned
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
    local filter = getReadFilterById(self.settings.read_filter or "unread")
    local count = selectedShelfCount(self.settings)
    self:showMessage(T(_("Syncing %1 shelves\nFilter: %2\nPlease wait. KOReader may not respond until this finishes."),
        count, filter.name), 120)
    UIManager:scheduleIn(0.25, function()
        local ok, err = pcall(function()
            self:syncSelectedShelfNow()
        end)
        if not ok then
            self.is_syncing = false
            logger.warn("CWA Magic Downloads: sync failed unexpectedly", err)
            self:showMessage(_("CWA Magic Downloads failed. Check the KOReader log for details."), 8)
        end
    end)
end

function CwaMagicDownload:syncOneShelf(shelf, read_ids)
    local root = self.settings.download_root or getHomeDir()
    local target_dir = joinPath(root, shelf.folder)
    local read_filter = self.settings.read_filter or "unread"
    os.execute("mkdir -p " .. shellQuote(target_dir))

    local books, err = self:collectShelfBooks(shelf, read_ids)
    if not books then
        return { failed = 1, message = err or _("Could not fetch the shelf feed. Check Wi-Fi and login.") }
    end
    if #books == 0 then
        return { empty = 1, folder = target_dir }
    end

    local downloaded, skipped, failed, pruned, retimed = 0, 0, 0, 0, 0
    local wanted_files = {}
    for _, book in ipairs(books) do
        local filename = safeFilename(book.title, book.format)
        wanted_files[filename] = true
        local out_path = joinPath(target_dir, filename)
        if fileExists(out_path) then
            if self:applyBookTimestamp(book, out_path) then
                retimed = retimed + 1
            end
            skipped = skipped + 1
        else
            local tmp_path = out_path .. ".part"
            local book_url = joinUrl(self.settings.server, book.href)
            local book_cmd = table.concat({
                "/system/bin/curl -fsSL",
                "--connect-timeout 20",
                "--max-time 300",
                "-u", shellQuote(self:getAuth()),
                "-o", shellQuote(tmp_path),
                shellQuote(book_url),
                "&& mv", shellQuote(tmp_path), shellQuote(out_path),
            }, " ")
            local ok = os.execute(book_cmd)
            if ok == true or ok == 0 then
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
        folder = target_dir,
    }
end

function CwaMagicDownload:syncSelectedShelfNow()
    if NetworkMgr:willRerunWhenOnline(function() self:syncSelectedShelf() end) then
        self.is_syncing = false
        return
    end
    if not self.settings.password or not self.settings.username or not self.settings.server then
        self:showMessage(_("Set the CWA server login first."))
        self.is_syncing = false
        return
    end

    self:refreshShelfList(false)
    local selected_shelves = {}
    for _, shelf in ipairs(allShelves(self.settings)) do
        if self.settings.selected_shelves and self.settings.selected_shelves[shelf.id] then
            table.insert(selected_shelves, shelf)
        end
    end
    if #selected_shelves == 0 then
        self:showMessage(_("Select at least one shelf to sync."))
        self.is_syncing = false
        return
    end

    local read_filter = self.settings.read_filter or "unread"
    local read_ids = {}
    if read_filter ~= "all" then
        read_ids = self:loadReadIds()
        if not read_ids then
            self:showMessage(_("Could not fetch read status. Check Wi-Fi and login."))
            self.is_syncing = false
            return
        end
    end

    local totals = { downloaded = 0, skipped = 0, failed = 0, pruned = 0, retimed = 0, empty = 0 }
    local messages = {}
    for _, shelf in ipairs(selected_shelves) do
        local result = self:syncOneShelf(shelf, read_ids)
        for key, value in pairs(totals) do
            totals[key] = value + (result[key] or 0)
        end
        if result.message then
            table.insert(messages, shelf.name .. ": " .. result.message)
        end
    end

    G_reader_settings:saveSetting("cwamagicdownload", self.settings)
    self.is_syncing = false
    local message = T(_("%1 shelves complete\nFilter: %2\nDownloaded: %3\nSkipped: %4\nRetimed: %5\nRemoved: %6\nEmpty: %7\nFailed: %8"),
        #selected_shelves, getReadFilterById(read_filter).name, totals.downloaded, totals.skipped, totals.retimed, totals.pruned, totals.empty, totals.failed)
    if #messages > 0 then
        message = message .. "\n" .. table.concat(messages, "\n")
    end
    self:showMessage(message, 14)
end

return CwaMagicDownload
