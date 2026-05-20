local urlparse = require("socket.url")
local http = require("socket.http")
local cjson = require("cjson")
local utf8 = require("utf8")

local item_dir = os.getenv("item_dir")
local warc_file_base = os.getenv("warc_file_base")
local concurrency = tonumber(os.getenv("concurrency"))
local item_type = nil
local item_name = nil
local item_value = nil

local url_count = 0
local tries = 0
local downloaded = {}
local seen_200 = {}
local addedtolist = {}
local abortgrab = false
local killgrab = false
local logged_response = false

local discovered_outlinks = {}
local discovered_items = {}
local bad_items = {}
local ids = {}

local retry_url = false
local is_initial_url = true

local item_patterns = {
  ["^https?://api%.rec%.net/api/images/v4/([0-9]+)$"]="image",
  ["^https?://rooms%.rec%.net/rooms/([0-9]+)$"]="room",
  ["^https?://accounts%.rec%.net/account/bulk%?id=([0-9]+)$"]="account",
  ["^https?://apim%.rec%.net/apis/api/playerevents/v1/([0-9]+)/?$"]="event",
  ["^https?://img%.rec%.net/([^?]+)"]="img",
  ["^https?://(cdn%.rec%.net/.+)$"]="asset",
  ["^https?://(rec%.net/_next/image%?.+)$"]="asset",
  ["^https?://(rec%.net/_next/static/.+)$"]="asset"
}

abort_item = function(item)
  abortgrab = true
  if not item then
    item = item_name
  end
  if not bad_items[item] then
    io.stdout:write("Aborting item " .. item .. ".\n")
    io.stdout:flush()
    bad_items[item] = true
  end
end

kill_grab = function(item)
  io.stdout:write("Aborting crawling.\n")
  io.stdout:flush()
  killgrab = true
end

read_file = function(file)
  if file then
    local f = assert(io.open(file, "rb"))
    local data = f:read("*all")
    f:close()
    return data
  else
    return ""
  end
end

processed = function(url)
  if downloaded[url] or addedtolist[url] then
    return true
  end
  return false
end

discover_item = function(target, item)
  if item ~= item_name and not target[item] then
--print("discovered", item)
    target[item] = true
    return true
  end
  return false
end

find_item = function(url)
  for pattern, name in pairs(item_patterns) do
    local value = string.match(url, pattern)
    if value then
      return {
        ["value"]=value,
        ["type"]=name
      }
    end
  end
end

set_item = function(url)
  if ids[string.lower(url)] then
    return nil
  end
  local found = find_item(url)
  if found then
    local newcontext = {}
    local new_item_type = found["type"]
    local new_item_value = found["value"]
    local new_item_name = new_item_type .. ":" .. new_item_value
    if new_item_name ~= item_name then
      ids = {}
      context = newcontext
      item_value = new_item_value
      item_type = new_item_type
      ids[string.lower(item_value)] = true
      ids[string.lower(url)] = true
      abortgrab = false
      tries = 0
      retry_url = false
      is_initial_url = true
      item_name = new_item_name
      print("Archiving item " .. item_name)
    end
  end
end

percent_encode_url = function(url)
  local temp = ""
  for c in string.gmatch(url, "(.)") do
    local b = string.byte(c)
    if b < 32 or b > 126 then
      c = string.format("%%%02X", b)
    end
    temp = temp .. c
  end
  return temp
end

allowed = function(url, parenturl)
  if ids[url] or ids[string.lower(url)] then
    return true
  end

  local found = find_item(url)
  if found then
    local found_item_name = found["type"] .. ":" .. found["value"]
    if found_item_name ~= item_name then
      discover_item(discovered_items, found_item_name)
      return false
    end
  end

  local host = string.match(url, "^https?://([^/:]+)")
  if host
    and host ~= "rec.net"
    and not string.match(host, "%.rec%.net$") then
    discover_item(discovered_outlinks, percent_encode_url(string.match(url, "^([^%s]+)")))
    return false
  end

  for _, pattern in pairs({
    "([0-9]+)",
    "([0-9a-zA-Z_]+)",
    "([0-9a-zA-Z_%%%.]+)"
  }) do
    for s in string.gmatch(url, pattern) do
      s = urlparse.unescape(s)
      if ids[string.lower(s)] then
        return true
      end
    end
  end

  return false
end

wget.callbacks.download_child_p = function(urlpos, parent, depth, start_url_parsed, iri, verdict, reason)
  return false
end

decode_codepoint = function(newurl)
  newurl = string.gsub(
    newurl, "\\[uU]([0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])",
    function (s)
      return utf8.char(tonumber(s, 16))
    end
  )
  return newurl
end

wget.callbacks.get_urls = function(file, url, is_css, iri)
  local urls = {}
  local html = nil
  local json = nil

  downloaded[url] = true
  set_item(url)

  if abortgrab then
    return {}
  end

  local function fix_case(newurl)
    if not newurl then
      newurl = ""
    end
    if not string.match(newurl, "^https?://[^/]") then
      return newurl
    end
    if string.match(newurl, "^https?://[^/]+$") then
      newurl = newurl .. "/"
    end
    local a, b = string.match(newurl, "^(https?://[^/]+/)(.*)$")
    return string.lower(a) .. b
  end

  local function check(newurl, headers, body_data, method)
    if not newurl then
      newurl = ""
    end
    if not string.match(newurl, "^https?://") then
      return nil
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "%s")
      or string.match(newurl, "\\") then
      return nil
    end
    newurl = fix_case(newurl)
    local origurl = url
    if string.len(url) == 0
      or string.len(newurl) == 0 then
      return nil
    end
    local url = string.match(newurl, "^([^#]+)")
    local url_ = url
    while string.match(url_, "&amp;") do
      url_ = string.gsub(url_, "&amp;", "&")
    end
    local key = (method or "GET") .. "\0" .. url_ .. "\0" .. tostring(body_data)
    if not processed(key)
      and (body_data or not processed(url_))
      and allowed(url_, origurl) then
      local url_data = {
        url=url_,
        headers=headers or {}
      }
      if body_data then
        url_data["body_data"] = body_data
        url_data["method"] = method or "POST"
      end
      table.insert(urls, url_data)
      addedtolist[key] = true
      if not body_data then
        addedtolist[url_] = true
        addedtolist[url] = true
      end
    end
  end

  local function checknewurl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "['\"><]") then
      return nil
    end
    if string.match(newurl, "^https?:////") then
      check(string.gsub(newurl, ":////", "://"))
    elseif string.match(newurl, "^https?://") then
      check(newurl)
    elseif string.match(newurl, "^https?:\\/\\?/") then
      check(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^\\/\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^//") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^\\/") then
      checknewurl(string.gsub(newurl, "\\", ""))
    elseif string.match(newurl, "^/") then
      check(urlparse.absolute(url, newurl))
    elseif string.match(newurl, "^%.%./") then
      if string.match(url, "^https?://[^/]+/[^/]+/") then
        check(urlparse.absolute(url, newurl))
      else
        checknewurl(string.match(newurl, "^%.%.(/.+)$"))
      end
    elseif string.match(newurl, "^%./") then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function checknewshorturl(newurl)
    if not newurl then
      newurl = ""
    end
    newurl = decode_codepoint(newurl)
    if string.match(newurl, "^%?") then
      check(urlparse.absolute(url, newurl))
    elseif not (
      string.match(newurl, "^https?:\\?/\\?//?/?")
      or string.match(newurl, "^[/\\]")
      or string.match(newurl, "^%./")
      or string.match(newurl, "^[jJ]ava[sS]cript:")
      or string.match(newurl, "^[mM]ail[tT]o:")
      or string.match(newurl, "^vine:")
      or string.match(newurl, "^android%-app:")
      or string.match(newurl, "^ios%-app:")
      or string.match(newurl, "^data:")
      or string.match(newurl, "^irc:")
      or string.match(newurl, "^%${")
    ) then
      check(urlparse.absolute(url, newurl))
    end
  end

  local function clean_value(value)
    if value
      and value ~= cjson.null then
      return tostring(value)
    end
  end

  local function check_image_name(image_name)
    image_name = clean_value(image_name)
    if image_name
      and string.len(image_name) > 0 then
      check("https://img.rec.net/" .. image_name)
      ids["https://apim.rec.net/apis/api/images/v4/bulk"] = true
      check(
        "https://apim.rec.net/apis/api/images/v4/bulk",
        {["Content-Type"]="application/json"},
        cjson.encode({["Names"]={image_name}})
      )
    end
  end

  local function check_bulk_ids(base_url, id_list)
    local bulk_url = base_url
    local count = 0
    for _, id in ipairs(id_list) do
      local part = (count == 0 and "?id=" or "&id=") .. id
      if count > 1
        and string.len(bulk_url .. part) > 2048 then
        ids[string.lower(bulk_url)] = true
        check(bulk_url)
        bulk_url = base_url
        count = 0
        part = "?id=" .. id
      end
      bulk_url = bulk_url .. part
      count = count + 1
    end
    if count > 1 then
      ids[string.lower(bulk_url)] = true
      check(bulk_url)
    end
  end

  local function get_count(data)
    local count = 0
    for _ in pairs(data) do
      count = count + 1
    end
    return count
  end

  local function discover_json(data, json_data)
    if data then
      for _, pattern in pairs({
        '[^\\]"ImageName"%s*:%s*"([^"\\]+)"',
        '[^\\]"profileImage"%s*:%s*"([^"\\]+)"',
        '[^\\]"bannerImage"%s*:%s*"([^"\\]+)"'
      }) do
        for image_name in string.gmatch(data, pattern) do
          check("https://img.rec.net/" .. image_name)
        end
      end
      for id in string.gmatch(data, '"RoomId"%s*:%s*([0-9]+)') do
        check("https://rooms.rec.net/rooms/" .. id)
      end
      for _, pattern in pairs({
        '"CreatorAccountId"%s*:%s*([0-9]+)',
        '"CreatorPlayerId"%s*:%s*([0-9]+)',
        '"PlayerId"%s*:%s*([0-9]+)',
        '"accountId"%s*:%s*([0-9]+)'
      }) do
        for id in string.gmatch(data, pattern) do
          check("https://accounts.rec.net/account/bulk?id=" .. id)
        end
      end
      for id in string.gmatch(data, '"PlayerEventId"%s*:%s*([0-9]+)') do
        check("https://apim.rec.net/apis/api/playerevents/v1/" .. id)
      end
      for tagged_ids in string.gmatch(data, '"TaggedPlayerIds"%s*:%s*%[([^%]]*)%]') do
        for id in string.gmatch(tagged_ids, "([0-9]+)") do
          check("https://accounts.rec.net/account/bulk?id=" .. id)
        end
      end
    end
    if type(json_data) == "table" then
      for _, value in pairs(json_data) do
        discover_json(nil, value)
      end
    elseif type(json_data) == "string" then
      check(json_data)
    end
  end

  if item_type == "img"
    and string.match(url, "^https?://img%.rec%.net/") then
    local base = "https://img.rec.net/" .. item_value
    for _, suffix in ipairs({
      "",
      "?width=1920",
      "?width=512",
      "?width=192&cropSquare=true",
      "?cropSquare=true&width=40&height=40",
      "?cropSquare=true&width=192&height=192"
    }) do
      local image_url = base .. suffix
      ids[string.lower(image_url)] = true
      check(image_url)
    end
  end

  if item_type ~= "asset"
    and item_type ~= "img"
    and allowed(url)
    and status_code < 300 then
    html = read_file(file)
    if string.match(url, "^https?://api%.rec%.net/api/images/v4/[0-9]+$")
      or string.match(url, "^https?://rooms%.rec%.net/rooms/[0-9]+$")
      or string.match(url, "^https?://rooms%.rec%.net/rooms/bulk%?")
      or string.match(url, "^https?://rooms%.rec%.net/rooms/ownedby/[0-9]+")
      or string.match(url, "^https?://rooms%.rec%.net/showcase/[0-9]+")
      or string.match(url, "^https?://accounts%.rec%.net/account/bulk%?")
      or string.match(url, "^https?://apim%.rec%.net/")
      or string.match(url, "^https?://clubs%.rec%.net/")
      or string.match(url, "^https?://econ%.rec%.net/") then
      json = cjson.decode(html)
      if string.match(url, "^https?://api%.rec%.net/api/images/v4/[0-9]+$") then
        check("https://rec.net/image/" .. item_value)
        check("https://apim.rec.net/apis/api/images/v1/" .. item_value .. "/comments")
        check("https://apim.rec.net/apis/api/images/v1/" .. item_value .. "/cheers")
        check_image_name(json["ImageName"])
      elseif string.match(url, "^https?://rooms%.rec%.net/rooms/[0-9]+$") then
        check_image_name(json["ImageName"])
        ids[string.lower(json["Name"])] = true
        local room_name = urlparse.escape(json["Name"])
        check("https://rec.net/room/" .. room_name)
        check("https://rec.net/room/" .. room_name .. "/events")
        check("https://rooms.rec.net/rooms/bulk?id=" .. item_value)
        check("https://apim.rec.net/rooms/rooms?name=" .. urlparse.escape(json["Name"]) .. "&include=0")
        check("https://apim.rec.net/apis/api/images/v4/room/" .. item_value .. "?skip=0&take=100&filter=1&sort=0")
        check("https://apim.rec.net/apis/api/images/v4/room/" .. item_value .. "?skip=0&take=100&filter=1&sort=1")
        check("https://apim.rec.net/apis/api/playerevents/v1/room/" .. item_value .. "?skip=0&take=50")
        check("https://apim.rec.net/apis/api/playerevents/v1/room/" .. item_value .. "?skip=0&take=100")
      elseif string.match(url, "^https?://accounts%.rec%.net/account/bulk%?id=[0-9]+$") then
        local account = json[1]
        check_image_name(account["profileImage"])
        check_image_name(account["bannerImage"])
        ids[string.lower(account["username"])] = true
        local username = urlparse.escape(account["username"])
        check("https://rec.net/user/" .. username)
        check("https://rec.net/user/" .. username .. "/photos")
        check("https://rec.net/user/" .. username .. "/rooms")
        check("https://rec.net/user/" .. username .. "/events")
        check("https://apim.rec.net/accounts/account/bulk?id=" .. item_value)
        check("https://apim.rec.net/accounts/account/" .. item_value .. "/bio")
        check("https://rooms.rec.net/showcase/" .. item_value)
        check("https://rooms.rec.net/rooms/ownedby/" .. item_value)
        check("https://clubs.rec.net/subscription/subscriberCount/" .. item_value)
        check("https://econ.rec.net/api/influencerpartnerprogram/isinfluencer?accountId=" .. item_value)
        check("https://apim.rec.net/apis/api/images/v3/feed/player/" .. item_value .. "?skip=0&take=100&since=2026-12-31T23:59:59.999Z")
        check("https://apim.rec.net/apis/api/images/v3/feed/player/" .. item_value .. "?skip=0&take=3&since=" .. os.date("!%Y-%m-%dT%H:%M:%S.000Z"))
        check("https://apim.rec.net/apis/api/images/v4/player/" .. item_value .. "?skip=0&take=20&sort=0")
        check("https://apim.rec.net/apis/api/playerevents/v1/creator/" .. item_value .. "?skip=0&take=20")
      elseif string.match(url, "^https?://apim%.rec%.net/apis/api/playerevents/v1/[0-9]+/?$") then
        check("https://rec.net/event/" .. item_value)
        check("https://rec.net/event/" .. item_value .. "/photos")
        check("https://apim.rec.net/apis/api/playerevents/v1/" .. item_value .. "/responses")
        check("https://apim.rec.net/apis/api/images/v1/playerevent/" .. item_value .. "?skip=0&take=30")
        check_image_name(json["ImageName"])
      elseif string.match(url, "^https?://apim%.rec%.net/apis/api/images/v4/room/[0-9]+%?") then
        local room_id, skip, take, filter, sort = string.match(url, "/v4/room/([0-9]+)%?skip=([0-9]+)&take=([0-9]+)&filter=([0-9]+)&sort=([0-9]+)$")
        local image_ids = {}
        local account_ids = {}
        local seen_account_ids = {}
        for i, image in ipairs(json) do
          local image_id = clean_value(image["Id"])
          if image_id then
            table.insert(image_ids, image_id)
            check("https://api.rec.net/api/images/v4/" .. image_id)
          end
          if i == 1
            and skip == "0" then
            local account_id = clean_value(image["PlayerId"])
            if account_id
              and not seen_account_ids[account_id] then
              table.insert(account_ids, account_id)
              seen_account_ids[account_id] = true
            end
            if image["TaggedPlayerIds"] then
              for _, tagged_account_id in ipairs(image["TaggedPlayerIds"]) do
                tagged_account_id = clean_value(tagged_account_id)
                if tagged_account_id
                  and not seen_account_ids[tagged_account_id] then
                  table.insert(account_ids, tagged_account_id)
                  seen_account_ids[tagged_account_id] = true
                end
              end
            end
          end
        end
        check_bulk_ids("https://accounts.rec.net/account/bulk", account_ids)
        if #image_ids > 0 then
          ids["https://apim.rec.net/apis/api/images/v3/bulk"] = true
          check(
            "https://apim.rec.net/apis/api/images/v3/bulk",
            {["Content-Type"]="application/json"},
            cjson.encode({["Ids"]=image_ids})
          )
        end
        if room_id == item_value
          and sort == "0"
          and get_count(json) == tonumber(take) then
          check(
            "https://apim.rec.net/apis/api/images/v4/room/"
            .. room_id .. "?skip=" .. (tonumber(skip) + tonumber(take))
            .. "&take=" .. take .. "&filter=" .. filter .. "&sort=" .. sort
          )
        end
      elseif string.match(url, "^https?://apim%.rec%.net/apis/api/images/v3/feed/player/([0-9]+)%?") == item_value
        or string.match(url, "^https?://apim%.rec%.net/apis/api/images/v4/player/([0-9]+)%?") == item_value then
        local room_ids = {}
        local account_ids = {}
        local seen_account_ids = {}
        local seen_room_ids = {}
        for room_id in string.gmatch(html, '"RoomId"%s*:%s*([0-9]+)') do
          if not seen_room_ids[room_id] then
            table.insert(room_ids, room_id)
            seen_room_ids[room_id] = true
          end
        end
        for _, image in ipairs(json) do
          local account_id = clean_value(image["PlayerId"])
          if account_id
            and account_id ~= item_value
            and not seen_account_ids[account_id] then
            table.insert(account_ids, account_id)
            seen_account_ids[account_id] = true
          end
          if image["TaggedPlayerIds"] then
            for _, tagged_account_id in ipairs(image["TaggedPlayerIds"]) do
              tagged_account_id = clean_value(tagged_account_id)
              if tagged_account_id
                and tagged_account_id ~= item_value
                and not seen_account_ids[tagged_account_id] then
                table.insert(account_ids, tagged_account_id)
                seen_account_ids[tagged_account_id] = true
              end
            end
          end
        end
        check_bulk_ids("https://rooms.rec.net/rooms/bulk", room_ids)
        check_bulk_ids("https://accounts.rec.net/account/bulk", account_ids)
        local account_id, skip, take, sort = string.match(url, "/v4/player/([0-9]+)%?skip=([0-9]+)&take=([0-9]+)&sort=([0-9]+)$")
        if account_id == item_value
          and get_count(json) == tonumber(take) then
          check(
            "https://apim.rec.net/apis/api/images/v4/player/"
            .. account_id .. "?skip=" .. (tonumber(skip) + tonumber(take))
            .. "&take=" .. take .. "&sort=" .. sort
          )
        end
        local feed_account_id, feed_skip, feed_take, since = string.match(url, "/v3/feed/player/([0-9]+)%?skip=([0-9]+)&take=([0-9]+)&since=([^&]+)$")
        if feed_account_id == item_value
          and since ~= "2026-12-31T23:59:59.999Z"
          and get_count(json) == tonumber(feed_take) then
          check(
            "https://apim.rec.net/apis/api/images/v3/feed/player/"
            .. feed_account_id .. "?skip=" .. (tonumber(feed_skip) + tonumber(feed_take))
            .. "&take=" .. feed_take .. "&since=" .. os.date("!%Y-%m-%dT%H:%M:%S.000Z")
          )
        end
      elseif string.match(url, "^https?://rooms%.rec%.net/rooms/ownedby/([0-9]+)") == item_value then
        local account_ids = {}
        local seen_account_ids = {}
        for _, room in ipairs(json) do
          local account_id = clean_value(room["CreatorAccountId"])
          if account_id
            and account_id ~= item_value
            and not seen_account_ids[account_id] then
            table.insert(account_ids, account_id)
            seen_account_ids[account_id] = true
          end
        end
        check_bulk_ids("https://accounts.rec.net/account/bulk", account_ids)
      end
      if string.match(url, "/playerevents/v1/.+/responses$")
        or string.match(url, "/playerevents/v1/room/[0-9]+%?")
        or string.match(url, "/playerevents/v1/creator/[0-9]+%?") then
        local account_ids = {}
        local seen_account_ids = {}
        local room_ids = {}
        local seen_room_ids = {}
        local skip_account_id = string.match(url, "/playerevents/v1/creator/([0-9]+)%?")
        for id in string.gmatch(html, '"RoomId"%s*:%s*([0-9]+)') do
          if not seen_room_ids[id] then
            table.insert(room_ids, id)
            seen_room_ids[id] = true
          end
        end
        for _, pattern in pairs({
          '"CreatorAccountId"%s*:%s*([0-9]+)',
          '"CreatorPlayerId"%s*:%s*([0-9]+)',
          '"PlayerId"%s*:%s*([0-9]+)',
          '"accountId"%s*:%s*([0-9]+)'
        }) do
          for id in string.gmatch(html, pattern) do
            if id ~= skip_account_id
              and not seen_account_ids[id] then
              table.insert(account_ids, id)
              seen_account_ids[id] = true
            end
          end
        end
        check_bulk_ids("https://rooms.rec.net/rooms/bulk", room_ids)
        check_bulk_ids("https://accounts.rec.net/account/bulk", account_ids)
        local room_id, skip, take = string.match(url, "/playerevents/v1/room/([0-9]+)%?skip=([0-9]+)&take=([0-9]+)$")
        if room_id == item_value
          and get_count(json) == tonumber(take) then
          check(
            "https://apim.rec.net/apis/api/playerevents/v1/room/"
            .. room_id .. "?skip=" .. (tonumber(skip) + tonumber(take))
            .. "&take=" .. take
          )
        end
        local creator_id = nil
        creator_id, skip, take = string.match(url, "/playerevents/v1/creator/([0-9]+)%?skip=([0-9]+)&take=([0-9]+)$")
        if creator_id == item_value
          and get_count(json) == tonumber(take) then
          check(
            "https://apim.rec.net/apis/api/playerevents/v1/creator/"
            .. creator_id .. "?skip=" .. (tonumber(skip) + tonumber(take))
            .. "&take=" .. take
          )
        end
      end
      if string.match(url, "^https?://apim%.rec%.net/apis/api/images/v[34]/") then
        for image_id in string.gmatch(html, '"Id"%s*:%s*([0-9]+)') do
          check("https://api.rec.net/api/images/v4/" .. image_id)
        end
      end
      if string.match(url, "^https?://apim%.rec%.net/apis/api/images/v1/playerevent/[0-9]+%?") then
        local image_ids = {}
        for image_id in string.gmatch(html, '"Id"%s*:%s*([0-9]+)') do
          table.insert(image_ids, image_id)
          check("https://api.rec.net/api/images/v4/" .. image_id)
        end
        if #image_ids > 0 then
          ids["https://apim.rec.net/apis/api/images/v3/bulk"] = true
          check(
            "https://apim.rec.net/apis/api/images/v3/bulk",
            {["Content-Type"]="application/json"},
            cjson.encode({["Ids"]=image_ids})
          )
        end
      end
      discover_json(html, json)
      if string.match(url, "^https?://apim%.rec%.net/apis/api/images/v1/[0-9]+/cheers$") then
        for account_id in string.gmatch(html, "([0-9]+)") do
          check("https://accounts.rec.net/account/bulk?id=" .. account_id)
        end
      end
    elseif string.match(url, "^https?://rec%.net/") then
      for newurl in string.gmatch(string.gsub(html, "&[qQ][uU][oO][tT];", '"'), '([^"]+)') do
        checknewurl(newurl)
      end
      for newurl in string.gmatch(string.gsub(html, "&#039;", "'"), "([^']+)") do
        checknewurl(newurl)
      end
      for newurl in string.gmatch(html, "[^%-]href='([^']+)'") do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, '[^%-]href="([^"]+)"') do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, "[^%-]src='([^']+)'") do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, '[^%-]src="([^"]+)"') do
        checknewshorturl(newurl)
      end
      for newurl in string.gmatch(html, ":%s*url%(([^%)]+)%)") do
        newurl = string.gsub(newurl, "^['\"]", "")
        newurl = string.gsub(newurl, "['\"]$", "")
        checknewurl(newurl)
      end
      html = string.gsub(html, "&gt;", ">")
      html = string.gsub(html, "&lt;", "<")
      for newurl in string.gmatch(html, ">%s*([^<%s]+)") do
        checknewurl(newurl)
      end
    end
  end

  return urls
end

wget.callbacks.write_to_warc = function(url, http_stat)
  status_code = http_stat["statcode"]
  set_item(url["url"])
  url_count = url_count + 1
  io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
  io.stdout:flush()
  logged_response = true
  if not item_name then
    error("No item name found.")
  end
  if status_code == 0
    or status_code == 429
    or status_code >= 500 then
    retry_url = true
    return false
  end
  if http_stat["len"] == 0
    and status_code == 200 then
    retry_url = true
    return false
  end
  for pattern, type_ in pairs(item_patterns) do
    if type_ ~= "asset"
      and item_type == type_
      and string.match(url["url"], pattern) then
      local body = nil
      local abort = status_code ~= 200
      if not abort
        and item_type == "account" then
        body = read_file(http_stat["local_file"])
        abort = string.match(body, "^%s*%[%s*%]%s*$")
      elseif not abort
        and item_type == "event" then
        body = read_file(http_stat["local_file"])
        abort = string.match(body, '"PlayerEventId"%s*:%s*([0-9]+)') ~= item_value
      end
      if abort then
        abort_item()
        return false
      end
    end
  end
  if abortgrab then
    print("Not writing to WARC.")
    return false
  end
  retry_url = false
  tries = 0
  return true
end

wget.callbacks.httploop_result = function(url, err, http_stat)
  status_code = http_stat["statcode"]

  if not logged_response then
    url_count = url_count + 1
    io.stdout:write(url_count .. "=" .. status_code .. " " .. url["url"] .. " \n")
    io.stdout:flush()
  end
  logged_response = false

  if killgrab then
    return wget.actions.ABORT
  end

  set_item(url["url"])
  if not item_name then
    error("No item name found.")
  end

  if abortgrab then
    abort_item()
    return wget.actions.EXIT
  end

  if status_code == 0 or retry_url then
    io.stdout:write("Server returned bad response. ")
    io.stdout:flush()
    tries = tries + 1
    local maxtries = 6
    if status_code == 401 or status_code == 403 or status_code == 404 then
      tries = maxtries + 1
    end
    if tries > maxtries then
      io.stdout:write(" Skipping.\n")
      io.stdout:flush()
      tries = 0
      abort_item()
      return wget.actions.EXIT
    end
    local sleep_time = math.random(
      math.floor(math.pow(2, tries-0.5)),
      math.floor(math.pow(2, tries))
    )
    io.stdout:write("Sleeping " .. sleep_time .. " seconds.\n")
    io.stdout:flush()
    os.execute("sleep " .. sleep_time)
    return wget.actions.CONTINUE
  else
    if status_code == 200 or status_code == 206 then
      if not seen_200[url["url"]] then
        seen_200[url["url"]] = 0
      end
      seen_200[url["url"]] = seen_200[url["url"]] + 1
    end
    downloaded[url["url"]] = true
  end

  if status_code >= 300 and status_code <= 399 then
    local newloc = urlparse.absolute(url["url"], http_stat["newloc"])
    if processed(newloc) or not allowed(newloc, url["url"]) then
      tries = 0
      return wget.actions.EXIT
    end
  end

  tries = 0

  return wget.actions.NOTHING
end

wget.callbacks.finish = function(start_time, end_time, wall_time, numurls, total_downloaded_bytes, total_download_time)
  local function submit_backfeed(items, key)
    local tries = 0
    local maxtries = 5
    while tries < maxtries do
      if killgrab then
        return false
      end
      local body, code, headers, status = http.request(
        "https://legacy-api.arpa.li/backfeed/legacy/" .. key,
        items .. "\0"
      )
      if code == 200 and body ~= nil and cjson.decode(body)["status_code"] == 200 then
        io.stdout:write(string.match(body, "^(.-)%s*$") .. "\n")
        io.stdout:flush()
        return nil
      end
      io.stdout:write("Failed to submit discovered URLs." .. tostring(code) .. tostring(body) .. "\n")
      io.stdout:flush()
      os.execute("sleep " .. math.floor(math.pow(2, tries)))
      tries = tries + 1
    end
    kill_grab()
    error()
  end

  local file = io.open(item_dir .. "/" .. warc_file_base .. "_bad-items.txt", "w")
  for url, _ in pairs(bad_items) do
    file:write(url .. "\n")
  end
  file:close()
  for key, data in pairs({
    ["recroom-i2eu4su96agjup9f"] = discovered_items,
    ["urls-fymabmvpvd5a71cu"] = discovered_outlinks
  }) do
    print("queuing for", string.match(key, "^(.+)%-"))
    local items = nil
    local count = 0
    for item, _ in pairs(data) do
      print("found item", item)
      if items == nil then
        items = item
      else
        items = items .. "\0" .. item
      end
      count = count + 1
      if count == 1000 then
        submit_backfeed(items, key)
        items = nil
        count = 0
      end
    end
    if items ~= nil then
      submit_backfeed(items, key)
    end
  end
end

wget.callbacks.before_exit = function(exit_status, exit_status_string)
  if killgrab then
    return wget.exits.IO_FAIL
  end
  if abortgrab then
    abort_item()
  end
  return exit_status
end
