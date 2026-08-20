# hextags (fork)

Chat and scoreboard tag manager for CS:GO. This is my fork of **HexTags** by Hexer10, fixed
for problems that showed up running it on a busy hide and seek server.

Upstream is 1,451 lines and this is 1,471, so it looks similar in size, but about 660 lines
changed inside it.

## Install

Drop the `addons` folder into your `csgo` folder:

```
addons/sourcemod/plugins/hextags.smx        the compiled plugin
addons/sourcemod/scripting/hextags.sp       source
addons/sourcemod/configs/hextags.cfg        your tag config, required
```

## What it does

Gives players tags in chat and on the scoreboard, based on their admin flags, SteamID, or
whatever selectors you put in `hextags.cfg`. Players can pick between tags they have access
to, and the choice is saved to their cookies.

## What I fixed

Almost all of the work was one symptom with three different causes: **tags silently not
sticking**.

**Tags reset after reconnects and map changes.** Cookie loading and admin authorization arrive
independently of each other, and the old code loaded tags before both were ready. That
overwrote the player's saved selection with the first matching config entry, so it looked like
their choice just kept getting forgotten.

**Duplicate selector names broke the saved choice.** The old build stored a KeyValues section
symbol in the cookie, which is not stable when a config has several sections with the same
name, which is normal (multiple `z` blocks, for instance). It now stores the tag *name*, which
is unique, and reads the old cookie once to migrate people across.

**External prefixes were being thrown away.** `OnClientPostAdminCheck` fires *before*
`OnClientPutInServer`. A plugin that pushes a prefix from post-admin-check can legitimately
have set one already, and the old code cleared it there, which left the player on their own
Steam clan tag for the rest of the session. The slot is now cleared on disconnect instead,
which is when the previous occupant actually leaves.

**Timer handling.** Closing a plugin-owned timer during unload races SourceMod's own cleanup
and throws "Handle is invalid". And a timer created without `TIMER_FLAG_NO_MAPCHANGE` gets
freed at map end without clearing the handle, so the next `OnConfigsExecuted` tries to delete
a stale one.

## What I added

A **`HexTags_SetClientPrefix` native**, so another plugin can push a prefix without fighting
over the clan tag. HexTags owns that tag and re-asserts it on a timer, so two writers would
just overwrite each other forever.

It takes a tag type, so a plugin can set the chat prefix and the scoreboard prefix separately:

```sourcepawn
HexTags_SetClientPrefix(client, ChatTag,  "{default}#3 [1420 ELO] ");
HexTags_SetClientPrefix(client, ScoreTag, "#3 [1420 ELO] ");
```

The prefix is stored *beside* the config tag rather than merged into it, which means a config
reload or a player reselecting their own tag keeps the prefix, and re-applying can never
double it up.

### What this is actually for

My **hnsmix** plugin uses it to show every player's Elo rank in chat and on the scoreboard, so
you can see who you are up against before a match starts. hnsmix formats the tag and pushes
it, HexTags owns where it goes.

The two sides are deliberately optional in both directions. hnsmix marks the native optional
and feature-checks before calling, so it runs fine on a server with no HexTags, the rank tag
just does not appear. And HexTags does not know or care what hnsmix is.

Two details that make it hold together:

* **`HasManagedScoreTag` checks both halves.** HexTags is responsible for a client's clan tag
  if the config forced a ScoreTag **or** another plugin pushed an external prefix. Without the
  second half, a player sitting on the empty "None" tag gets skipped by the force timer, so an
  external prefix is set once and then quietly lost to the next thing that writes a clan tag.
* **hnsmix re-pushes on library load.** If HexTags loads or reloads after hnsmix, hnsmix
  catches it in `OnLibraryAdded` and re-pushes every rank tag, so a mid-map plugin reload does
  not leave everybody blank.

There is also a proper "None" tag now, so a player can explicitly choose to have no tag and a
`Force=1` selector cannot silently re-grant one on the next map.

## Credits

Original **HexTags** by **Mattia (Hexah / Hexer10)**:
[github.com/Hexer10/HexTags](https://github.com/Hexer10/HexTags)

The original copyright notice is kept in the source, as GPL requires.

## License

GPL-3.0, same as upstream. See `LICENSE`.
