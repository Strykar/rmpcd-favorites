# rmpcd-favorites

Favorite songs from any MPD client and keep stored playlists in sync,
powered by [rmpcd](https://rmpc.mierak.dev/rmpcd/).

Favoriting sets a `favorite` sticker on the song and records it in a small
index. From that index the plugin regenerates up to three stored playlists
directly in MPD's `playlist_directory`, so they show up in rmpc, myMPD, ncmpcpp
or anything else that lists stored playlists:

- **rmpcd-favorites** — every favorite, in the order you added them
- **rmpcd-favorites-top** — favorites ranked by play count (pairs with
  `#builtin.playcount`)
- **rmpcd-favorites-fresh** — your most recently added favorites

The names are prefixed so they can never clobber a playlist you already
have; rename them via `setup()` if you prefer something shorter.

## Install

In `~/.config/rmpcd/init.lua`:

```lua
rmpcd.install({ url = "https://github.com/Strykar/rmpcd-favorites.git" }):setup({
    -- everything below is optional, defaults shown
    playlist_dir = os.getenv("HOME") .. "/.config/mpd/playlists",
    static_playlist = "rmpcd-favorites",
    top_playlist = "rmpcd-favorites-top",
    top_limit = 25,
    fresh_playlist = "rmpcd-favorites-fresh",
    fresh_limit = 25,
    playcount_sticker = "playCount",
    notify = true, -- desktop notification on favorite/unfavorite
})
```

`playlist_dir` must be the same directory as `playlist_directory` in your
`mpd.conf`. For play-count ranking also enable the builtin tracker:

```lua
rmpcd.install("#builtin.playcount")
```

MPD needs `sticker_file` configured, since favorites and play counts are
stickers.

## Use

The plugin listens on the MPD client-to-client channel `rmpcd.favorites`:

```sh
mpc sendmessage rmpcd.favorites toggle    # favorite/unfavorite the current song
mpc sendmessage rmpcd.favorites fav
mpc sendmessage rmpcd.favorites unfav
mpc sendmessage rmpcd.favorites generate  # rewrite all playlists
```

Bind it in rmpc (`config.ron`, merges with default keybinds):

```ron
keybinds: (
    global: {
        "F": ExternalCommand(
            command: ["mpc", "sendmessage", "rmpcd.favorites", "toggle"],
            description: "Favorite/unfavorite the current song",
        ),
    },
),
```

Any MPD client that can send channel messages works the same way.

## Notes

- The sticker is the source of truth (`favorite=1`, unfavoriting sets `0`);
  the index at `~/.local/state/rmpcd-favorites/index.tsv` mirrors it and
  carries the favoriting timestamps used for ordering.
- Playlists are only written once you have at least one favorite.
- The rmpcd Lua API has no sticker search yet, so favorites marked outside
  this plugin (e.g. `mpc sticker ... set favorite 1`) are not picked up
  automatically.
- Favorites that have no `playCount` sticker yet rank last in the top
  playlist, and rmpcd currently logs each missing-sticker lookup as an
  error during regeneration; harmless, quiets down once `#builtin.playcount`
  has seen the songs.
