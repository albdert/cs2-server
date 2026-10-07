# CS2 KZ Server (Docker)

Counter-Strike 2 dedicated server running the [cs2kz](https://github.com/KZGlobalTeam/cs2kz-metamod) plugin, based on the [joedwards32/cs2](https://github.com/joedwards32/CS2) image.

## Directory Layout

```
cs2/
├── docker-compose.yml
├── .env                 # server settings and secrets (do not commit)
├── workshop.sh          # loads the workshop collection after boot
└── cs2-data/            # game files, mounted at /home/steam/cs2-dedicated
    └── game/
        ├── bin/linuxsteamrt64/        # libssl.so.1.1 + libcrypto.so.1.1 go here
        └── csgo/
            ├── gameinfo.gi            # needs the Metamod search path line
            ├── addons/                # Metamod + plugins
            └── cfg/                   # server and plugin configs
```

## Requirements

- Linux host with Docker and Docker Compose v2
- 2+ CPU cores (single-thread performance matters most), 4 GB RAM, 60 GB disk
- A Game Server Login Token (GSLT). Without one the server logs in anonymously, which restricts connections to LAN only and prevents workshop downloads.
- `rcon-cli` on the host for `workshop.sh` (see [RCON](#rcon))

## docker-compose.yml

```yaml
services:
  cs2:
    image: joedwards32/cs2
    container_name: cs2
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./cs2-data:/home/steam/cs2-dedicated
    ports:
      - "27015:27015/tcp"
      - "27015:27015/udp"
      - "27020:27020/udp"   # SourceTV
    stdin_open: true
    tty: true
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"
```

The `logging` block is required. The server can spam `Unknown read error 21` in a tight loop, and without a cap the log grows to many GB.

## .env Variables

```
SRCDS_TOKEN=
CS2_SERVERNAME=homelab kz
CS2_RCONPW=changeme
CS2_PW=changeme
CS2_MAXPLAYERS=10
CS2_GAMEALIAS=deathmatch
CS2_STARTMAP=de_dust2
#CS2_HOST_WORKSHOP_MAP=
#CS2_HOST_WORKSHOP_COLLECTION=
```

| Variable | Description |
|---|---|
| `SRCDS_TOKEN` | GSLT from https://steamcommunity.com/dev/managegameservers (App ID 730). Required for non-LAN connections and workshop downloads. Regenerate it if it appears in shared logs. |
| `CS2_SERVERNAME` | Server name shown in the browser and scoreboard. |
| `CS2_RCONPW` | RCON password. Use a strong one; RCON is reachable wherever port 27015/tcp is. |
| `CS2_PW` | Join password. Clients connect with `password <value>`. Empty means no password. |
| `CS2_MAXPLAYERS` | Player slots. |
| `CS2_GAMEALIAS` | Base game mode (`casual`, `deathmatch`, `competitive`, ...). cs2kz overrides movement and round settings regardless. |
| `CS2_STARTMAP` | Map loaded on boot. Must be a stock map; see the workshop note below. |
| `CS2_PORT` | Listen port, default 27015. If changed, update the compose port mappings. |
| `CS2_ADDITIONAL_ARGS` | Extra launch arguments appended to the server command line. |
| `CS2_HOST_WORKSHOP_MAP` | Leave unset. See below. |
| `CS2_HOST_WORKSHOP_COLLECTION` | Leave unset. See below. |
| `DEBUG` | Image debug output: 0 none, 1 steamcmd, 2 cs2, 3 all. |

**Workshop variables:** when either workshop variable is set, the image launches with no start map. The workshop download is then attempted before the Steam logon finishes, it fails, and the server sits mapless (clients time out, the log fills with read errors). Instead, boot on `CS2_STARTMAP=de_dust2` and load the collection with `workshop.sh` once the server is logged on.

`.env` changes apply on `docker compose up -d`. `docker compose restart` does not reload them.

## Initial Setup

### 1. Prepare the Data Directory

The container runs as UID 1000.

```
mkdir cs2-data
sudo chown 1000:1000 cs2-data
docker compose up -d
docker logs -f cs2
```

The first start downloads about 35 GB. Wait until the server finishes starting, then stop it to install plugins:

```
docker compose stop cs2
```

### 2. Install Metamod:Source 2.0

Download the latest Linux build (penguin icon) from https://www.sourcemm.net/downloads.php?branch=master. Skip builds with a faded penguin; their Linux build is unavailable. cs2kz requires build 1459 or later.

```
tar -xzf mmsource-2.0.0-git*-linux.tar.gz -C cs2-data/game/csgo/
```

### 3. Edit gameinfo.gi

Add `Game csgo/addons/metamod` directly below the `Game_LowViolence` line in `cs2-data/game/csgo/gameinfo.gi`. To do it with a command:

```
grep -q "csgo/addons/metamod" cs2-data/game/csgo/gameinfo.gi || \
sed -i '/Game_LowViolence/a\\t\t\tGame\tcsgo/addons/metamod' cs2-data/game/csgo/gameinfo.gi
```

CS2 updates overwrite this file. Re-run the command after every update.

### 4. Install the Plugins

Install in this order, extracting each into `cs2-data/game/csgo/`.

| Plugin | Source | Asset |
|---|---|---|
| MultiAddonManager v1.6+ | https://github.com/Source2ZE/MultiAddonManager/releases | `*-steamrt3.tar.gz` |
| SQL_MM v1.3.4.3+ | https://github.com/zer0k-z/sql_mm/releases | `sql_mm-linux-*.tar.gz` |
| cs2kz | https://github.com/KZGlobalTeam/cs2kz-metamod/releases | `cs2kz-linux-master.tar.gz` |

- **MultiAddonManager** handles KZ sounds, the HUD, and radio menus.
- **SQL_MM** provides the local database for times and PBs.
- **cs2kz** is the KZ plugin itself.

```
tar -xzf <archive>.tar.gz -C cs2-data/game/csgo/
```

Notes:

- **Runtime build:** Use the `steamrt3` builds; `steamrt4` builds can fail with GLIBC errors in this container.
- **cs2kz package:** The `-upgrade` package is for updating an existing install; use the full package for the first install.
- **Download links:** Copy asset links from the release page (they contain `/releases/download/`) and download with `curl -LO` or `wget`. If `tar` reports "does not look like a tar archive", the download saved an HTML page.

### 5. Add OpenSSL 1.1

cs2kz and SQL_MM link against `libssl.so.1.1`, which the container's OS does not ship. Without it they fail to load.

```
wget http://deb.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb
dpkg-deb -x libssl1.1_*.deb libssl
cp libssl/usr/lib/x86_64-linux-gnu/libssl.so.1.1 \
   libssl/usr/lib/x86_64-linux-gnu/libcrypto.so.1.1 \
   cs2-data/game/bin/linuxsteamrt64/
```

If the `.deb` returns 404, check http://deb.debian.org/debian/pool/main/o/openssl/ for the current `libssl1.1_*_amd64.deb`. Without `dpkg-deb`, extract with `ar x <deb> && tar -xf data.tar.xz -C libssl`.

These files survive normal updates but may be removed by a `validate` or a reinstall.

### 6. Fix Ownership and Start

```
sudo chown -R 1000:1000 cs2-data
docker compose up -d
```

### 7. Verify

In the server console (see [Connecting](#connecting)):

```
meta list
```

MultiAddonManager, SQL_MM, and cs2kz should all show as loaded. The log should contain `Logging into Steam gameserver account with logon token` instead of the anonymous-account banner.

## Workshop Maps (workshop.sh)

The script waits for the server to finish the Steam logon, then loads the collection over RCON.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

COLLECTION=3179428851
RCONPW=$(grep -E '^CS2_RCONPW=' .env | cut -d= -f2-)
started=$(docker inspect -f '{{.State.StartedAt}}' cs2)

for _ in $(seq 1 60); do
  if docker logs --since "$started" cs2 2>&1 | grep -q "GameServerSteamAPIActivated"; then
    sleep 5
    rcon -a 127.0.0.1:27015 -p "$RCONPW" "host_workshop_collection $COLLECTION"
    exit 0
  fi
  sleep 5
done

echo "timed out waiting for Steam logon" >&2
exit 1
```

```
chmod +x workshop.sh
docker compose up -d && ./workshop.sh
```

To run it on host boot, add this to the crontab (`crontab -e`) of a user in the `docker` group:

```
@reboot sleep 30 && /path/to/workshop.sh >> /path/to/workshop.log 2>&1
```

If Docker restarts a crashed container, the server comes back on dust2. Run `./workshop.sh` again.

## Connecting

### Joining the Game

In the CS2 console (enable the developer console in settings, open it with `~`):

```
connect <server-ip>:27015; password <CS2_PW>
```

On the same LAN, use the host's LAN IP. From outside, forward 27015 tcp/udp (and 27020 udp for SourceTV) on the router and use the public IP.

### Server Console

```
docker attach cs2
```

Type commands directly, without the `rcon` prefix. Detach with `Ctrl+P, Ctrl+Q`; `Ctrl+C` stops the server. This is the most reliable way to run commands.

### RCON From the Game Client

```
rcon_password <CS2_RCONPW>
rcon status
rcon <command>
```

When not connected to the server, set the target first with `rcon_address <server-ip>:27015`. Client RCON is unreliable in CS2. If `rcon status` returns nothing, use the server console or rcon-cli.

### RCON From the Command Line

Install [gorcon/rcon-cli](https://github.com/gorcon/rcon-cli):

```
curl -LO https://github.com/gorcon/rcon-cli/releases/download/v0.10.3/rcon-0.10.3-amd64_linux.tar.gz
tar -xzf rcon-*.tar.gz
sudo mv rcon-*/rcon /usr/local/bin/
```

Run a single command:

```
rcon -a <server-ip>:27015 -p <CS2_RCONPW> "status"
```

Or start an interactive session:

```
rcon -a <server-ip>:27015 -p <CS2_RCONPW>
```

## In-Game Commands

The commands below run in the server console, or with an `rcon ` prefix from the client.

### Maps

| Command | Effect |
|---|---|
| `changelevel de_mirage` | Switch to a stock map |
| `host_workshop_map <id>` | Download and load a single workshop map |
| `host_workshop_collection <id>` | Download a collection and load a map from it |
| `ds_workshop_listmaps` | List maps in the loaded collection |
| `ds_workshop_changelevel <name>` | Switch to a map from the loaded collection |
| `maps *` | List installed maps |

The workshop commands only work after the Steam logon has completed.

### Server Settings

| Command | Effect |
|---|---|
| `status` | Players, map, IP, and version |
| `hostname "name"` | Change the server name |
| `sv_password "pw"` | Change the join password (empty to remove) |
| `game_alias casual` | Change the game mode; applies on the next map change |
| `mp_restartgame 1` | Restart the round or match |
| `mp_warmup_end` | End warmup |
| `bot_kick` | Remove all bots |
| `kick <name>` | Kick a player |
| `kickid <userid>` | Kick a player by the user ID from `status` |
| `say <text>` | Message all players |
| `exec <file>.cfg` | Run a config from `game/csgo/cfg/` |

Settings changed in the console reset on restart. Put permanent settings in `cs2-data/game/csgo/cfg/server.cfg`.

### Plugins

| Command | Effect |
|---|---|
| `meta list` | Loaded Metamod plugins and their status |
| `meta version` | Metamod version |
| `mm_print_searchpaths` | Search paths mounted by MultiAddonManager |

### cs2kz Chat Commands

Players type these in chat. Run `!help` for the full list. Common ones (names may differ between versions):

| Command | Effect |
|---|---|
| `!r` | Restart the run |
| `!cp` | Save a checkpoint |
| `!tp` | Teleport to the last checkpoint |
| `!mode` | Change the movement mode |
| `!map <name>` | Change map |
| `!spec` | Go to spectator |

## Updating

### CS2

The image runs a SteamCMD update on every container start, including `docker compose start`, so updates cannot be skipped by stopping and starting. After a CS2 update:

1. Re-apply the gameinfo.gi line.
2. Check `meta list`. Major Valve updates often break cs2kz until it releases a new build; Metamod usually survives minor patches.
3. Watch the cs2kz GitHub releases for fixes.

Clients on a newer CS2 version cannot join an outdated server, so updates cannot be postponed for long.

### Plugins

```
docker compose stop cs2
tar -xzf <new-archive>.tar.gz -C cs2-data/game/csgo/
sudo chown -R 1000:1000 cs2-data/game/csgo/addons
docker compose start cs2
```

- **cs2kz upgrades:** Use `cs2kz-linux-master-upgrade.tar.gz` for updates, so your configs are not overwritten.
- **Back up configs:** For other plugins, back up any edited configs in `addons/` and `cfg/` first, since extracting can overwrite them.
- **Stale files:** Extracting does not remove obsolete files. If something behaves oddly, delete the plugin's folder and reinstall cleanly.
- **Isolating a broken plugin:** To disable a plugin temporarily, move its `.vdf` out of `addons/metamod/`.

## Logs

The read-error spam makes unfiltered logs slow and useless. Always limit and filter:

```
docker logs --since 10m cs2 2>&1 | grep -v "Unknown read error" | tail -80
```

| Purpose | Filter |
|---|---|
| Plugin errors | `grep -iE "META|cs2kz|sql_mm|failed|GLIBC"` |
| Steam logon | `grep -iE "token|anonymous|logged|GameServerSteamAPIActivated"` |
| Map loading | `grep -iE "Loading map|workshop|Spawn Server"` |

To check container state and restarts (an uptime much lower than the creation time means a crash loop):

```
docker ps --filter name=cs2
```

To confirm the tty and stdin settings are active:

```
docker inspect cs2 --format 'tty={{.Config.Tty}} stdin={{.Config.OpenStdin}}'
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `connect` times out | No map loaded (`Loading map "<empty>"`) | Set `CS2_STARTMAP`, unset the workshop variables |
| `connect` times out from another network | Anonymous logon restricts the server to LAN | Set `SRCDS_TOKEN` |
| `libssl.so.1.1: cannot open shared object file` | OpenSSL 1.1 missing | [Setup step 5](#5-add-openssl-11) |
| `meta list` errors or shows nothing | gameinfo.gi was reset by an update | Re-apply the Metamod line |
| `GLIBC_x.xx not found` | Wrong runtime build | Use the `steamrt3` build |
| MultiAddonManager: "server is not logged on Steam" | No GSLT, or the download was attempted before logon | Set `SRCDS_TOKEN`; it retries after logon |
| Workshop map or collection does nothing at boot | Ran before the Steam logon | Use `workshop.sh` |
| Cannot choose a team | cs2kz not loaded, or the map lacks spawns for that team | Check `meta list`; try `jointeam 3` or `!spec` |
| `Unknown read error 21` spam | Image console input handling | Harmless; keep the log size cap |
| `docker logs` hangs | Huge log from the spam | Use `--since` or `--tail`; add the `logging` block |
| Container uptime resets repeatedly | Crash loop | Check the log end; disable plugins one at a time |
| Container ignores `.env` changes | Used `restart` instead of recreating | `docker compose up -d` |
| Permission denied in logs | Files not owned by UID 1000 | `sudo chown -R 1000:1000 cs2-data` |
