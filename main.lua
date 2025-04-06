local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local DocSettings = require("docsettings")
local http = require("socket.http")
local socket = require("socket")
local ltn12 = require("ltn12")
local JSON = require("json")

local Dispatcher = require("dispatcher") -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local KeyValuePage = require("ui/widget/keyvaluepage")
local ConfirmBox = require("ui/widget/confirmbox")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local TouchMenu = require("ui/widget/touchmenu")
local InputDialog = require("ui/widget/inputdialog")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local Blitbuffer = require("ffi/blitbuffer")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local _ = require("gettext")

local SQ3 = require("lua-ljsqlite3/init")

local logger = require("logger")
local util = require("util")

local goodreads_dir = DataStorage:getDataDir() .. "/goodreads_connector/"
local db_location = DataStorage:getSettingsDir() .. "/goodreads_connector.sqlite3"

local statistics_dir = DataStorage:getDataDir() .. "/statistics/"
local stats_db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"


local Goodreads_Connector = WidgetContainer:extend {
    name = "Goodreads Connector",
    is_doc_only = false,
}

function Goodreads_Connector:onDispatcherRegisterActions()
    Dispatcher:registerAction("helloworld_action",
        { category = "none", event = "HelloWorld", title = _("Hello World"), general = true, })
end

function Goodreads_Connector:onReaderReady(config)
    self.data = config:readSetting("stats", { performance_in_pages = {} })
    self.doc_md5 = config:readSetting("partial_md5_checksum")
    self.ui_ref = self.ui
end

function Goodreads_Connector:onPageUpdate(pageno)
    logger.info("Page update: ", pageno)
    if self.data == nil then
        return
    end
    self.data.curr_page = pageno
end

function Goodreads_Connector:onCloseDocument()
    if self.data.curr_page == nil then
        return
    end

    self:updateDB()
end

function Goodreads_Connector:getBookId(title, authors, md5)
    local conn = SQ3.open(db_location)
    local sql_stmt = [[
            SELECT id
            FROM   book
            WHERE  title = ?
                AND   author = ?
                AND    md5 = ?;
        ]]
    local stmt = conn:prepare(sql_stmt)
    local result = stmt:reset():bind(title, authors, md5):step()
    conn:close()

    if result == nil then
        return nil
    end
    return result[1]
end

function Goodreads_Connector:getGRBookId(book_id)
    local conn = SQ3.open(db_location)
    local sql_stmt = [[
            SELECT goodreads_id
            FROM   book
            WHERE  id = ?;
        ]]
    local stmt = conn:prepare(sql_stmt)
    local result = stmt:reset():bind(book_id):step()
    conn:close()

    if result == nil then
        return nil
    end
    return result[1]
end

function Goodreads_Connector:getBookReadPages(id_book)
    if id_book == nil then
        return
    end
    local conn = SQ3.open(stats_db_location)
    local sql_stmt = [[
    SELECT count(*),
           sum(durations)
    FROM (
        SELECT min(sum(duration), %d) AS durations
        FROM page_stat
        WHERE id_book = %d
        GROUP BY page
    );
    ]]

    local total_pages, total_time = conn:rowexec(string.format(sql_stmt, 120, id_book))
    conn:close()

    if total_pages then
        total_pages = tonumber(total_pages)
    else
        total_pages = 0
    end
    if total_time then
        total_time = tonumber(total_time)
    else
        total_time = 0
    end
    return total_pages, total_time
end

function Goodreads_Connector:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:createDBs()
    self:initSettings()
end

function Goodreads_Connector:addToMainMenu(menu_items)
    menu_items.goodreads_connector = {
        text = _("Goodreads - Connector"),

        sub_item_table = {
            -- {
            --     text = _("Test Button"),
            --     callback = function()
            --         self:tryUI()
            --     end,
            -- },
            {
                text = _("Sync Book"),
                keep_menu_open = true,
                -- checked_func = function()
                --     return false
                -- end,
                callback = function()
                    NetworkMgr:runWhenOnline(function() self:syncBook() end)
                end,
                enabled = self.ui.file_chooser == nil,
            },
            {
                text = _("Sync Books"),
                keep_menu_open = true,
                separator = true,
                callback = function()
                    NetworkMgr:runWhenOnline(function()
                        -- logger.info(self.data)
                    end)
                end,
            },
            {
                text = _("Remove Link"),
                keep_menu_open = true,
                callback = function()
                    self:viewLinkedBooks()
                end,
            },
            {
                text = _("Settings"),
                keep_menu_open = true,
                sub_item_table = {
                    {
                        text = _("Set Email"),
                        keep_menu_open = true,
                        callback = function()
                            self:setEmail()
                        end,
                    },
                    {
                        text = _("Set Password"),
                        keep_menu_open = true,
                        callback = function()
                            self:setPassword()
                        end,
                    },
                    {
                        text = _("Set Server"),
                        keep_menu_open = true,
                        separator = true,
                        callback = function()
                            self:setServer()
                        end,
                    },
                    {
                        text = _("Connect"),
                        keep_menu_open = true,
                        callback = function()
                            NetworkMgr:runWhenOnline(function()
                                self:connect()
                            end)
                        end,
                    },

                },
            },
        },

        sorting_hint = "tools",
    }
end

function Goodreads_Connector:createDBs()
    local conn = SQ3.open(db_location)
    local sql_stmt = [[
        -- book
        CREATE TABLE IF NOT EXISTS book
            (
                id integer PRIMARY KEY autoincrement,
                title text,
                author text,
                goodreads_title text,
                goodreads_id      integer,
                md5 text,
                curr_pages integer,
                updated_pages integer,
                to_sync integer
            );
    ]]
    conn:exec(sql_stmt)
end

function Goodreads_Connector:initSettings()
    self.settings = {
        email = nil,
        password = nil,
        server = nil,
        user_id = nil,
    }

    self.settings.email = G_reader_settings:readSetting("goodreads_email")
    self.settings.password = G_reader_settings:readSetting("goodreads_password")
    self.settings.server = G_reader_settings:readSetting("api_server")
    self.settings.user_id = G_reader_settings:readSetting("api_user_id")
end

function Goodreads_Connector:updateDB()
    logger.dbg("Updating Book pages")
    local id_book = Goodreads_Connector:getBookId(self.data.title, self.data.authors, self.doc_md5)

    if id_book == nil then
        return
    end

    local conn = SQ3.open(db_location)
    local sql_stmt = [[
        UPDATE book
        SET updated_pages = ?,
            to_sync = ?
        WHERE id = ? and curr_pages != ?;
    ]]
    local stmt = conn:prepare(sql_stmt)
    stmt:reset():bind(self.data.curr_page, 1, id_book, self.data.curr_page):step()
    conn:close()
end

function Goodreads_Connector:onHelloWorld(str)
    local popup = InfoMessage:new {
        text = _(str),
    }
    UIManager:show(popup)
end

------------------------------------------------------

function Goodreads_Connector:syncBook()
    logger.info("Syncing book")

    if (self.settings.server == nil or self.settings.email == nil or self.settings.password == nil or self.settings.user_id == nil) then
        UIManager:show(InfoMessage:new {
            text = _("Missing some configurations!"),
        })
        return
    end

    local id_book = Goodreads_Connector:getBookId(self.data.title, self.data.authors, self.doc_md5)

    if id_book == nil then
        local books, shelves = Goodreads_Connector:getBooks(self.settings.server, self.settings.user_id)
        Goodreads_Connector:viewShelves(
            shelves,
            books,
            function(goodreads_id, goodreads_title)
                self:createLink(self.data.title, self.data.authors, self.doc_md5, goodreads_id,
                    goodreads_title, self.data.curr_page, self.data.pages)
            end)
    else
        local goodreads_id = Goodreads_Connector:getGRBookId(id_book)

        if goodreads_id == nil then
            UIManager:show(InfoMessage:new {
                text = _("Book not linked to goodreads"),
            })
            return
        end
        local percentage = self.data.curr_page / self.data.pages * 100
        Goodreads_Connector:updateProgress(self.settings.server, self.settings.user_id, tostring(goodreads_id),
            percentage)
    end
end

------------------------------------------------------
---
function Goodreads_Connector:setEmail()
    local function emailCheck(e)
        if e:match(".+@.+%.%w+") then
            return true
        end
        return false
    end
    local email_dialog
    email_dialog = InputDialog:new {
        title = _("Set the email for goodreads account"),
        input = G_reader_settings:readSetting("goodreads_email") or "",
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(email_dialog)
                end,
            },
            {
                text = _("Set email"),
                callback = function()
                    local email = email_dialog:getInputText()
                    if emailCheck(email) then
                        G_reader_settings:saveSetting("goodreads_email", email)
                        UIManager:show(InfoMessage:new {
                            text = _("Email saved"),
                        })
                        self.settings.email = email
                    else
                        G_reader_settings:delSetting("goodreads_email")
                        UIManager:show(InfoMessage:new {
                            text = _("Invalid email address"),
                        })
                    end
                    UIManager:close(email_dialog)
                end,
            },
        } },
    }
    UIManager:show(email_dialog)
    email_dialog:onShowKeyboard()
end

function Goodreads_Connector:setPassword()
    local function passwordCheck(p)
        local t = type(p)
        if t == "number" or (t == "string" and p:match("%S")) then
            return true
        end
        return false
    end


    local password_dialog
    password_dialog = InputDialog:new {
        title = _("Set the password for goodreads account"),
        input = G_reader_settings:readSetting("goodreads_password") or "",
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(password_dialog)
                end,
            },
            {
                text = _("Set password"),
                callback = function()
                    local pass = password_dialog:getInputText()
                    if passwordCheck(pass) then
                        G_reader_settings:saveSetting("goodreads_password", pass)
                        UIManager:show(InfoMessage:new {
                            text = _("Password saved"),
                        })
                        self.settings.password = pass
                    else
                        G_reader_settings:delSetting("goodreads_password")
                        UIManager:show(InfoMessage:new {
                            text = _("Invalid password"),
                        })
                    end
                    UIManager:close(password_dialog)
                end,
            },
        } },
    }
    UIManager:show(password_dialog)
    password_dialog:onShowKeyboard()
end

function Goodreads_Connector:setServer()
    local function serverCheck(s)
        if s:match("https://.+%.%w+") or s:match("http://.+%.%w+") or s:match("%d+%.%d+%.%d+%.%d+") then
            return true
        end
        return false
    end
    local server_dialog
    server_dialog = InputDialog:new {
        title = _("Set the server for the API"),
        input = G_reader_settings:readSetting("api_server") or "",
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(server_dialog)
                end,
            },
            {
                text = _("Set server"),
                callback = function()
                    local server = server_dialog:getInputText()
                    if serverCheck(server) then
                        G_reader_settings:saveSetting("api_server", server)
                        UIManager:show(InfoMessage:new {
                            text = _("Server saved"),
                        })
                        self.settings.server = server
                    else
                        G_reader_settings:delSetting("api_server")
                        UIManager:show(InfoMessage:new {
                            text = _("Invalid server address"),
                        })
                    end
                    UIManager:close(server_dialog)
                end,
            },
        } },
    }
    UIManager:show(server_dialog)
    server_dialog:onShowKeyboard()
end

------------------------------------------------------
---
function Goodreads_Connector:connect()
    if (self.settings.server == nil or self.settings.email == nil or self.settings.password == nil) then
        UIManager:show(InfoMessage:new {
            text = _("Missing some configurations!"),
        })
        return
    end

    local url = self.settings.server .. "/connect?user=" .. self.settings.email .. "&pass=" .. self.settings.password
    local request = {}
    local sink = {}

    logger.info("Connecting to ", url)

    request.url = url
    request.method = "GET"
    request.sink = ltn12.sink.table(sink)

    local code, resp_headers, status = socket.skip(1, http.request(request))

    if code == 200 then
        logger.info("Request successful")
        logger.info("Response: ", status)
        local content = table.concat(sink)
        if content ~= "" and string.sub(content, 1, 1) == "{" then
            local ok, result = pcall(JSON.decode, content)
            if ok and result then
                logger.info(result)
                self.settings.user_id = result.user_id
                G_reader_settings:saveSetting("api_user_id", result.user_id)
                UIManager:show(InfoMessage:new {
                    text = _("Connected"),
                })
            else
                UIManager:show(InfoMessage:new {
                    text = _("Server response is not valid."),
                })
            end
        else
            UIManager:show(InfoMessage:new {
                text = _("Server response is not valid."),
            })
        end
    else
        logger.info("Request failed")
        logger.info("Response: ", status)
        UIManager:show(InfoMessage:new {
            text = _("Server response was not valid."),
        })
    end
end

function Goodreads_Connector:getBooks(server, user_id)
    -- Creates a request to backend http://192.168.31.208:3000/getBooks/156172432
    local url = server .. "/getBooks/" .. user_id
    local request = {}
    local sink = {}

    request.url = url
    request.method = "GET"
    request.sink = ltn12.sink.table(sink)


    local code, resp_headers, status = socket.skip(1, http.request(request))

    if code == 200 then
        logger.info("Request successful")
        logger.info("Response: ", status)
        local content = table.concat(sink)
        if content ~= "" and string.sub(content, 1, 1) == "{" then
            local ok, result = pcall(JSON.decode, content)
            if ok and result then
                return result.books, result.shelves
            else
                UIManager:show(InfoMessage:new {
                    text = _("Server response is not valid."), })
            end
        else
            UIManager:show(InfoMessage:new {
                text = _("Server response is not valid."), })
        end
    else
        logger.info("Request failed")
        logger.info("Response: ", status)
        UIManager:show(InfoMessage:new {
            text = _("Server response is not valid."), })
    end
end

function Goodreads_Connector:updateProgress(server, user_id, id_book, percentage)
    local url = server .. "/syncBooks/"
    local request = {}
    local sink = {}

    request.url = url
    request.method = "POST"
    request.sink = ltn12.sink.table(sink)

    local data = {
        user_id = user_id,
        books_id = { id_book },
        books_progress = { percentage },
    }

    logger.info(id_book, percentage)
    logger.info(data)

    request.source = ltn12.source.string(JSON.encode(data))
    request.headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = string.len(JSON.encode(data)),
    }

    local code, resp_headers, status = socket.skip(1, http.request(request))

    if code == 200 then
        logger.info("Request successful")
        logger.info("Response: ", status)
        local content = table.concat(sink)
        if content ~= "" and string.sub(content, 1, 1) == "{" then
            local ok, result = pcall(JSON.decode, content)
            if ok and result then
                logger.info(result)
                UIManager:show(InfoMessage:new {
                    text = _("Book synced"),
                })
            else
                UIManager:show(InfoMessage:new {
                    text = _("Server response is not valid."),
                })
            end
        else
            UIManager:show(InfoMessage:new {
                text = _("Server response is not valid."),
            })
        end
    else
        logger.info("Request failed")
        logger.info("Response: ", status)
        UIManager:show(InfoMessage:new {
            text = _("Server response is not valid."),
        })
    end
end

------------------------------------------------------
---
function Goodreads_Connector:viewLinkedBooks()
    local conn = SQ3.open(db_location)
    local sql_stmt = [[
        SELECT id, title, goodreads_id, goodreads_title, author
        FROM book
    ]]
    local stmt = conn:prepare(sql_stmt)
    local rows = stmt:rows()

    local kv_pairs = {}

    for row in rows do
        local id, title, goodreads_id, goodreads_title, author = row[1], row[2], row[3], row[4], row[5]
        local book_content = { {
            _("ID"),
            id,
        }, {
            _("Title"),
            title,
        }, {
            _("Author"),
            author,
        }, {
            _("Goodreads Title"),
            goodreads_title,
        }, {
            _("Goodreads ID"),
            goodreads_id,
            separator = true,
        }, {
            _("Unlink"),
            "",
            callback = function()
                self:deleteLink(id)
            end
        } }
        table.insert(kv_pairs, {
            title,
            "",
            callback = function()
                self:viewItem(book_content, function() self:viewLinkedBooks() end)
            end
        })
    end

    if self.kv then
        UIManager:close(self.kv)
    end
    self.kv = KeyValuePage:new {
        title = _("Current Linked Books"),
        value_overflow_align = "right",
        kv_pairs = kv_pairs,
        callback_return = function()
            UIManager:close(self.kv)
        end
    }
    UIManager:show(self.kv)
end

function Goodreads_Connector:deleteLink(id)
    local conn = SQ3.open(db_location)
    local sql_stmt = [[
        DELETE FROM book
        WHERE id = ?
    ]]
    local stmt = conn:prepare(sql_stmt)
    stmt:reset():bind(id):step()
    conn:close()

    if self.kv then
        UIManager:close(self.kv)
    end

    Goodreads_Connector:viewLinkedBooks()
end

------------------------------------------------------
---
function Goodreads_Connector:viewShelves(shelves, books, create_link)
    local shelves_table = {}

    for index, shelve in ipairs(shelves) do
        table.insert(shelves_table, {
            shelve,
            "",
            callback = function()
                self:viewBooks(shelve, books, create_link, function() self:viewShelves(shelves, books, create_link) end)
            end,
        })
    end

    if self.kv then
        UIManager:close(self.kv)
    end

    self.kv = KeyValuePage:new {
        title = _("Shelves"),
        value_overflow_align = "right",
        kv_pairs = shelves_table,
        callback_return = function()
            UIManager:close(self.kv)
        end
    }
    UIManager:show(self.kv)
end

function Goodreads_Connector:viewBooks(shelve, books, create_link, callback)
    local books_table = {}
    for index, book in ipairs(books) do
        if shelve == 'all' or string.find(book.shelve, shelve, 1, true) ~= nil then
            local book_content = {
                {
                    _("Title"),
                    book.title,
                }, {
                _("Author"),
                book.author,
            }, {
                _("ID (Goodreads)"),
                book.id,
                separator = true,
            }, {
                _("Link to book"),
                "",
                callback = function()
                    create_link(book.id, book.title)
                    UIManager:show(InfoMessage:new {
                        text = _("Book linked"),
                    })
                    if self.kv then
                        UIManager:close(self.kv)
                    end
                end
            } }
            table.insert(books_table, {
                book.title,
                "",
                callback = function()
                    self:viewItem(book_content, function() self:viewBooks(shelve, books, create_link, callback) end)
                end,
            })
        end
    end

    if self.kv then
        UIManager:close(self.kv)
    end
    self.kv = KeyValuePage:new {
        title = _("Books in " .. shelve),
        value_overflow_align = "right",
        kv_pairs = books_table,
        callback_return = function()
            callback()
        end
    }
    UIManager:show(self.kv)
end

function Goodreads_Connector:createLink(title, authors, md5, goodreads_id, goodreads_title, curr_page, pages)
    local conn = SQ3.open(db_location)
    local sql_stmt = [[
        INSERT INTO book (title, author, goodreads_title, goodreads_id, md5, curr_pages, updated_pages, to_sync)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
    ]]
    local stmt = conn:prepare(sql_stmt)
    stmt:reset():bind(title, authors, goodreads_title, goodreads_id, md5, curr_page, curr_page, 0):step()
    conn:close()



    local percentage = curr_page / pages * 100
    Goodreads_Connector:updateProgress(self.settings.server, self.settings.user_id, goodreads_id, percentage)
end

------------------------------------------------------
---
function Goodreads_Connector:viewItem(data, callback)
    if self.kv then
        UIManager:close(self.kv)
    end
    self.kv = KeyValuePage:new {
        title = _("Book Info"),
        value_overflow_align = "left",
        kv_pairs = data,
        callback_return = function()
            callback()
        end
    }
    UIManager:show(self.kv)
end

return Goodreads_Connector
