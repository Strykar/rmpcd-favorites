-- rmpcd-favorites: favorite songs via MPD stickers and keep playlists in sync.
--
-- Favoriting sets a "favorite" sticker on the song and records the URI in a
-- plain text index. From that index the plugin regenerates stored playlists
-- directly in MPD's playlist_directory (stored playlists are just m3u files,
-- so they appear in every client immediately):
--   * static: every favorite, in the order they were added
--   * top:    favorites ranked by the playCount sticker (#builtin.playcount)
--   * fresh:  the most recently favorited songs
--
-- Control it over MPD's client-to-client channel "rmpcd.favorites":
--   mpc sendmessage rmpcd.favorites toggle    -- favorite/unfavorite current song
--   mpc sendmessage rmpcd.favorites fav
--   mpc sendmessage rmpcd.favorites unfav
--   mpc sendmessage rmpcd.favorites generate  -- rewrite all playlists

---@class FavoritesPluginArgs
---@field playlist_dir string|nil MPD playlist_directory. Default: $HOME/.config/mpd/playlists
---@field static_playlist string|nil Playlist with all favorites. Default: "Favorites"
---@field top_playlist string|nil Most-played favorites. Default: "Favorites-Top"
---@field top_limit number|nil Size of the top playlist. Default: 25
---@field fresh_playlist string|nil Recently favorited. Default: "Favorites-Fresh"
---@field fresh_limit number|nil Size of the fresh playlist. Default: 25
---@field playcount_sticker string|nil Sticker to rank the top playlist by. Default: "playCount"
---@field notify boolean|nil Desktop notification on favorite/unfavorite. Default: true when notify-send exists

---@class FavoritesPlugin : RmpcdPlugin<FavoritesPluginArgs>

---@type FavoritesPlugin
local M = {
	playlist_dir = os.getenv("HOME") .. "/.config/mpd/playlists",
	static_playlist = "Favorites",
	top_playlist = "Favorites-Top",
	top_limit = 25,
	fresh_playlist = "Favorites-Fresh",
	fresh_limit = 25,
	playcount_sticker = "playCount",
	notify = nil,

	subscribed_channels = { "rmpcd.favorites" },

	_index_path = os.getenv("HOME") .. "/.local/state/rmpcd-favorites/index.tsv",
	-- array of { ts = <epoch>, uri = <song uri> }, favoriting order
	_index = {},
}

---@param self FavoritesPlugin
local function load_index(self)
	self._index = {}
	local content, err = fs.read_str(self._index_path)
	if content == nil or err ~= nil then
		return
	end
	for line in content:gmatch("[^\n]+") do
		local ts, uri = line:match("^(%d+)\t(.+)$")
		if ts ~= nil and uri ~= nil then
			table.insert(self._index, { ts = tonumber(ts), uri = uri })
		end
	end
end

---@param self FavoritesPlugin
local function save_index(self)
	local lines = {}
	for _, e in ipairs(self._index) do
		table.insert(lines, e.ts .. "\t" .. e.uri)
	end
	local ok, err = fs.write_str(self._index_path, table.concat(lines, "\n") .. "\n")
	if not ok then
		log.error("favorites: failed to write index: " .. tostring(err))
	end
end

---@param self FavoritesPlugin
---@param uri string
---@return number|nil position in the index
local function index_of(self, uri)
	for i, e in ipairs(self._index) do
		if e.uri == uri then
			return i
		end
	end
	return nil
end

---@param self FavoritesPlugin
---@param name string playlist name without extension
---@param uris string[]
local function write_playlist(self, name, uris)
	local path = self.playlist_dir .. "/" .. name .. ".m3u"
	local ok, err = fs.write_str(path, table.concat(uris, "\n") .. "\n")
	if not ok then
		log.error("favorites: failed to write playlist " .. path .. ": " .. tostring(err))
	end
end

---@param self FavoritesPlugin
local function regenerate(self)
	if #self._index == 0 then
		-- Nothing favorited: never create playlists, but empty out ones we
		-- created earlier so removing the last favorite is reflected.
		for _, name in ipairs({ self.static_playlist, self.top_playlist, self.fresh_playlist }) do
			local path = self.playlist_dir .. "/" .. name .. ".m3u"
			if fs.exists(path) then
				fs.write_str(path, "")
			end
		end
		return
	end

	-- static: favoriting order
	local static = {}
	for _, e in ipairs(self._index) do
		table.insert(static, e.uri)
	end
	write_playlist(self, self.static_playlist, static)

	-- top: by play count, most recently favorited breaking ties
	local ranked = {}
	for _, e in ipairs(self._index) do
		local count = tonumber(mpd.get_song_sticker(e.uri, self.playcount_sticker) or "0") or 0
		table.insert(ranked, { uri = e.uri, ts = e.ts, count = count })
	end
	table.sort(ranked, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.ts > b.ts
	end)
	local top = {}
	for i = 1, math.min(self.top_limit, #ranked) do
		table.insert(top, ranked[i].uri)
	end
	write_playlist(self, self.top_playlist, top)

	-- fresh: most recently favorited first
	local by_ts = {}
	for _, e in ipairs(self._index) do
		table.insert(by_ts, e)
	end
	table.sort(by_ts, function(a, b)
		return a.ts > b.ts
	end)
	local fresh = {}
	for i = 1, math.min(self.fresh_limit, #by_ts) do
		table.insert(fresh, by_ts[i].uri)
	end
	write_playlist(self, self.fresh_playlist, fresh)

	log.info("favorites: playlists regenerated (" .. #self._index .. " favorites)")
end

---@param self FavoritesPlugin
---@param summary string
local function notify_user(self, summary)
	if self.notify then
		process.spawn({ "notify-send", "-a", "rmpcd", summary })
	end
end

---@param song QueuedSong
---@return string
local function song_label(song)
	local artist = (song.artist and song.artist:first()) or nil
	local title = (song.title and song.title:first()) or song.file
	if artist ~= nil then
		return artist .. " - " .. title
	end
	return title
end

---@param self FavoritesPlugin
local function fav_current(self)
	local song = mpd.get_current_song()
	if song == nil then
		log.warn("favorites: no current song to favorite")
		return
	end
	if index_of(self, song.file) ~= nil then
		log.info("favorites: already a favorite: " .. song.file)
		return
	end
	mpd.set_song_sticker(song.file, "favorite", "1")
	table.insert(self._index, { ts = os.time(), uri = song.file })
	save_index(self)
	regenerate(self)
	log.info("favorites: added " .. song.file)
	notify_user(self, "\u{2665} " .. song_label(song))
end

---@param self FavoritesPlugin
local function unfav_current(self)
	local song = mpd.get_current_song()
	if song == nil then
		log.warn("favorites: no current song to unfavorite")
		return
	end
	local i = index_of(self, song.file)
	if i == nil then
		log.info("favorites: not a favorite: " .. song.file)
		return
	end
	mpd.set_song_sticker(song.file, "favorite", "0")
	table.remove(self._index, i)
	save_index(self)
	regenerate(self)
	log.info("favorites: removed " .. song.file)
	notify_user(self, "\u{2661} " .. song_label(song))
end

---@param self FavoritesPlugin
---@param _channel string
---@param message string
M.message = function(self, _channel, message)
	local cmd = message:match("^%s*(%S+)")
	if cmd == "toggle" then
		local song = mpd.get_current_song()
		if song ~= nil and index_of(self, song.file) ~= nil then
			unfav_current(self)
		else
			fav_current(self)
		end
	elseif cmd == "fav" then
		fav_current(self)
	elseif cmd == "unfav" then
		unfav_current(self)
	elseif cmd == "generate" then
		regenerate(self)
	else
		log.warn("favorites: unknown command: " .. tostring(message))
	end
end

---@param self FavoritesPlugin
---@param args FavoritesPluginArgs
M.setup = function(self, args)
	args = args or {}
	if args.playlist_dir ~= nil then
		self.playlist_dir = args.playlist_dir
	end
	if args.static_playlist ~= nil then
		self.static_playlist = args.static_playlist
	end
	if args.top_playlist ~= nil then
		self.top_playlist = args.top_playlist
	end
	if args.top_limit ~= nil then
		self.top_limit = args.top_limit
	end
	if args.fresh_playlist ~= nil then
		self.fresh_playlist = args.fresh_playlist
	end
	if args.fresh_limit ~= nil then
		self.fresh_limit = args.fresh_limit
	end
	if args.playcount_sticker ~= nil then
		self.playcount_sticker = args.playcount_sticker
	end
	if args.notify ~= nil then
		self.notify = args.notify
	else
		self.notify = util.which("notify-send") ~= nil
	end

	fs.create_dir_all(self._index_path:match("^(.+)/[^/]+$"))
	load_index(self)
	regenerate(self)
	log.info("favorites: ready (" .. #self._index .. " favorites, playlists in " .. self.playlist_dir .. ")")
end

return M
