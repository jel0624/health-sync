#!/bin/bash
# Omnitrack installer for macOS (DESIGN.md section 11.3).
#
# The download page's one-liner and the .pkg's postinstall both run this script. It installs for the current user
# (no administrator password), keeps the app and your data in separate folders, and can be run again at any time:
# a second run repairs or updates the app and never touches your data.
#
#   curl -fsSL https://jel0624.github.io/health-sync/install.sh | bash
#   bash install.sh --zip omnitrack-0.2.0.zip
#   bash install.sh --root /tmp/ot --port 5799 --service-prefix OmniTest --no-browser     (test sandbox)
#   bash install.sh --dry-run                                                            (print the plan)
#
# Steps: preflight -> release zip (download + SHA256) -> unpack to src.new -> uv -> Python 3.12 -> stop the running
# app -> swap src -> uv sync -> shim + init -> services (LaunchAgents) -> launcher app -> setup page -> state.json.
# Health Sync 0.1 (the earlier name, DESIGN.md 11.6) is moved over: <X>/HealthSync/{app,data} -> <X>/Omnitrack/...
# (its updater passes the old folders and "Health Sync" as the prefix; --legacy-app / --legacy-data name others).
# The new app is installed first; then the old one is stopped, its LaunchAgents and launcher app removed, the data
# folder moved (a rename), the Keychain entries moved (read with the old app's own Python, so macOS asks nothing)
# and the old app folder deleted. When the new version does not install or start, whatever of that was done is
# undone (its LaunchAgents back, the data folder moved back) and the old app folder is kept. When both data folders
# exist the new one is used and the old one left as it is; with no Health Sync app as well, that is a normal
# install or update, not a move. Every run also points the settings back into the data folder when an earlier move
# stopped before it could (they still name the HealthSync folder, which no longer holds data).
# Port: without --port the data folder's own port is kept (default 5710); when another program uses it, the next
# free one of 5710-5730 is taken and saved. An explicit --port is used as given (the installer stops if it is busy).
# At the end it writes <Data>/run/installer-result.json (exit code, version, error line) for the setup page.
# Exit codes: 0 ok, 1 preflight, 2 download/verify, 3 uv/python, 4 install failed (previous version restored),
#             5 services failed (the app itself is installed).
#
# Written for the bash 3.2 that ships with macOS: no associative arrays, no ${x,,}, no mapfile.
set -euo pipefail

NEW_NAME="Omnitrack"            # the app's name and folder name since 0.2.0
OLD_FOLDER="HealthSync"         # Health Sync 0.1's folder: ~/Library/Application Support/HealthSync/{app,data}
OLD_PREFIX="Health Sync"        # its service prefix and Keychain name

main() {
    local SUPPORT="$HOME/Library/Application Support/$NEW_NAME"
    local APP="" DATA="" ROOT="" ZIP="" ZIP_SHA="" UV_TAR="" LEGACY_APP="" LEGACY_DATA=""
    local VERSION_URL="https://jel0624.github.io/health-sync/version.json"
    local PORT=5710 PREFIX="$NEW_NAME" PORT_GIVEN=0 LAUNCHER_GIVEN=0
    local NO_SERVICES=0 NO_BROWSER=0 FROM_INSTALLER=0 UPDATE=0 DRY_RUN=0 NO_SHORTCUTS=0
    local LAUNCHER_DIR="$HOME/Applications"

    while [ $# -gt 0 ]; do
        local opt="$1" val=""
        case "$opt" in
            --*=*) val="${opt#*=}"; opt="${opt%%=*}" ;;
        esac
        case "$opt" in
            --app|--data|--root|--zip|--sha256|--uv-tar|--version-url|--port|--service-prefix|--launcher-dir|--legacy-app|--legacy-data)
                if [ -z "$val" ]; then
                    [ $# -ge 2 ] || usage "$opt needs a value"
                    val="$2"; shift
                fi ;;
        esac
        case "$opt" in
            --app) APP="$val" ;;
            --data) DATA="$val" ;;
            --root) ROOT="$val" ;;
            --zip) ZIP="$val" ;;
            --sha256) ZIP_SHA="$val" ;;
            --uv-tar) UV_TAR="$val" ;;
            --version-url) VERSION_URL="$val" ;;
            --port) PORT="$val"; PORT_GIVEN=1 ;;
            --service-prefix) PREFIX="$val" ;;
            --launcher-dir) LAUNCHER_DIR="$val"; LAUNCHER_GIVEN=1 ;;
            --legacy-app) LEGACY_APP="$val" ;;
            --legacy-data) LEGACY_DATA="$val" ;;
            --no-shortcuts) NO_SHORTCUTS=1 ;;
            --no-services) NO_SERVICES=1 ;;
            --no-browser) NO_BROWSER=1 ;;
            --from-installer) FROM_INSTALLER=1 ;;
            --update) UPDATE=1 ;;
            --dry-run) DRY_RUN=1 ;;
            -h|--help) sed -n '2,25p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) usage "unknown option: $opt" ;;
        esac
        shift
    done

    # ---- folders and options
    local base="$SUPPORT"
    [ -n "$ROOT" ] && base="$ROOT"
    [ -n "$APP" ] || APP="$base/app"
    [ -n "$DATA" ] || DATA="$base/data"
    APP=$(abspath "$APP"); DATA=$(abspath "$DATA")
    [ -n "$ZIP" ] && ZIP=$(abspath "$ZIP")
    [ -n "$UV_TAR" ] && UV_TAR=$(abspath "$UV_TAR")
    LAUNCHER_DIR=$(abspath "$LAUNCHER_DIR")
    [ "$PREFIX" = "$OLD_PREFIX" ] && PREFIX="$NEW_NAME"      # Health Sync 0.1's default name

    # Health Sync 0.1: its updater passes the old folders (they move to the Omnitrack names); otherwise the new
    # folders' HealthSync twins, or the ones given with --legacy-*, are taken over when they hold an install
    OLD_APP="" OLD_DATA=""
    local r
    r=$(renamed_path "$APP"); if [ "$r" != "$APP" ]; then OLD_APP="$APP"; APP="$r"; fi
    r=$(renamed_path "$DATA"); if [ "$r" != "$DATA" ]; then OLD_DATA="$DATA"; DATA="$r"; fi
    if [ -n "$LEGACY_APP" ]; then OLD_APP=$(abspath "$LEGACY_APP"); elif [ -z "$OLD_APP" ]; then OLD_APP=$(old_path "$APP"); fi
    if [ -n "$LEGACY_DATA" ]; then OLD_DATA=$(abspath "$LEGACY_DATA"); elif [ -z "$OLD_DATA" ]; then OLD_DATA=$(old_path "$DATA"); fi
    if [ -n "$OLD_APP" ] && { [ "$OLD_APP" = "$APP" ] || ! is_app_folder "$OLD_APP"; }; then OLD_APP=""; fi
    if [ -n "$OLD_DATA" ] && { [ "$OLD_DATA" = "$DATA" ] || [ ! -f "$OLD_DATA/healthsync.json" ]; }; then OLD_DATA=""; fi
    MIG=0 MOVE_DATA=0 MIG_STOPPED=0 MIG_MOVED=0 MIG_NEW_AGENTS=0 MIG_UNDONE=0 OLD_SETTINGS_PREFIX=""
    OLD_VERSION="0.1"
    local stale_data="" both_data=""
    if [ -n "$OLD_DATA" ] && [ ! -f "$DATA/healthsync.json" ]; then MOVE_DATA=1; fi
    if [ -n "$OLD_DATA" ] && [ "$MOVE_DATA" = 0 ] && [ -z "$OLD_APP" ]; then
        # a HealthSync data folder next to this one and no Health Sync app: nothing to move over, a normal install
        stale_data="$OLD_DATA"; OLD_DATA=""
    fi
    OLD_DATA_WAS="$OLD_DATA"
    if [ -n "$OLD_APP" ] || [ "$MOVE_DATA" = 1 ]; then
        MIG=1
        if [ -n "$OLD_DATA" ]; then OLD_SETTINGS_PREFIX=$(json_get "$OLD_DATA/healthsync.json" service_prefix 2>/dev/null || true); fi
        if [ -n "$OLD_APP" ]; then
            local v
            v=$(src_version "$OLD_APP/src")
            [ -n "$v" ] && OLD_VERSION="$v"
        fi
    fi

    # never stand in the app folder (its src is replaced below)
    cd "${TMPDIR:-/tmp}" 2>/dev/null || cd /
    APP_FOR_RESULT="$APP"
    local custom_data=1
    [ "$DATA" = "$(abspath "$SUPPORT/data")" ] && custom_data=0
    local slug
    slug=$(printf '%s' "$PREFIX" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    local make_launcher=1
    [ "$NO_SHORTCUTS" = 1 ] && make_launcher=0
    if [ "$UPDATE" = 1 ] && [ "$make_launcher" = 1 ]; then
        # an update keeps the launcher; one that moves Health Sync 0.1 over makes it again under the new name,
        # where the old one was
        make_launcher=0
        local old_launcher=""
        [ -n "$OLD_APP" ] && old_launcher=$(json_get "$OLD_APP/state.json" launchers.0 2>/dev/null || true)
        case "$old_launcher" in
            *.app) make_launcher=1; [ "$LAUNCHER_GIVEN" = 1 ] || LAUNCHER_DIR=$(dirname "$old_launcher") ;;
        esac
    fi

    if [ "$DRY_RUN" = 0 ]; then
        # until the data folder has moved, the log and the result file live in the old one (they move along)
        local log_home="$DATA"
        [ "$MOVE_DATA" = 1 ] && log_home="$OLD_DATA"
        mkdir -p "$log_home/logs"
        chmod 700 "$log_home" 2>/dev/null || true
        RESULT="$log_home/run/installer-result.json"
        MODE=install
        [ "$UPDATE" = 1 ] && MODE=update
        LOG="$log_home/logs/install.log"
        if [ "$UPDATE" = 1 ]; then
            # "omnitrack update" already sends this script's output to update.log; only log it ourselves at a terminal
            if [ -t 1 ]; then LOG="$log_home/logs/update.log"; else LOG=""; fi
        fi
    fi
    say ""
    say "---- Omnitrack installer, $([ "$UPDATE" = 1 ] && echo update || echo install) ($(date '+%Y-%m-%d %H:%M:%S'))"
    say "app folder:  $APP"
    say "data folder: $DATA"
    if [ "$MIG" = 1 ]; then
        if [ "$MOVE_DATA" = 1 ]; then say "Health Sync $OLD_VERSION is moved over: app ${OLD_APP:--}, data $OLD_DATA"
        else say "Health Sync $OLD_VERSION is moved over: app ${OLD_APP:--}, data -"; fi
    fi
    both_data="$stale_data"
    if [ -n "$OLD_DATA" ] && [ "$MOVE_DATA" = 0 ]; then both_data="$OLD_DATA"; fi
    if [ -n "$both_data" ] && [ "$DRY_RUN" = 0 ]; then
        say "note: both $both_data and $DATA hold Omnitrack data; $DATA is used and $both_data is left as it is"
    fi

    # ---- 1. preflight
    step "Checking this Mac"
    printf '%s' "$PREFIX" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9 _-]{0,39}$' \
        || fail 1 "The service prefix may only use letters, digits, spaces, - and _ (got '$PREFIX')."
    case "$PORT" in ''|*[!0-9]*) fail 1 "The port must be a number." ;; esac
    if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then fail 1 "The port must be between 1024 and 65535."; fi
    case "$DATA/" in "$APP/"*) fail 1 "The data folder must not be inside the app folder (updates replace the app folder)." ;; esac
    if [ "$MOVE_DATA" = 1 ] && [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
        fail 1 "Your data is in $OLD_DATA, and $DATA already exists without Omnitrack's settings in it. Move or delete $DATA, then run the installer again."
    fi
    [ "$(id -u)" != 0 ] || fail 1 "Run this installer as your normal user, not with sudo (Omnitrack installs for one user)."
    local macos major arch
    macos=$(sw_vers -productVersion 2>/dev/null || echo 0)
    major=${macos%%.*}
    case "$major" in ''|*[!0-9]*) major=0 ;; esac
    [ "$major" -ge 13 ] || fail 1 "Omnitrack needs macOS 13 Ventura or newer (this is $macos)."
    arch=$(uname -m)
    # an Intel shell under Rosetta on an Apple Silicon Mac: install the native arm64 build
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then arch=arm64; fi
    local uv_key
    case "$arch" in
        arm64) uv_key="macos-arm64" ;;
        x86_64) uv_key="macos-x86_64" ;;
        *) fail 1 "Unsupported processor: $arch" ;;
    esac
    local parent="$APP"
    while [ ! -d "$parent" ]; do parent=$(dirname "$parent"); done
    local free_kb
    free_kb=$(df -Pk "$parent" | awk 'NR==2 {print $4}')
    [ "${free_kb:-0}" -ge 2097152 ] || fail 1 "Omnitrack needs at least 2 GB of free disk space."
    local src="$APP/src" src_new="$APP/src.new" src_old="$APP/src.old" downloads="$APP/downloads"
    local state="$APP/state.json" old_py="$APP/venv/bin/python" had_app=0
    [ -f "$src/run.py" ] && had_app=1
    HAD_APP="$had_app"

    # the port: this data folder's own server may hold it (it is restarted), or Health Sync 0.1's being moved over;
    # anything else holding it is never stopped: another program, or another data folder's or user's Omnitrack
    local my_home legacy_home="" server_was_up=0 new_was_up=0 wanted="$PORT" saved="" p pong chosen="" pong_h
    my_home=$(home_id_of "$old_py" "$src/run.py" "$DATA")
    if [ -n "$OLD_DATA" ]; then legacy_home=$(home_id_of "$OLD_APP/venv/bin/python" "$OLD_APP/src/run.py" "$OLD_DATA"); fi
    if [ "$PORT_GIVEN" = 0 ]; then
        local from="$DATA"
        [ -f "$DATA/healthsync.json" ] || from="$OLD_DATA"
        if [ -n "$from" ] && [ -f "$from/healthsync.json" ]; then
            saved=$(json_get "$from/healthsync.json" port 2>/dev/null || true)
            case "$saved" in ''|*[!0-9]*) ;; *) [ "$saved" -ge 1024 ] && [ "$saved" -le 65535 ] && wanted="$saved" ;; esac
        fi
    fi
    local cands="$wanted"
    [ "$PORT_GIVEN" = 0 ] && cands="$wanted $(seq 5710 5730 | grep -vx "$wanted" | tr '\n' ' ')"
    for p in $cands; do
        pong=$(ping_server "$p" 5)
        if [ -z "$pong" ]; then chosen="$p"; break; fi
        pong_h=$(pong_home "$pong")
        if [ -n "$pong_h" ] && { [ "$pong_h" = "$my_home" ] || [ "$pong_h" = "$legacy_home" ]; }; then
            # whose server: this install's own (restarted after a failed update) or Health Sync 0.1's (its agents
            # come back with undo_migration)
            chosen="$p"; server_was_up=1
            if [ "$pong_h" = "$my_home" ]; then new_was_up=1; fi
            break
        fi
        if [ "$p" = "$wanted" ]; then
            case "$pong" in
                *healthsync*) say "    note: port $p is used by another Omnitrack (another data folder or user)" ;;
                *) say "    note: port $p is used by another program" ;;
            esac
        fi
    done
    if [ -z "$chosen" ]; then
        [ "$PORT_GIVEN" = 1 ] && fail 1 "Port $PORT is used by another program. Close it, or install with a different port (--port $((PORT + 1)))."
        fail 1 "Ports 5710-5730 are all used by other programs. Close one of them and run the installer again."
    fi
    [ "$chosen" != "$wanted" ] && say "    Omnitrack will use port $chosen instead"
    PORT="$chosen"
    say "    macOS $macos ($arch), $((free_kb / 1048576)) GB free, port $PORT $([ $server_was_up = 1 ] && echo 'used by this install (will restart)' || echo free)"

    if [ "$DRY_RUN" = 1 ]; then
        say ""
        say "Plan (dry run, nothing is changed):"
        if [ -n "$ZIP" ]; then say "  release:        $ZIP"; else say "  release:        latest from $VERSION_URL"; fi
        if [ "$had_app" = 1 ]; then say "  existing app:   yes (update in place, data kept)"; else say "  existing app:   no (fresh install)"; fi
        if [ "$MIG" = 1 ]; then
            if [ -n "$OLD_APP" ]; then say "  Health Sync:    $OLD_APP is stopped, its LaunchAgents and launcher removed, then the folder deleted"
            else say "  Health Sync:    no old app folder"; fi
            if [ "$MOVE_DATA" = 1 ]; then say "  your data:      $OLD_DATA is moved to $DATA"; fi
            say "  sign-ins:       moved to the Keychain names of '$PREFIX'"
        fi
        if [ -n "$both_data" ]; then
            say "  your data:      both $both_data and $DATA exist: $DATA is used, the old folder is left as it is"
        fi
        say "  uv:             $APP/uv/uv ($uv_key, pinned in installer/uv.json)"
        say "  python:         $APP/python (uv-managed CPython 3.12, nothing added to PATH)"
        say "  environments:   $APP/venv (+ venv-memos when state.json lists memo extras)"
        say "  command line:   $APP/omnitrack (healthsync: the same, under the 0.1 name)"
        say "  port:           $PORT"
        if [ "$NO_SERVICES" = 1 ]; then say "  services:       not registered (--no-services)"
        else say "  services:       ~/Library/LaunchAgents/io.github.jel0624.$slug.{server,daily,memos}.plist"; fi
        if [ "$make_launcher" = 0 ]; then say "  launcher:       none (kept by an update, or --no-shortcuts)"
        else say "  launcher:       $LAUNCHER_DIR/$PREFIX.app"; fi
        if [ "$NO_BROWSER" = 1 ] || [ "$FROM_INSTALLER" = 1 ] || [ "$UPDATE" = 1 ] || [ "$NO_SERVICES" = 1 ]; then
            say "  setup page:     not opened"
        else say "  setup page:     http://127.0.0.1:$PORT/setup"; fi
        return 0
    fi
    mkdir -p "$APP" "$downloads"
    if [ -n "$OLD_APP" ] && [ -d "$OLD_APP/cache" ] && [ ! -e "$APP/cache" ]; then
        # the old app's download cache spares downloading every library again (uv's cache can be moved)
        mv "$OLD_APP/cache" "$APP/cache" 2>/dev/null && say "    reusing the download cache of $OLD_APP" || true
    fi

    # ---- 2. release zip
    step "Getting the Omnitrack release"
    local zip_path version_doc=""
    if [ -n "$ZIP" ]; then
        zip_path="$ZIP"
        [ -f "$zip_path" ] || fail 2 "Release zip not found: $zip_path"
        if [ -n "$ZIP_SHA" ] && [ "$(sha256 "$zip_path")" != "$(lower "$ZIP_SHA")" ]; then
            fail 2 "The release zip does not match its SHA256 checksum."
        fi
        if [ "$(dirname "$zip_path")" != "$downloads" ]; then
            cp -f "$zip_path" "$downloads/"
            zip_path="$downloads/$(basename "$zip_path")"
        fi
        say "    using $zip_path"
    else
        version_doc="$downloads/version.json"
        fetch "$VERSION_URL" "$version_doc" \
            || fail 2 "Could not read $VERSION_URL. Check the internet connection and try again."
        local latest zip_url zip_sum
        latest=$(json_get "$version_doc" latest) || fail 2 "version.json has no latest version."
        zip_url=$(json_get "$version_doc" assets.zip.url) || fail 2 "version.json has no release zip."
        zip_sum=$(json_get "$version_doc" assets.zip.sha256) || fail 2 "version.json has no release checksum."
        zip_path="$downloads/omnitrack-$latest.zip"
        if [ -f "$zip_path" ] && [ "$(sha256 "$zip_path")" = "$(lower "$zip_sum")" ]; then
            say "    already downloaded: $zip_path"
        else
            say "    downloading Omnitrack $latest"
            fetch "$zip_url" "$zip_path" || fail 2 "Download failed: $zip_url"
            if [ "$(sha256 "$zip_path")" != "$(lower "$zip_sum")" ]; then
                rm -f "$zip_path"
                fail 2 "The downloaded release does not match its SHA256 checksum; nothing was changed."
            fi
        fi
    fi

    # ---- 3. unpack next to the running app
    step "Unpacking"
    rm -rf "$src_new"
    ditto -x -k "$zip_path" "$src_new" || fail 2 "The release zip could not be unpacked."
    local new_version old_version=""
    new_version=$(src_version "$src_new")
    TARGET="$new_version"
    if [ ! -f "$src_new/run.py" ] || [ -z "$new_version" ]; then
        rm -rf "$src_new"
        fail 2 "The release zip is not an Omnitrack release (run.py or the version is missing)."
    fi
    [ "$had_app" = 1 ] && old_version=$(src_version "$src")
    if [ -n "$old_version" ]; then say "    Omnitrack $old_version -> $new_version"
    elif [ "$MIG" = 1 ]; then say "    Health Sync $OLD_VERSION -> Omnitrack $new_version"
    else say "    Omnitrack $new_version"; fi
    local py_version="3.12"
    [ -f "$src_new/.python-version" ] && py_version=$(head -n 1 "$src_new/.python-version" | tr -d '[:space:]')

    # ---- 4. uv (the package manager that installs Python and the libraries)
    step "Preparing uv"
    local pins="$src_new/installer/uv.json"
    if [ ! -f "$pins" ]; then
        [ -n "$version_doc" ] || fail 3 "The release has no uv pin (installer/uv.json)."
        pins="$downloads/uv-pins.json"
        json_get "$version_doc" uv json > "$pins" || fail 3 "version.json has no uv block."
    fi
    local uv_version uv_dir="$APP/uv" uv="$APP/uv/uv"
    uv_version=$(json_get "$pins" version) || fail 3 "installer/uv.json has no version."
    mkdir -p "$uv_dir"
    if [ "$(uv_version_of "$uv")" != "$uv_version" ]; then
        local tarball="$UV_TAR" uv_sum
        uv_sum=$(json_get "$pins" "$uv_key.sha256") || fail 3 "installer/uv.json has no $uv_key entry."
        if [ -z "$tarball" ]; then
            tarball="$downloads/uv-$uv_version-$uv_key.tar.gz"
            say "    downloading uv $uv_version"
            fetch "$(json_get "$pins" "$uv_key.url")" "$tarball" || fail 3 "Could not download uv."
        fi
        if [ "$(sha256 "$tarball")" != "$(lower "$uv_sum")" ]; then
            [ -n "$UV_TAR" ] || rm -f "$tarball"
            fail 3 "The uv download does not match its SHA256 checksum."
        fi
        local tmp="$downloads/uv-unpack"
        rm -rf "$tmp"; mkdir -p "$tmp"
        tar -xzf "$tarball" -C "$tmp" || fail 3 "Could not unpack uv."
        local f found
        for f in uv uvx; do
            found=$(find "$tmp" -type f -name "$f" | head -n 1)
            if [ -n "$found" ]; then cp -f "$found" "$uv_dir/$f"; chmod 755 "$uv_dir/$f"; fi
        done
        rm -rf "$tmp"
        [ -n "$UV_TAR" ] || rm -f "$tarball"
    fi
    [ "$(uv_version_of "$uv")" = "$uv_version" ] || fail 3 "uv $uv_version could not be set up in $uv_dir."
    say "    uv $uv_version"

    # every uv call: everything inside the app folder, never a system or Homebrew Python, nothing on PATH
    export UV_CACHE_DIR="$APP/cache" UV_PYTHON_INSTALL_DIR="$APP/python" UV_PYTHON_PREFERENCE=only-managed
    export UV_PYTHON_INSTALL_BIN=0 UV_PYTHON_INSTALL_REGISTRY=0 UV_NO_PROGRESS=1 UV_PROJECT_ENVIRONMENT="$APP/venv"
    export PYTHONIOENCODING=utf-8 PYTHONUTF8=1
    unset UV_PYTHON UV_SYSTEM_PYTHON VIRTUAL_ENV PYTHONHOME PYTHONPATH CONDA_PREFIX 2>/dev/null || true

    # ---- 5. Python (before anything is stopped: a failed download changes nothing)
    step "Installing Python $py_version (first time: about 20 MB)"
    run_logged "$uv" python install "$py_version" --no-bin || fail 3 "uv could not install Python $py_version."

    # ---- 6. stop the running app so its files can be replaced
    if [ "$had_app" = 1 ]; then
        step "Stopping the running Omnitrack"
        if [ -x "$old_py" ]; then run_logged "$old_py" "$src/run.py" --home "$DATA" service stop || true; fi
        local name
        for name in server daily memos; do
            launchctl bootout "gui/$(id -u)/io.github.jel0624.$slug.$name" >/dev/null 2>&1 || true
        done
        wait_app_stopped "$APP" 30
    fi

    # ---- 7. swap src (the previous version stays in src.old until the end)
    step "Installing the app files"
    rm -rf "$src_old"
    [ -d "$src" ] && mv "$src" "$src_old"
    if ! mv "$src_new" "$src"; then
        [ -d "$src_old" ] && [ ! -d "$src" ] && mv "$src_old" "$src"
        restart_previous "$new_was_up"
        fail 4 "The app folder could not be replaced."
    fi

    # ---- 8. libraries, Health Sync 0.1 handed over, command-line shim, data folder
    local extras="" py="$APP/venv/bin/python" problem=""
    if [ -n "$OLD_APP" ] && [ ! -f "$state" ] && [ -f "$OLD_APP/state.json" ]; then
        # the new app folder inherits the old one's extras (the voice memo environment to keep in sync)
        local old_extras
        old_extras=$(json_get "$OLD_APP/state.json" extras json 2>/dev/null || echo '[]')
        printf '{\n  "extras": %s\n}\n' "${old_extras:-[]}" > "$state"
    fi
    [ -f "$state" ] && extras=$(json_get "$state" extras json 2>/dev/null | tr -d '[]" \n' | tr ',' ' ' || true)
    sync_all "$extras" || problem="uv sync failed"
    if [ -z "$problem" ] && [ "$MIG" = 1 ]; then
        # the new app is ready: only now is Health Sync 0.1 stopped and its data moved (undone on any failure below)
        MIG_STOPPED=1
        [ -n "$OLD_APP" ] && stop_old_app
        if [ "$MOVE_DATA" = 1 ]; then
            move_old_data || problem="Health Sync could not be moved over (the data folder)"
        fi
    fi
    local prev_prefix=""
    [ -f "$DATA/healthsync.json" ] && prev_prefix=$(json_get "$DATA/healthsync.json" service_prefix 2>/dev/null || true)
    [ -z "$prev_prefix" ] && prev_prefix="$OLD_SETTINGS_PREFIX"
    if [ -z "$problem" ]; then
        write_shim "$custom_data"
        step "Preparing the data folder"
        if [ "$MIG_MOVED" = 0 ]; then
            # an earlier move that stopped between the rename and "migrate --moved-from" (power cut, logout), or an
            # undo that could not move the folder back: the settings still point into the old folder
            local twin
            for twin in "$(old_path "$DATA")" ${LEGACY_DATA:+"$(abspath "$LEGACY_DATA")"}; do
                [ -n "$twin" ] && [ "$twin" != "$DATA" ] && [ ! -f "$twin/healthsync.json" ] || continue
                points_into "$DATA" "$twin" || continue
                say "    the settings still point into $twin"
                run_logged "$py" "$src/run.py" --home "$DATA" migrate --moved-from "$twin" \
                    || say "    note: they could not be changed; the next install tries again"
            done
        fi
        run_logged "$py" "$src/run.py" --home "$DATA" init --port "$PORT" --service-prefix "$PREFIX" \
            || problem="omnitrack init failed"
        chmod 700 "$DATA" 2>/dev/null || true
    fi
    if [ -n "$problem" ]; then
        undo_migration
        restore_old "$extras"
        restart_previous "$new_was_up"
        fail 4 "$problem. $(rollback_note)"
    fi

    # ---- 9. background services (LaunchAgents) and the server
    local services_ok=1
    if [ "$NO_SERVICES" = 0 ]; then
        step "Registering the background services"
        MIG_NEW_AGENTS=1
        remove_stale_agents "$APP" "io.github.jel0624.$slug."
        run_logged "$py" "$src/run.py" --home "$DATA" service install || { services_ok=0; say "    service install failed"; }
        run_logged "$py" "$src/run.py" --home "$DATA" service start --only server || { services_ok=0; say "    could not start the server"; }
        step "Waiting for the Omnitrack server on port $PORT"
        # only this data folder's own server counts: another Omnitrack on the same port is not this install
        local up=0 foreign=0 new_home
        new_home=$(home_id_of "$py" "$src/run.py" "$DATA")
        [ -n "$new_home" ] && my_home="$new_home"
        for _ in $(seq 1 90); do
            pong=$(ping_server "$PORT" 2)
            if [ -n "$pong" ] && [ "$(pong_home "$pong")" = "$my_home" ]; then up=1; break; fi
            if [ -n "$pong" ]; then foreign=1; else foreign=0; fi
            sleep 1
        done
        if [ "$up" = 1 ]; then say "    the server answers on http://127.0.0.1:$PORT"
        else
            services_ok=0
            if [ "$foreign" = 1 ]; then say "    another program (or another Omnitrack) answers on port $PORT, not this one"
            else say "    the server did not answer within 90 seconds"; fi
            if [ "$MIG_STOPPED" = 1 ] || { [ "$had_app" = 1 ] && [ "$new_was_up" = 1 ] && [ -d "$src_old" ]; }; then
                # go back to what worked: Health Sync 0.1 as it was (whether or not its server ran), and the previous
                # version of this app folder when there was one
                undo_migration
                if [ "$had_app" = 1 ] && [ -d "$src_old" ]; then
                    restore_old "$extras"
                    if [ "$new_was_up" = 1 ]; then restart_previous 1
                    else run_logged "$py" "$src/run.py" --home "$DATA" service install || true; fi   # its agents back
                fi
                fail 4 "The new version did not start. $(rollback_note)"
            fi
        fi
    fi

    # ---- 10. finish: sign-ins under the current names, Health Sync 0.1 removed, launcher, state.json, clean up
    local kargs=("$src/run.py" --home "$DATA" migrate --keychain)
    [ -n "$prev_prefix" ] && [ "$prev_prefix" != "$PREFIX" ] && kargs+=(--from-prefix "$prev_prefix")
    [ -n "$OLD_APP" ] && [ -x "$OLD_APP/venv/bin/python" ] && kargs+=(--legacy-python "$OLD_APP/venv/bin/python")
    run_logged "$py" "${kargs[@]}" || say "    note: a sign-in stays under its old Keychain name; it still works"
    [ "$MIG" = 1 ] && complete_migration
    # this app folder's launcher under an earlier name is made again under this one
    local cur_launcher=""
    [ -f "$state" ] && cur_launcher=$(json_get "$state" launchers.0 2>/dev/null || true)
    case "$cur_launcher" in
        *.app) if [ "$(basename "$cur_launcher")" != "$PREFIX.app" ]; then
                   rm -rf "$cur_launcher" && say "    removed $(basename "$cur_launcher") (its old name)"
                   if [ "$NO_SHORTCUTS" = 0 ]; then
                       make_launcher=1
                       [ "$LAUNCHER_GIVEN" = 1 ] || LAUNCHER_DIR=$(dirname "$cur_launcher")
                   fi
               fi ;;
    esac
    local kind=sh
    [ "$FROM_INSTALLER" = 1 ] && kind=pkg
    local launcher_args=""
    if [ "$make_launcher" = 1 ]; then
        # an app in ~/Applications that opens the day page (the .pkg and the one-liner make no other entry point)
        step "Adding Omnitrack to Applications"
        if write_launcher "$LAUNCHER_DIR/$PREFIX.app"; then
            say "    $LAUNCHER_DIR/$PREFIX.app"
            launcher_args="$LAUNCHER_DIR/$PREFIX.app"
        else
            say "    note: the launcher could not be made in $LAUNCHER_DIR"
        fi
    fi
    if [ -n "$launcher_args" ]; then
        run_logged "$py" "$src/installer/state.py" "$state" --version "$new_version" --installer "$kind" --uv "$uv_version" \
            --launcher "$launcher_args" || true
    else
        run_logged "$py" "$src/installer/state.py" "$state" --version "$new_version" --installer "$kind" --uv "$uv_version" || true
    fi
    rm -rf "$src_old"
    local z
    for z in "$downloads"/omnitrack-*.zip "$downloads"/health-sync-*.zip; do
        if [ -e "$z" ] && [ "$z" != "$zip_path" ]; then rm -f "$z"; fi
    done

    step "Done"
    say "    Omnitrack $new_version is installed for $(id -un)."
    say "    Your data stays in $DATA"
    say "    Command line: \"$APP/omnitrack\" (for example: \"$APP/omnitrack\" doctor)"
    if [ "$NO_SERVICES" = 0 ] && [ "$NO_BROWSER" = 0 ] && [ "$FROM_INSTALLER" = 0 ] && [ "$UPDATE" = 0 ] && [ "$services_ok" = 1 ]; then
        say "    Opening the setup page: http://127.0.0.1:$PORT/setup"
        run_logged "$py" "$src/run.py" --home "$DATA" setup || open "http://127.0.0.1:$PORT/setup" || true
    elif [ "$NO_SERVICES" = 1 ]; then
        say "    Background services were not registered (--no-services). Start the server with: \"$APP/omnitrack\" serve"
    elif [ "$UPDATE" = 0 ]; then
        say "    Setup page: http://127.0.0.1:$PORT/setup"
    fi
    [ "$services_ok" = 1 ] || fail 5 "Omnitrack is installed, but its background services could not be set up. Run \"$APP/omnitrack\" doctor for details."
    write_result 0 ""
    return 0
}


# ---------------------------------------------------------------- helpers (they read main's local variables)

LOG=""
RESULT=""
MODE=install
TARGET=""
APP_FOR_RESULT=""
OLD_APP=""
OLD_DATA=""
OLD_DATA_WAS=""
MIG=0
MOVE_DATA=0
MIG_STOPPED=0
MIG_MOVED=0
MIG_NEW_AGENTS=0
MIG_UNDONE=0                # undo_migration put something back
MIG_KEEP=""                 # the old LaunchAgents' plists, kept for undo_migration
HAD_APP=0                   # an Omnitrack was installed in the app folder before this run

say() {
    printf '%s\n' "$1"
    if [ -n "$LOG" ]; then printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG" 2>/dev/null || true; fi
}

step() { say ""; say "==> $1"; }

fail() {
    say "ERROR: $2"
    [ -n "$LOG" ] && say "       The full log is in $LOG"
    write_result "$1" "$2"
    exit "$1"
}

json_str() {
    # a JSON string literal of $1 (backslashes, quotes and control characters escaped)
    printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037')"
}

write_result() {
    # <Data>/run/installer-result.json: the setup page shows whether an update installed or was rolled back
    [ -n "$RESULT" ] || return 0
    local now version=""
    mkdir -p "$(dirname "$RESULT")" 2>/dev/null || return 0
    [ -n "$APP_FOR_RESULT" ] && version=$(src_version "$APP_FOR_RESULT/src")
    now=$(date '+%Y-%m-%dT%H:%M:%S%z' | sed 's/\([0-9][0-9]\)$/:\1/')
    printf '{\n  "mode": %s,\n  "exit": %s,\n  "version": %s,\n  "target": %s,\n  "message": %s,\n  "finished_at": %s\n}\n' \
        "$(json_str "$MODE")" "$1" "$(json_str "$version")" "$(json_str "$TARGET")" "$(json_str "$2")" \
        "$(json_str "$now")" > "$RESULT" 2>/dev/null || true
}

pong_home() {
    # the "home" of a /ping answer ("" when there is none)
    printf '%s' "$1" | sed -n 's/.*"home": *"\([0-9a-f]*\)".*/\1/p' | head -n 1
}

home_id_of() {
    # a data folder's /ping "home" as the app computes it: from the app's `version --json` when it can run, else
    # sha256 of the folder's real path (Python resolves symlinks, as pwd -P does)
    local py="$1" run="$2" data="$3" out real
    if [ -x "$py" ] && [ -f "$run" ]; then
        out=$("$py" "$run" --home "$data" version --json 2>/dev/null </dev/null || true)
        out=$(printf '%s' "$out" | sed -n 's/.*"home": *"\([0-9a-f]*\)".*/\1/p' | head -n 1)
        if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    fi
    real=$(cd "$data" 2>/dev/null && pwd -P) || real="$data"
    printf '%s' "$real" | shasum -a 256 | cut -c1-12
}

renamed_path() {
    # <X>/HealthSync/<leaf> -> <X>/Omnitrack/<leaf>: where Health Sync 0.1 kept its folders; anything else unchanged
    local parent
    parent=$(dirname "$1")
    if [ "$(basename "$parent")" = "$OLD_FOLDER" ]; then
        printf '%s/%s/%s' "$(dirname "$parent")" "$NEW_NAME" "$(basename "$1")"
    else
        printf '%s' "$1"
    fi
}

old_path() {
    # <X>/Omnitrack/<leaf> -> <X>/HealthSync/<leaf> ("" for any other folder)
    local parent
    parent=$(dirname "$1")
    if [ "$(basename "$parent")" = "$NEW_NAME" ]; then
        printf '%s/%s/%s' "$(dirname "$parent")" "$OLD_FOLDER" "$(basename "$1")"
    fi
}

is_app_folder() {
    # an app folder made by install.sh (also one an earlier attempt left half removed)
    [ -d "$1" ] || return 1
    [ -f "$1/src/run.py" ] || [ -f "$1/state.json" ] || [ -d "$1/venv" ] || [ -x "$1/uv/uv" ] || [ -f "$1/healthsync" ]
}

agents_of() {
    # the LaunchAgents whose program runs from an app folder, whatever their label: "label<TAB>plist" lines
    local app="$1" f prog label
    [ -n "$app" ] || return 0
    for f in "$HOME/Library/LaunchAgents"/*.plist; do
        [ -f "$f" ] || continue
        prog=$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$f" 2>/dev/null || true)
        case "$prog" in
            "$app"/*) label=$(/usr/bin/plutil -extract Label raw -o - "$f" 2>/dev/null || true)
                      [ -n "$label" ] && printf '%s\t%s\n' "$label" "$f" ;;
        esac
    done
}

remove_stale_agents() {
    # this app folder's LaunchAgents under an earlier prefix (Health Sync 0.1's io.github.jel0624.healthsync.*)
    local app="$1" keep="$2" label plist
    agents_of "$app" | while IFS="$(printf '\t')" read -r label plist; do
        case "$label" in "$keep"*) continue ;; esac
        launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
        rm -f "$plist" && say "    removed the LaunchAgent $label (its old name)"
    done
}

stop_old_app() {
    # stop Health Sync 0.1 and unload its LaunchAgents (their plists are kept, so undo_migration can put them back)
    step "Stopping Health Sync $OLD_VERSION"
    if [ -n "$OLD_DATA" ] && [ -x "$OLD_APP/venv/bin/python" ] && [ -f "$OLD_APP/src/run.py" ]; then
        run_logged "$OLD_APP/venv/bin/python" "$OLD_APP/src/run.py" --home "$OLD_DATA" service stop || true
    fi
    MIG_KEEP=$(mktemp -d "${TMPDIR:-/tmp}/omnitrack-agents.XXXXXX")
    local label plist list
    list=$(agents_of "$OLD_APP")
    while IFS="$(printf '\t')" read -r label plist; do
        [ -n "$label" ] || continue
        cp -p "$plist" "$MIG_KEEP/" 2>/dev/null || true
        launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
        rm -f "$plist"
        say "    removed the LaunchAgent $label"
    done <<EOF
$list
EOF
    wait_app_stopped "$OLD_APP" 30
}

move_old_data() {
    # move the 0.1 data folder here (one rename), keep its config files as they were for undo_migration, and point
    # the paths in them at the new place
    step "Moving your data to $DATA"
    [ -d "$DATA" ] && rmdir "$DATA" 2>/dev/null || true
    mkdir -p "$(dirname "$DATA")"
    mv "$OLD_DATA" "$DATA" || return 1
    MIG_MOVED=1
    RESULT="$DATA/run/installer-result.json"
    [ -n "$LOG" ] && LOG="$DATA/logs/$(basename "$LOG")"
    say "    moved $OLD_DATA -> $DATA"
    local rel keep="$DATA/run/pre-0.2"
    for rel in healthsync.json activity-tracker/config.json google-health-sync/config.json voice-memos/config.json; do
        if [ -f "$DATA/$rel" ]; then mkdir -p "$(dirname "$keep/$rel")"; cp -p "$DATA/$rel" "$keep/$rel"; fi
    done
    run_logged "$APP/venv/bin/python" "$APP/src/run.py" --home "$DATA" migrate --moved-from "$OLD_DATA"
}

undo_migration() {
    # the new version did not install or start: put back what this run changed of Health Sync 0.1 and nothing else.
    # The new version's LaunchAgents are removed (a previous version of this app folder gets its own back from
    # restart_previous), the data folder is moved back and its config files restored as they were, and the old
    # LaunchAgents are loaded again (as at login: the server agent starts)
    [ "$MIG" = 1 ] && [ "$MIG_STOPPED" = 1 ] || return 0
    MIG_STOPPED=0                           # once
    step "Putting Health Sync $OLD_VERSION back"
    if [ "$MIG_NEW_AGENTS" = 1 ] && [ -x "$APP/venv/bin/python" ]; then
        run_logged "$APP/venv/bin/python" "$APP/src/run.py" --home "$DATA" service uninstall || true
    fi
    wait_app_stopped "$APP" 15
    if [ "$MIG_MOVED" = 1 ]; then
        # the folder first: when it cannot move back, its config files keep pointing where it is
        if mv "$DATA" "$OLD_DATA"; then
            MIG_MOVED=0 MIG_UNDONE=1
            RESULT="$OLD_DATA/run/installer-result.json"
            [ -n "$LOG" ] && LOG="$OLD_DATA/logs/$(basename "$LOG")"
            say "    moved your data back to $OLD_DATA"
            local rel keep="$OLD_DATA/run/pre-0.2"
            for rel in healthsync.json activity-tracker/config.json google-health-sync/config.json voice-memos/config.json; do
                if [ -f "$keep/$rel" ]; then cp -p "$keep/$rel" "$OLD_DATA/$rel" || say "    note: $rel could not be put back"; fi
            done
            rm -rf "$keep"
        else
            say "    could not move your data back (it is in $DATA)"
        fi
    fi
    local f
    if [ -n "$MIG_KEEP" ] && [ -d "$MIG_KEEP" ]; then
        for f in "$MIG_KEEP"/*.plist; do
            [ -f "$f" ] || continue
            if cp -p "$f" "$HOME/Library/LaunchAgents/"; then
                launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$(basename "$f")" >/dev/null 2>&1 || true
                MIG_UNDONE=1
                say "    restored the LaunchAgent $(basename "$f" .plist)"
            else
                say "    could not restore the LaunchAgent $(basename "$f" .plist)"
            fi
        done
        rm -rf "$MIG_KEEP"
        MIG_KEEP=""
    fi
}

rollback_note() {
    # the end of the error line after a failed install: what is back as it was
    if [ "$MIG_UNDONE" = 1 ]; then
        if [ -n "$OLD_APP" ]; then echo "Health Sync $OLD_VERSION is back as it was; your data is where it was."
        else echo "Your data is where it was."; fi
    elif [ "$HAD_APP" = 1 ]; then echo "The previous version was restored."
    else echo "Nothing else was changed; run the installer again after fixing the problem."; fi
}

points_into() {
    # does a config file of the data folder $1 name a path inside $2 (JSON: "$2/..." or "$2")
    local rel
    for rel in healthsync.json activity-tracker/config.json google-health-sync/config.json voice-memos/config.json; do
        [ -f "$1/$rel" ] || continue
        grep -qF -e "\"$2/" -e "\"$2\"" "$1/$rel" 2>/dev/null && return 0
    done
    return 1
}

complete_migration() {
    # the new version runs (and has the sign-ins): remove what is left of Health Sync 0.1 (its launcher app, the app
    # folder, the HealthSync folder when nothing else is in it)
    rm -rf "$DATA/run/pre-0.2"
    [ -n "$MIG_KEEP" ] && rm -rf "$MIG_KEEP"
    [ -n "$OLD_APP" ] || return 0
    step "Removing Health Sync $OLD_VERSION"
    local launcher a
    launcher=$(json_get "$OLD_APP/state.json" launchers.0 2>/dev/null || true)
    for a in "$launcher" "$HOME/Applications"/*.app; do
        case "$a" in *.app) ;; *) continue ;; esac
        [ -d "$a" ] || continue
        # the launcher install.sh made runs <old app>/healthsync
        if [ "$a" = "$launcher" ] || grep -qF "$OLD_APP/" "$a/Contents/MacOS/healthsync-open" 2>/dev/null; then
            rm -rf "$a" && say "    removed $(basename "$a")"
        fi
    done
    wait_app_stopped "$OLD_APP" 10
    if rm -rf "$OLD_APP"; then say "    deleted $OLD_APP"; else say "    note: could not delete $OLD_APP yet; the next install tries again"; fi
    local parent
    for parent in "$(dirname "$OLD_APP")" ${OLD_DATA_WAS:+"$(dirname "$OLD_DATA_WAS")"}; do
        if [ "$(basename "$parent")" = "$OLD_FOLDER" ] && rmdir "$parent" 2>/dev/null; then
            say "    deleted the empty folder $parent"
        fi
    done
}

write_launcher() {
    # $1 = .../Omnitrack.app: a tiny app whose program runs `omnitrack open` and shows an alert when that fails
    local app="$1" exe
    rm -rf "$app" 2>/dev/null || true
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" || return 1
    exe="$app/Contents/MacOS/omnitrack-open"
    cat > "$app/Contents/Info.plist" <<EOF || return 1
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>omnitrack-open</string>
  <key>CFBundleIdentifier</key><string>io.github.jel0624.$slug.launcher</string>
  <key>CFBundleName</key><string>$PREFIX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$new_version</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
    cat > "$exe" <<EOF || return 1
#!/bin/sh
# Omnitrack launcher (written by install.sh): opens the day page, starting the server when needed
out=\$("$APP/omnitrack" open 2>&1) && exit 0
/usr/bin/osascript -e 'on run argv' -e 'display alert "Omnitrack could not open" message (item 1 of argv)' -e 'end run' "\$out" >/dev/null 2>&1
exit 1
EOF
    chmod 755 "$exe"
}

usage() {
    echo "install.sh: $1" >&2
    echo "usage: install.sh [--app DIR] [--data DIR] [--root DIR] [--zip FILE] [--sha256 HEX] [--uv-tar FILE]" >&2
    echo "                  [--version-url URL] [--port N] [--service-prefix P] [--launcher-dir DIR]" >&2
    echo "                  [--legacy-app DIR] [--legacy-data DIR] [--no-services] [--no-browser] [--no-shortcuts]" >&2
    echo "                  [--from-installer] [--update] [--dry-run]" >&2
    exit 1
}

abspath() {
    # absolute path without requiring it to exist
    case "$1" in
        /*) printf '%s' "$1" | sed 's:/*$::' ;;
        *) printf '%s/%s' "$(pwd)" "$1" | sed 's:/*$::' ;;
    esac
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

fetch() {
    # download (or copy, for a local path) through a .part file
    local url="$1" dest="$2"
    rm -f "$dest.part"
    case "$url" in
        http://*|https://*)
            if [ -t 1 ]; then curl -fL --retry 3 --progress-bar -o "$dest.part" "$url" </dev/null || return 1
            else curl -fsSL --retry 3 -o "$dest.part" "$url" </dev/null || return 1; fi ;;
        *) cp -f "${url#file://}" "$dest.part" || return 1 ;;
    esac
    mv -f "$dest.part" "$dest"
}

json_get() {
    # json_get FILE KEYPATH [raw|json]: one value from a JSON file, read with macOS's own plutil
    /usr/bin/plutil -extract "$2" "${3:-raw}" -o - "$1" 2>/dev/null
}

src_version() {
    [ -f "$1/healthsync/__init__.py" ] || return 0
    sed -n 's/^__version__ *= *["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/p' "$1/healthsync/__init__.py" | head -n 1
}

uv_version_of() {
    [ -x "$1" ] || return 0
    "$1" --version 2>/dev/null </dev/null | awk '{print $2}'
}

ping_server() {
    # the /ping JSON of whatever answers on the port, "other" for a non-HTTP listener, "" for nothing
    local out
    if out=$(curl -sS --noproxy '*' --max-time "$2" "http://127.0.0.1:$1/ping" 2>/dev/null </dev/null); then
        [ -n "$out" ] && { printf '%s' "$out"; return 0; }
        echo other; return 0
    fi
    if nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1 </dev/null; then echo other; fi
    return 0
}

run_logged() {
    # run a program, copy its output to the console and the log, return its exit code
    local rcfile rc line
    rcfile=$(mktemp "${TMPDIR:-/tmp}/omnitrack-rc.XXXXXX")
    { "$@" </dev/null 2>&1 && rc=0 || rc=$?; echo "$rc" > "$rcfile"; } | while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$line" ]; then say "    $line"; fi
    done
    rc=$(cat "$rcfile" 2>/dev/null || echo 1)
    rm -f "$rcfile"
    return "${rc:-1}"
}

wait_app_stopped() {
    # wait for the server and jobs started from the app folder to exit, then end the rest
    local app="$1" secs="$2"
    for _ in $(seq 1 "$((secs * 2))"); do
        pgrep -f "$app/venv" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    say "    ending the remaining processes of $app"
    pkill -f "$app/venv" >/dev/null 2>&1 || true
    sleep 1
}

sync_all() {
    # uv sync of the base environment, and of venv-memos when the voice memo step installed it
    step "Installing the libraries (first time: a few minutes)"
    export UV_PROJECT_ENVIRONMENT="$APP/venv"
    run_logged "$APP/uv/uv" sync --project "$APP/src" --frozen --no-dev || return 1
    case " $1 " in
        *" memos "*)
            step "Updating the voice memo environment"
            # the cuda extra only has Windows packages; on a Mac it is just "memos"
            export UV_PROJECT_ENVIRONMENT="$APP/venv-memos"
            if ! run_logged "$APP/uv/uv" sync --project "$APP/src" --frozen --no-dev --extra memos; then
                export UV_PROJECT_ENVIRONMENT="$APP/venv"
                return 1
            fi
            export UV_PROJECT_ENVIRONMENT="$APP/venv" ;;
    esac
    return 0
}

restore_old() {
    # put src.old back and re-sync its libraries
    if [ ! -d "$APP/src.old" ]; then
        [ "$MIG" = 1 ] || say "    nothing to restore (first install); run the installer again after fixing the problem"
        return 0
    fi
    step "Restoring the previous version"
    wait_app_stopped "$APP" 15
    rm -rf "$APP/src"
    mv "$APP/src.old" "$APP/src" || { say "    restore failed"; return 0; }
    sync_all "$1" || say "    re-sync of the previous version failed"
}

restart_previous() {
    # start this app folder's server again when it ran before the install began (macOS: re-register the agents);
    # nothing when there was no Omnitrack here (the new files must not start; Health Sync 0.1 is undo_migration's)
    [ "$1" = 1 ] || return 0
    [ "$HAD_APP" = 1 ] || return 0
    [ -x "$APP/venv/bin/python" ] && [ -f "$APP/src/run.py" ] || return 0
    run_logged "$APP/venv/bin/python" "$APP/src/run.py" --home "$DATA" service install || true
    run_logged "$APP/venv/bin/python" "$APP/src/run.py" --home "$DATA" service start --only server || true
}

write_shim() {
    # <App>/omnitrack runs the CLI with the app's own Python; --home only for a non-default data folder.
    # <App>/healthsync, the 0.1 name, does the same for scripts and habits that still use it.
    local home_arg="" name
    [ "$1" = 1 ] && home_arg=" --home \"$DATA\""
    for name in omnitrack healthsync; do
        cat > "$APP/$name" <<EOF
#!/bin/sh
# Omnitrack command line (written by install.sh)
here=\$(cd "\$(dirname "\$0")" && pwd)
exec "\$here/venv/bin/python" "\$here/src/run.py"$home_arg "\$@"
EOF
        chmod 755 "$APP/$name"
    done
}

# everything above is only definitions: with "curl | bash" nothing runs before the whole script has arrived
main "$@"
