#!/bin/bash
# dock-folders — Generate .app wrappers for folders so custom icons show in the macOS Dock
# Each generated app shows a native popup menu with the folder's contents when clicked.
#
# Usage:
#   ./dock-folders.sh /path/to/folder1 [/path/to/folder2 ...]
#   ./dock-folders.sh --output-dir ~/MyApps /path/to/folder
#   ./dock-folders.sh --all /path/to/parent-directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUTPUT_DIR="$SCRIPT_DIR/build"
OUTPUT_DIR=""
ALL_MODE=false
VIEW_MODE="list"
FOLDERS=()

# Resolves $1 to an absolute, real path -- prints it and returns success,
# or prints nothing and fails if it isn't an existing directory. "--" and
# an unset CDPATH keep an odd-looking value (a bare "-", or a name that
# happens to match a CDPATH entry) from resolving to somewhere other than
# the literal path given; -P (not -L) follows a symlinked folder to where
# it actually points. A leading "~" is expanded first, since a value that
# arrived pre-quoted (e.g. inside a --combine argument) never got that
# from the shell the way a bare positional argument normally would.
resolve_existing_dir() {
    local raw="${1/#\~/$HOME}"
    ( unset CDPATH; cd -P -- "$raw" 2>/dev/null && pwd -P )
}

# Escapes a string for safe embedding inside an AppleScript double-quoted
# string literal. Folder/file names may legally contain characters (", \)
# that would otherwise let untrusted filenames break out of the literal and
# inject arbitrary AppleScript (e.g. `do shell script "..."`).
applescript_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    # A raw newline/CR inside a "..." literal isn't a valid AppleScript
    # escape and would break compilation of the generated source, so
    # collapse it rather than leave the template in an unparseable state.
    s="${s//$'\n'/ }"
    s="${s//$'\r'/ }"
    printf '%s' "$s"
}

# Reads one of Finder's own icon-view settings (iconSize or textSize) so
# the grid view's icon/label size follows what the user already has Finder
# set to, instead of a hardcoded guess. Finder keeps a separate setting for
# the Desktop specifically (View Options on the Desktop) from every other
# folder's default (View Options on a regular Finder window) -- callers
# pick which one applies. Falls back to Finder's own defaults if the key
# isn't set (e.g. the user never opened View Options) or can't be read.
finder_icon_view_setting() {
    local settings_key="$1" # DesktopViewSettings or FK_StandardViewSettings
    local subkey="$2"       # iconSize or textSize
    local fallback="$3"
    local plist="$HOME/Library/Preferences/com.apple.finder.plist"
    local raw
    raw=$(/usr/libexec/PlistBuddy -c "Print :${settings_key}:IconViewSettings:${subkey}" "$plist" 2>/dev/null)
    if [[ "$raw" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%.0f' "$raw"
    else
        printf '%s' "$fallback"
    fi
}

# Warns (doesn't block) if the chosen output directory could let another
# local user tamper with what's built there. The build itself no longer
# has an exploitable window regardless of this -- everything is built in
# a private temp directory and only the finished, signed bundle is moved
# into place -- but a shared, writable output directory is still worth
# flagging on its own terms (anyone with write access there could still
# swap out the finished .app between builds, replace icons, etc.).
check_output_dir_safety() {
    local dir="$1"
    local owner_uid perms group_bit other_bit
    owner_uid="$(stat -f '%u' "$dir" 2>/dev/null)" || return 0
    perms="$(stat -f '%Lp' "$dir" 2>/dev/null)" || return 0
    if [[ "$owner_uid" != "$(id -u)" ]]; then
        echo "⚠ Warning: '$dir' isn't owned by you -- its owner could tamper with what's built there." >&2
    fi
    group_bit=$(( (8#$perms / 8) % 8 ))
    other_bit=$(( 8#$perms % 8 ))
    if (( (group_bit & 2) != 0 || (other_bit & 2) != 0 )); then
        echo "⚠ Warning: '$dir' is writable by other users on this Mac. Consider a private directory instead." >&2
    fi
}

# ─── Keeping generated apps warm across logins ──────────────────────────────
# Each app pre-warms itself right after being built (see the main loop
# below), but that warmth doesn't survive a restart, logout, or force-quit.
# A per-user LaunchAgent re-warms every app this script has ever generated
# each time the user logs in, so the very first click of a session is fast
# too, not just the ones after this script happened to run.
PREWARM_SUPPORT_DIR="$HOME/Library/Application Support/dock-folders"
PREWARM_MANIFEST="$PREWARM_SUPPORT_DIR/prewarmed-apps.txt"
PREWARM_AGENT_LABEL="com.dock-folders.prewarm"
PREWARM_AGENT_PLIST="$HOME/Library/LaunchAgents/${PREWARM_AGENT_LABEL}.plist"

# Returns success only if $1 looks like a real Dock Folders app bundle
# we actually generated -- not just any directory that happens to sit
# at a path the prewarm manifest once recorded. The login-time agent
# below runs at every login with nobody watching what it opens; a
# manifest entry can outlive the app it named (deleted, or its path
# reused by something else entirely -- a downloaded .app, even a
# folder someone else can write to), and without this check it would
# get silently launched too.
is_our_app_bundle() {
    local path="$1"
    [[ -d "$path" ]] || return 1
    [[ -x "$path/Contents/MacOS/applet" ]] || return 1
    local bundle_id
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Contents/Info.plist" 2>/dev/null)" || return 1
    [[ "$bundle_id" == com.dock-folders.* ]]
}

ensure_prewarm_login_agent() {
    mkdir -p "$PREWARM_SUPPORT_DIR" "$HOME/Library/LaunchAgents"
    chmod 700 "$PREWARM_SUPPORT_DIR"
    touch "$PREWARM_MANIFEST"
    chmod 600 "$PREWARM_MANIFEST"

    # Drop any entry that no longer checks out (see is_our_app_bundle
    # above), rather than letting this list only ever grow.
    if [[ -s "$PREWARM_MANIFEST" ]]; then
        local pruned
        pruned="$(mktemp "${TMPDIR:-/tmp}/dock-folders-manifest.XXXXXX")"
        while IFS= read -r app; do
            [[ -n "$app" ]] || continue
            is_our_app_bundle "$app" && printf '%s\n' "$app" >> "$pruned"
        done < "$PREWARM_MANIFEST"
        mv "$pruned" "$PREWARM_MANIFEST"
        chmod 600 "$PREWARM_MANIFEST"
    fi

    local warm_script="$PREWARM_SUPPORT_DIR/prewarm.sh"
    cat > "$warm_script" <<WARMEOF
#!/bin/bash
# Silently re-launches every Dock Folders app generated so far, so each is
# already a warm, running process before it's actually clicked -- avoiding
# a cold start (process launch, framework loading) on the first click of
# a session. Managed by dock-folders.sh; regenerated each time it runs.
MANIFEST="$PREWARM_MANIFEST"
[[ -f "\$MANIFEST" ]] || exit 0
while IFS= read -r app; do
    [[ -n "\$app" && -d "\$app" ]] || continue
    # Only reopen bundles that are actually ours -- see
    # is_our_app_bundle() in dock-folders.sh for the full reasoning.
    [[ -x "\$app/Contents/MacOS/applet" ]] || continue
    bundle_id="\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "\$app/Contents/Info.plist" 2>/dev/null)"
    [[ "\$bundle_id" == com.dock-folders.* ]] || continue
    open --env DOCK_FOLDERS_PREWARM=1 -g "\$app" 2>/dev/null || true
done < "\$MANIFEST"
WARMEOF
    chmod 700 "$warm_script"

    cat > "$PREWARM_AGENT_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${PREWARM_AGENT_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${warm_script}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
PLISTEOF
    chmod 600 "$PREWARM_AGENT_PLIST"

    # (Re)load now too, not just at next login, so this run's warm-up
    # takes effect immediately.
    launchctl bootout "gui/$(id -u)" "$PREWARM_AGENT_PLIST" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PREWARM_AGENT_PLIST" >/dev/null 2>&1 || true
}

record_prewarmed_app() {
    local app_path="$1"
    grep -qxF "$app_path" "$PREWARM_MANIFEST" 2>/dev/null || echo "$app_path" >> "$PREWARM_MANIFEST"
}

# ─── Argument parsing ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] FOLDER [FOLDER ...]

Generate .app wrappers for folders so their custom icons show in the macOS Dock.

Options:
  --output-dir DIR       Where to place generated .app bundles
                         (default: ./build, next to this script)
  --all DIR              Process all subdirectories within DIR
  --view MODE            Popup layout: "list" or "grid" (default: list)
  --combine NAME=DIR,DIR[,DIR...]
                         Show two or more real folders as one combined app
                         named NAME -- e.g. /Applications and
                         /System/Applications appearing as a single
                         "Applications" Dock icon. Contents are merged and
                         sorted together; a name that exists in more than
                         one of the folders is shown once, from whichever
                         folder is listed first. Repeatable, for more than
                         one combined app.
  -h, --help             Show this help

Examples:
  $(basename "$0") ~/Documents/dock-folders/coding
  $(basename "$0") --all ~/Documents/dock-folders
  $(basename "$0") --output-dir ~/Desktop ~/Documents/my-folder
  $(basename "$0") --view grid ~/Documents/dock-folders/coding
  $(basename "$0") --combine "Applications=/Applications,/System/Applications"
EOF
    exit 0
}

COMBINE_SPECS=()

NO_MORE_OPTIONS=false
while [[ $# -gt 0 ]]; do
    if $NO_MORE_OPTIONS; then
        FOLDERS+=("$1")
        shift
        continue
    fi
    case "$1" in
        --)
            NO_MORE_OPTIONS=true
            shift
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --all)
            ALL_MODE=true
            shift
            ;;
        --view)
            VIEW_MODE="$2"
            shift 2
            ;;
        --combine)
            COMBINE_SPECS+=("$2")
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            # A folder that happens to start with "-" (or a bare "-")
            # is exactly the kind of argument that later gets handed
            # straight to `cd` -- silently treating it as a folder here
            # instead of rejecting it is how that ends up resolving to
            # somewhere the user never named. Use "--" first if a real
            # folder name genuinely starts with "-".
            echo "Error: unknown option '$1' (use -- before a folder name that starts with -)" >&2
            exit 1
            ;;
        *)
            FOLDERS+=("$1")
            shift
            ;;
    esac
done

# In --all mode, the single argument is the parent directory
if $ALL_MODE; then
    if [[ ${#FOLDERS[@]} -ne 1 ]]; then
        echo "Error: --all requires exactly one directory argument"
        exit 1
    fi
    PARENT_DIR="${FOLDERS[0]}"
    if [[ ! -d "$PARENT_DIR" ]]; then
        echo "Error: '$PARENT_DIR' is not a directory"
        exit 1
    fi
    FOLDERS=()
    while IFS= read -r -d '' dir; do
        FOLDERS+=("$dir")
    done < <(find "$PARENT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 | sort -z)
fi

if [[ ${#FOLDERS[@]} -eq 0 && ${#COMBINE_SPECS[@]} -eq 0 ]]; then
    echo "Error: No folders specified. Use -h for help."
    exit 1
fi

# Build the list of apps to generate: one entry per app, encoded as
# "NAME<TAB>path1,path2,...". A plain folder becomes an app named for
# itself, backed by that one real folder; a --combine spec becomes an
# app named as specified, backed by however many real folders it lists.
# Unifying both into one shape here (instead of treating them as two
# separate cases) means the main loop below doesn't need to know the
# difference.
APP_SPECS=()

# Guarded by a count check, not just iterated directly: macOS's stock
# /bin/bash is 3.2, where "${arr[@]}" on a declared-but-empty array
# throws "unbound variable" under "set -u" -- and unlike FOLDERS before
# this feature existed, either of these two can now legitimately be
# empty (a run using only --combine has no plain FOLDERS, and vice
# versa) rather than always having been checked non-empty already.
if [[ ${#FOLDERS[@]} -gt 0 ]]; then
    for folder in "${FOLDERS[@]}"; do
        if ! resolved="$(resolve_existing_dir "$folder")"; then
            echo "⚠ Skipping '$folder' — not a directory"
            continue
        fi
        APP_SPECS+=("$(basename "$resolved")"$'\t'"$resolved")
    done
fi

if [[ ${#COMBINE_SPECS[@]} -gt 0 ]]; then
    for spec in "${COMBINE_SPECS[@]}"; do
        if [[ "$spec" != *=* ]]; then
            echo "Error: --combine must look like NAME=DIR,DIR[,DIR...] (got '$spec')" >&2
            exit 1
        fi
        combine_name="${spec%%=*}"
        combine_paths_raw="${spec#*=}"
        if [[ -z "$combine_name" ]]; then
            echo "Error: --combine is missing a name (got '$spec')" >&2
            exit 1
        fi
        resolved_paths=""
        remaining="$combine_paths_raw"
        while [[ -n "$remaining" ]]; do
            one="${remaining%%,*}"
            if [[ "$remaining" == *,* ]]; then
                remaining="${remaining#*,}"
            else
                remaining=""
            fi
            [[ -n "$one" ]] || continue
            if ! one_resolved="$(resolve_existing_dir "$one")"; then
                echo "⚠ --combine '$combine_name': skipping '$one' — not a directory" >&2
                continue
            fi
            if [[ -n "$resolved_paths" ]]; then
                resolved_paths+=","
            fi
            resolved_paths+="$one_resolved"
        done
        if [[ -z "$resolved_paths" ]]; then
            echo "⚠ --combine '$combine_name': no valid folders, skipping" >&2
            continue
        fi
        APP_SPECS+=("$combine_name"$'\t'"$resolved_paths")
    done
fi

if [[ ${#APP_SPECS[@]} -eq 0 ]]; then
    echo "Error: No valid folders to build. Use -h for help."
    exit 1
fi

if [[ "$VIEW_MODE" != "list" && "$VIEW_MODE" != "grid" ]]; then
    echo "Error: --view must be 'list' or 'grid' (got '$VIEW_MODE')"
    exit 1
fi
IS_GRID_LITERAL=false
if [[ "$VIEW_MODE" == "grid" ]]; then
    IS_GRID_LITERAL=true
fi

OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
mkdir -p "$OUTPUT_DIR"
# Resolved to an absolute path: a relative --output-dir would otherwise
# get recorded as-is in the prewarm manifest, and the login-time
# LaunchAgent runs with a different (or undefined) working directory --
# silently no-op'ing on every one of those relative entries.
OUTPUT_DIR="$(cd -P -- "$OUTPUT_DIR" && pwd -P)"
check_output_dir_safety "$OUTPUT_DIR"

echo "🔁 Setting up login-time warm-up for generated apps..."
ensure_prewarm_login_agent

# On-disk cache of downsized item thumbnails (real photo/PDF previews,
# keyed by source path + mtime + size), shared by every generated app.
# Without it, each app decodes every image/PDF in its folder at full
# resolution on every popup build and never releases it -- for a folder
# with a few hundred photos that's easily north of a gigabyte of RSS.
THUMB_CACHE_DIR="$PREWARM_SUPPORT_DIR/thumbnails"
mkdir -p "$THUMB_CACHE_DIR"

# ─── Icon extraction ────────────────────────────────────────────────────────────
# Extracts the folder's rendered icon (including custom emoji + color) as .icns
create_icns() {
    local folder_path="$1"
    local icns_path="$2"
    local png_path="${icns_path%.icns}.png"
    local iconset_dir="${icns_path%.icns}.iconset"

    # Check for "Customize Folder" emoji icon (stored as JSON xattr)
    local emoji=""
    local xattr_data
    xattr_data=$(xattr -p com.apple.icon.folder#S "$folder_path" 2>/dev/null) || true
    if [[ -n "$xattr_data" ]]; then
        # Parse emoji from JSON like {"emoji":"👨‍💻"}
        emoji=$(echo "$xattr_data" | python3 -c "import sys,json; print(json.load(sys.stdin).get('emoji',''))" 2>/dev/null) || true
    fi

    local emoji_esc png_path_esc folder_path_esc
    emoji_esc="$(applescript_escape "$emoji")"
    png_path_esc="$(applescript_escape "$png_path")"
    folder_path_esc="$(applescript_escape "$folder_path")"

    # Step 1: Render the folder icon as 1024x1024 PNG via AppleScript ObjC bridge
    if [[ -n "$emoji" ]]; then
        # Render emoji on dark background (macOS adds its own squircle mask)
        osascript <<ICONSCRIPT >/dev/null 2>&1
use framework "AppKit"
use framework "Foundation"
use scripting additions

set px to 1024

-- Create canvas
set bitmapRep to (current application's NSBitmapImageRep's alloc()'s initWithBitmapDataPlanes:(missing value) pixelsWide:px pixelsHigh:px bitsPerSample:8 samplesPerPixel:4 hasAlpha:true isPlanar:false colorSpaceName:(current application's NSCalibratedRGBColorSpace) bytesPerRow:0 bitsPerPixel:0)

set ctx to (current application's NSGraphicsContext's graphicsContextWithBitmapImageRep:bitmapRep)
current application's NSGraphicsContext's setCurrentContext:ctx

-- Fill with dark background
set bgColor to current application's NSColor's colorWithCalibratedRed:0.455 green:0.455 blue:0.471 alpha:1.0
set bgPath to current application's NSBezierPath's bezierPathWithRect:{{0, 0}, {px, px}}
bgColor's setFill()
bgPath's fill()

-- Draw emoji large and centered
set emojiStr to current application's NSString's stringWithString:"${emoji_esc}"
set emojiSize to 620
set emojiFont to current application's NSFont's systemFontOfSize:emojiSize
set emojiAttrs to current application's NSDictionary's dictionaryWithObjects:{emojiFont} forKeys:{current application's NSFontAttributeName}
set attrStr to (current application's NSAttributedString's alloc()'s initWithString:emojiStr attributes:emojiAttrs)
set strSize to attrStr's |size|()
set strW to strSize's width
set strH to strSize's height
set drawX to ((px - strW) / 2)
set drawY to ((px - strH) / 2)
attrStr's drawAtPoint:{x:drawX, y:drawY}

current application's NSGraphicsContext's setCurrentContext:(missing value)

set pngData to bitmapRep's representationUsingType:4 |properties|:(missing value)
set outURL to current application's NSURL's fileURLWithPath:"${png_path_esc}"
pngData's writeToURL:outURL options:0 |error|:(missing value)
ICONSCRIPT
    else
        # No custom emoji — use NSWorkspace's standard icon
        osascript <<ICONSCRIPT >/dev/null 2>&1
use framework "AppKit"
use framework "Foundation"
use scripting additions

set ws to current application's NSWorkspace's sharedWorkspace()
set theIcon to ws's iconForFile:"${folder_path_esc}"
theIcon's setSize:{width:1024, height:1024}

set bitmapRep to (current application's NSBitmapImageRep's alloc()'s initWithBitmapDataPlanes:(missing value) pixelsWide:1024 pixelsHigh:1024 bitsPerSample:8 samplesPerPixel:4 hasAlpha:true isPlanar:false colorSpaceName:(current application's NSCalibratedRGBColorSpace) bytesPerRow:0 bitsPerPixel:0)

set ctx to (current application's NSGraphicsContext's graphicsContextWithBitmapImageRep:bitmapRep)
current application's NSGraphicsContext's setCurrentContext:ctx
theIcon's drawInRect:{origin:{x:0, y:0}, |size|:{width:1024, height:1024}}
current application's NSGraphicsContext's setCurrentContext:(missing value)

set pngData to bitmapRep's representationUsingType:4 |properties|:(missing value)
set outURL to current application's NSURL's fileURLWithPath:"${png_path_esc}"
pngData's writeToURL:outURL options:0 |error|:(missing value)
ICONSCRIPT
    fi

    if [[ ! -f "$png_path" || ! -s "$png_path" ]]; then
        return 1
    fi

    # Step 2: Create iconset with all required sizes via sips
    mkdir -p "$iconset_dir"
    sips -z 16 16     "$png_path" --out "$iconset_dir/icon_16x16.png"      >/dev/null 2>&1
    sips -z 32 32     "$png_path" --out "$iconset_dir/icon_16x16@2x.png"   >/dev/null 2>&1
    sips -z 32 32     "$png_path" --out "$iconset_dir/icon_32x32.png"      >/dev/null 2>&1
    sips -z 64 64     "$png_path" --out "$iconset_dir/icon_32x32@2x.png"   >/dev/null 2>&1
    sips -z 128 128   "$png_path" --out "$iconset_dir/icon_128x128.png"    >/dev/null 2>&1
    sips -z 256 256   "$png_path" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "$png_path" --out "$iconset_dir/icon_256x256.png"    >/dev/null 2>&1
    sips -z 512 512   "$png_path" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "$png_path" --out "$iconset_dir/icon_512x512.png"    >/dev/null 2>&1
    sips -z 1024 1024 "$png_path" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null 2>&1

    # Step 3: Convert iconset to icns
    iconutil -c icns "$iconset_dir" -o "$icns_path" 2>/dev/null
    local result=$?

    # Cleanup
    rm -rf "$iconset_dir" "$png_path"
    return $result
}

# ─── AppleScript template ───────────────────────────────────────────────────────
generate_applescript() {
    local folder_paths_csv="$1" # one or more real absolute paths, comma-separated --
                                 # a single-folder app is just the one-path case
    local folder_name="$2"
    local is_grid="$3" # "true" or "false" -- a trusted literal, not escaped text
    local grid_icon_size="$4" # from Finder's own icon-view settings -- a plain integer
    local grid_text_size="$5" # likewise
    local grid_spacing="$6" # likewise
    local debug_log_path="$7"
    local thumb_cache_dir="$8"
    local folder_name_esc debug_log_path_esc thumb_cache_dir_esc
    folder_name_esc="$(applescript_escape "$folder_name")"
    debug_log_path_esc="$(applescript_escape "$debug_log_path")"
    thumb_cache_dir_esc="$(applescript_escape "$thumb_cache_dir")"

    # Build the AppleScript list literal for sourceFolderPaths, e.g.
    # {"/Applications", "/System/Applications"} -- each path individually
    # escaped the same way every other string is before it's embedded in
    # the generated source. Split via parameter expansion, not IFS word-
    # splitting -- no dependency on IFS actually being what's expected.
    local source_folder_paths_literal="" one_path one_path_esc
    local remaining_paths="$folder_paths_csv"
    while [[ -n "$remaining_paths" ]]; do
        one_path="${remaining_paths%%,*}"
        if [[ "$remaining_paths" == *,* ]]; then
            remaining_paths="${remaining_paths#*,}"
        else
            remaining_paths=""
        fi
        [[ -n "$one_path" ]] || continue
        one_path_esc="$(applescript_escape "$one_path")"
        if [[ -n "$source_folder_paths_literal" ]]; then
            source_folder_paths_literal+=", "
        fi
        source_folder_paths_literal+="\"$one_path_esc\""
    done

    cat <<APPLESCRIPT
use framework "AppKit"
use framework "Foundation"
use framework "PDFKit"
use scripting additions

property sourceFolderPaths : {$source_folder_paths_literal}
property itemPaths : {}
property currentFolderPath : ""
property isGridView : $is_grid
property activeWindow : missing value
property dismissTimer : missing value
property keepAliveActivity : missing value
property hasSeenActiveThisShow : false
property inactiveStreak : 0
property debugLogPath : "$debug_log_path_esc"
property thumbCacheDir : "$thumb_cache_dir_esc"
-- Fixed resolution real item thumbnails are generated/cached at,
-- independent of the current display size (list view's small icon vs.
-- grid view's larger one) -- see realThumbnailForPath. Large enough to
-- stay sharp at a Retina 2x pixel density for the largest icon size
-- Finder's own grid-icon-size setting realistically produces, small
-- enough to keep per-item memory in the hundreds-of-KB range instead
-- of the tens-of-MB a native-resolution photo decodes to. Sized for a
-- sharp Retina 2x grid icon at Finder's default grid-icon-size setting
-- (96pt -> 192px); larger than that is a rare custom setting, and with
-- loaded thumbnails now bounded by maxLoadedThumbnails rather than by
-- folder size, there's no longer a reason to size this for the largest
-- plausible setting "just in case" the way there was before that cap
-- existed.
property thumbCacheSize : 256
property isBuildingMenu : false
-- Real (decoded) thumbnails are loaded only for items currently on
-- screen, not for the whole folder up front -- everything else shows
-- the cheap generic per-type icon until it's scrolled into view. These
-- four track that: itemIconViews/itemHasRealThumb are parallel to
-- allNames/itemPaths (index i in one is the same item as index i in
-- the others -- see the note in showFolderMenu on why they're
-- pre-filled to itemCount length up front rather than appended to
-- during the build loop), loadedThumbOrder is every index currently
-- holding a real thumbnail in least- to most-recently-visible order
-- (a plain LRU queue), and lastVisibleFirstIndex/lastVisibleLastIndex
-- are the visible range as of the last check, purely so an unchanged
-- scroll position between ticks is a no-op instead of redoing the same
-- work five times a second.
property itemIconViews : {}
property itemHasRealThumb : {}
property loadedThumbOrder : {}
property lastVisibleFirstIndex : 0
property lastVisibleLastIndex : 0
property currentColumns : 1
property currentCellH : 34
property currentItemsH : 0
property currentIconSize : 26
-- 10 columns x 7 rows -- computeLayout's own cap before a grid needs to
-- scroll at all -- is the largest count that's ever genuinely all
-- visible at once, so nothing above that needs to stay resident. Not
-- applied literally as "evict at 71": see updateVisibleThumbnails,
-- which never evicts anything currently on screen regardless of this
-- number, so the true ceiling is max(70, current visible count).
property maxLoadedThumbnails : 70
-- Once built, activeWindow and its whole view hierarchy (every item's
-- icon/label/button/menu) are kept alive for the app's lifetime instead
-- of being destroyed and recreated on every close/reopen: doing that on
-- every click, even a click that just toggles the popup closed, was the
-- actual cause of an intermittent crash under fast repeated clicking.
-- popupVisible tracks show/hide state separately, since activeWindow no
-- longer goes back to missing value just because the popup is hidden.
-- lastItemNames/builtTotalW record what's currently built, so a click
-- that finds the folder's contents unchanged can just reshow the
-- existing window instead of rebuilding anything.
property popupVisible : false
property lastItemNames : {}
property builtTotalW : 0
property builtItemsContainer : missing value
property builtItemsH : 0
property builtNeedsScroll : false

on logEvent(msg)
    -- Diagnostic trail: showFolderMenu() has a lot of surface area with
    -- no error handling of its own, and a failure there can look exactly
    -- like "the click did nothing". Logging every run/reopen and every
    -- caught error means the next occurrence leaves real evidence
    -- instead of needing to be reproduced blind.
    --
    -- Built entirely through Cocoa (NSString/NSFileHandle/NSDateFormatter),
    -- not AppleScript's native "&", "write", or "(current date) as text":
    -- AppleScript's own legacy string engine has a real memory-corruption
    -- bug under sustained repeated use in a long-lived process, and this
    -- handler runs on every single log call across the app's lifetime.
    try
        set fm to current application's NSFileManager's defaultManager()
        set logDir to ((current application's NSString's stringWithString:(my debugLogPath))'s stringByDeletingLastPathComponent())
        (fm's createDirectoryAtPath:logDir withIntermediateDirectories:true attributes:(missing value) |error|:(missing value))
        if not (fm's fileExistsAtPath:(my debugLogPath)) then
            (fm's createFileAtPath:(my debugLogPath) |contents|:(missing value) |attributes|:(missing value))
        end if
        set fmt to (current application's NSDateFormatter's alloc()'s init())
        (fmt's setDateStyle:(current application's NSDateFormatterFullStyle))
        (fmt's setTimeStyle:(current application's NSDateFormatterMediumStyle))
        set nsLine to (fmt's stringFromDate:(current application's NSDate's |date|()))
        set nsLine to (nsLine's stringByAppendingString:" -- ")
        set nsLine to (nsLine's stringByAppendingString:(current application's NSString's stringWithString:msg))
        set nsLine to (nsLine's stringByAppendingString:(current application's NSString's stringWithString:linefeed))
        set nsData to (nsLine's dataUsingEncoding:(current application's NSUTF8StringEncoding))
        set fh to (current application's NSFileHandle's fileHandleForWritingAtPath:(my debugLogPath))
        -- Reset past a size cap instead of growing forever.
        set curLogSize to 0
        set logAttrs to (fm's attributesOfItemAtPath:(my debugLogPath) |error|:(missing value))
        if logAttrs is not missing value then
            set sizeNum to (logAttrs's objectForKey:(current application's NSFileSize))
            if sizeNum is not missing value then set curLogSize to (sizeNum as integer)
        end if
        if curLogSize > 2000000 then
            (fh's truncateFileAtOffset:0)
        else
            (fh's seekToEndOfFile())
        end if
        (fh's writeData:nsData)
        (fh's closeFile())
    end try
end logEvent

on run
    my logEvent("on run fired")
    try
        -- This whole app's design depends on staying resident between
        -- clicks (see the prewarming note below), but a background agent
        -- with no open windows is exactly what macOS's Automatic
        -- Termination / App Nap targets for being silently killed or
        -- throttled to save resources. Opt out for this process's entire
        -- lifetime, once, right at launch.
        set pInfo to current application's NSProcessInfo's processInfo()
        (pInfo's disableAutomaticTermination:"Dock Folders stays running so future clicks are instant")
        (pInfo's disableSuddenTermination())
        set my keepAliveActivity to (pInfo's beginActivityWithOptions:(current application's NSActivityUserInitiated) reason:"Dock Folders popup responsiveness")

        -- dock-folders.sh silently pre-launches the app right after
        -- building it (see the main script), so it's already a warm,
        -- already-running process by the time the user first clicks it --
        -- avoiding the cold start (process launch, framework loading)
        -- that a genuinely first-ever launch pays. That pre-launch sets
        -- this to tell run apart from an actual click, which always
        -- arrives as reopen once the process is already alive; skip
        -- showing the menu only for the former.
        set prewarmFlag to (system attribute "DOCK_FOLDERS_PREWARM")
        if prewarmFlag is "" then
            showFolderMenu()
        else
            my logEvent("run: prewarm launch, not showing menu")
        end if
    on error errMsg number errNum
        my logEvent("run: UNCAUGHT ERROR " & errNum & ": " & errMsg)
    end try
end run

on reopen
    my logEvent("on reopen fired")
    try
        showFolderMenu()
    on error errMsg number errNum
        my logEvent("reopen: UNCAUGHT ERROR " & errNum & ": " & errMsg)
    end try
end reopen

on checkShouldDismiss:sender
    -- This is an LSUIElement agent app, and testing showed its popup
    -- window never actually becomes "key" in the normal AppKit sense
    -- (isKeyWindow stays false even while it's frontmost and working
    -- fine for clicks) -- so windowDidResignKey: never fires either.
    -- What *does* correctly flip is whether this app is still the
    -- active one, which becomes false the moment the user clicks
    -- another app or the desktop. Poll that instead.
    if not my popupVisible then
        my stopDismissTimer()
        return
    end if

    -- Piggybacked on this same 5x/second timer rather than its own --
    -- one more scheduledTimer here would be one more thing to invalidate
    -- correctly on every dismiss/rebuild path, for no real benefit over
    -- just doing a cheap bit of extra work each existing tick. Wrapped
    -- in its own try so a bug in here can never take the dismiss-check
    -- below down with it.
    try
        my updateVisibleThumbnails()
    end try

    -- A reopen right after being deactivated reads isActive() as false
    -- for a real 1-1.2+ seconds before settling true (measured), so
    -- dismissing on the first false reading would close the popup
    -- before the user ever saw it. Wait until isActive() has been
    -- observed true at least once during this show before trusting a
    -- false reading as a genuine click-away; a later click-away is
    -- then caught within two ticks (0.4s).
    if not my hasSeenActiveThisShow then
        if (current application's NSApp's isActive()) then
            set my hasSeenActiveThisShow to true
        end if
        return
    end if

    if (current application's NSApp's isActive()) then
        set my inactiveStreak to 0
    else
        set my inactiveStreak to (my inactiveStreak) + 1
        if (my inactiveStreak) >= 2 then
            my closePopupWindow:me
        end if
    end if
end checkShouldDismiss:

on stopDismissTimer()
    if my dismissTimer is not missing value then
        (my dismissTimer)'s invalidate()
        set my dismissTimer to missing value
    end if
    set my inactiveStreak to 0
end stopDismissTimer

on closePopupWindow:sender
    my stopDismissTimer()
    if my popupVisible then
        -- Hides rather than closes -- see the property declarations
        -- above for why activeWindow stays alive instead.
        (my activeWindow)'s orderOut:me
        set my popupVisible to false
    end if
end closePopupWindow:

on presentWindow(win, winW)
    -- Shared by a fresh build and by reshowing an unchanged, already-
    -- built popup: position near the mouse (Dock click location),
    -- clamped to stay fully on screen, then bring it to front and
    -- start the dismiss timer.
    set scr to current application's NSScreen's mainScreen()'s frame()
    set scrSize to item 2 of scr
    set scrW to item 1 of scrSize as real
    set mouseLoc to current application's NSEvent's mouseLocation()
    set desiredX to ((mouseLoc's x) as real) - (winW / 2)
    if desiredX < 4 then set desiredX to 4
    if (desiredX + winW) > (scrW - 4) then set desiredX to scrW - winW - 4
    set desiredY to 50
    (win's setFrameOrigin:{desiredX, desiredY})

    -- Always reopen scrolled to the top, whether this is a fresh build
    -- or reshowing an unchanged popup that the user had scrolled down
    -- in before -- a real Dock stack doesn't remember scroll position
    -- either. itemsContainer isn't flipped, so y=0 is its bottom, and
    -- the first item is laid out at the top of its own coordinate
    -- space (see cellY in the build loop below), hence itemsH here
    -- rather than 0.
    if my builtNeedsScroll then
        (my builtItemsContainer)'s scrollPoint:{0, my builtItemsH}
        -- Force the next updateVisibleThumbnails tick to recompute
        -- rather than trust whatever range was visible when this same
        -- popup was last closed (real if it had been scrolled down
        -- before) -- 0/0 can never match a real range, so it always
        -- looks "changed" once.
        set my lastVisibleFirstIndex to 0
        set my lastVisibleLastIndex to 0
    end if

    set my hasSeenActiveThisShow to false
    set my inactiveStreak to 0
    (current application's NSApp's activateIgnoringOtherApps:true)
    (win's makeKeyAndOrderFront:me)
    set my dismissTimer to (current application's NSTimer's scheduledTimerWithTimeInterval:0.2 target:me selector:"checkShouldDismiss:" userInfo:(missing value) repeats:true)
    set my popupVisible to true
end presentWindow

on listCombinedFolder(sourcePaths)
    -- Enumerated via NSFileManager, not AppleScript's "list folder" --
    -- "list folder" returns names in HFS form, where a POSIX ":" in a
    -- filename comes back as "/". A file named "Important:Report.pdf"
    -- would then resolve to a DIFFERENT real file if a folder also
    -- happened to have a matching path -- and every action in this
    -- popup, including Move to Trash, would act on that real file
    -- instead of the one shown. NSFileManager returns real POSIX names
    -- and real POSIX paths directly (via |path|()), so that can't
    -- happen. (This is still the first thing that touches a
    -- TCC-protected folder -- see the activate call in showFolderMenu.)
    --
    -- Takes one or more source folders and merges their contents into
    -- a single listing -- a plain single-folder app is just the
    -- one-source case of the same mechanism. A name that exists in
    -- more than one source folder is kept only once, from whichever
    -- source is listed first; one unreadable source (a removable
    -- volume that isn't mounted, say) doesn't stop the others from
    -- still being listed.
    set fm to current application's NSFileManager's defaultManager()
    set foundNames to {}
    set pathsByName to current application's NSMutableDictionary's dictionary()
    set anySourceReadable to false
    repeat with sp in sourcePaths
        try
            set folderURL to (current application's NSURL's fileURLWithPath:(sp as text) isDirectory:true)
            set contentsURLs to (fm's contentsOfDirectoryAtURL:folderURL includingPropertiesForKeys:{} options:(current application's NSDirectoryEnumerationSkipsHiddenFiles) |error|:(missing value))
            if contentsURLs is not missing value then
                set anySourceReadable to true
                repeat with u in contentsURLs
                    set oneName to ((u's lastPathComponent()) as text)
                    if (pathsByName's objectForKey:oneName) is missing value then
                        set end of foundNames to oneName
                        (pathsByName's setObject:((u's |path|()) as text) forKey:oneName)
                    end if
                end repeat
            end if
        end try
    end repeat
    return {names:foundNames, pathsByName:pathsByName, anyReadable:anySourceReadable}
end listCombinedFolder

on ceilSqrt(n)
    -- Smallest integer i such that i*i >= n. Used to pick a roughly
    -- square grid column count, e.g. ceilSqrt(6) = 3 -> a 3x2 grid.
    set i to 1
    repeat while (i * i) < n
        set i to i + 1
    end repeat
    return i
end ceilSqrt

on cellOriginForIndex(i, columns, cellW, cellH, itemsH)
    -- 1-based index -> {x, y} of that cell's origin in a top-to-bottom,
    -- left-to-right grid. itemsContainer isn't flipped, so row 0 sits
    -- at the top by starting from itemsH and working down.
    set col to ((i - 1) mod columns)
    set rowIdx to ((i - 1) div columns)
    return {col * cellW, itemsH - ((rowIdx + 1) * cellH)}
end cellOriginForIndex

on computeLayout(itemCount)
    -- Lay out the items either as a single-column list or a wrapping grid.
    -- These are real NSButtons in a plain floating window we control
    -- ourselves (not hosted inside an NSMenu) so each one gets its own
    -- left-click (open) and right-click (context menu) behavior -- an
    -- NSMenu's own click-tracking loop does not reliably forward
    -- secondary-click events to a custom view it hosts.
    if my isGridView then
        -- Match macOS's own Dock-stack grid: a roughly square layout
        -- (e.g. 6 items -> 3 wide x 2 high) that widens up to 10 columns
        -- before it would otherwise need more than 7 rows, then scrolls.
        -- This sizing is based on the real items alone.
        set maxCols to 10
        set maxRowsBeforeScroll to 7
        set columns to my ceilSqrt(itemCount)
        if columns > maxCols then set columns to maxCols
        if columns < 1 then set columns to 1
        set rowCount to ((itemCount + columns - 1) div columns)
        repeat while (rowCount > maxRowsBeforeScroll) and (columns < maxCols)
            set columns to columns + 1
            set rowCount to ((itemCount + columns - 1) div columns)
        end repeat
        -- "Open in Finder" is its own trailing slot in this same grid,
        -- not a separate footer bar -- it either falls into whatever
        -- empty cell is left in the last row, or (if the last row was
        -- already full) needs exactly one more row.
        set finderSlotRow to (itemCount div columns)
        if (finderSlotRow + 1) > rowCount then set rowCount to finderSlotRow + 1
        -- Icon/label size and the spacing between cells all follow
        -- Finder's own icon-view settings (View Options > Icon size),
        -- not a fixed guess. Cell width is the icon plus Finder's own
        -- inter-icon grid spacing; height adds extra room on top of
        -- that for the label line itself.
        set iconSize to $grid_icon_size * 1.5
        set labelFontSize to ($grid_text_size - 2) * 1.5
        if labelFontSize < 10 then set labelFontSize to 10
        set gridSpacing to $grid_spacing * 0.5
        set cellW to iconSize + gridSpacing
        set cellH to iconSize + gridSpacing + 20
        set footerH to 0
    else
        set columns to 1
        set rowCount to itemCount
        set cellW to 260
        set cellH to 34
        set iconSize to 26
        set labelFontSize to 14
        set footerH to 28
    end if
    set itemsW to columns * cellW
    set itemsH to rowCount * cellH
    -- Padding around the items area -- a fixed, modest margin rather
    -- than scaling with icon size (which made it excessive at larger
    -- icon sizes).
    set pad to 16
    -- Extra breathing room above the title, between it and the top edge.
    set topPad to 14

    -- Screen height, needed to cap the popup's height (so it never
    -- grows taller than the screen -- long folders scroll instead).
    -- (Screen width is presentWindow()'s own concern, for positioning.)
    set scr to current application's NSScreen's mainScreen()'s frame()
    set scrSize to item 2 of scr
    set scrH to item 2 of scrSize as real

    set headerH to 20
    set maxItemsH to scrH * 0.6
    set needsScroll to (itemsH > maxItemsH)
    if needsScroll then
        set visibleItemsH to maxItemsH
    else
        set visibleItemsH to itemsH
    end if

    set totalW to itemsW + (2 * pad)
    if totalW < 180 then set totalW to 180
    set totalH to topPad + headerH + visibleItemsH + (2 * pad) + footerH

    return {columns:columns, cellW:cellW, cellH:cellH, iconSize:iconSize, labelFontSize:labelFontSize, footerH:footerH, itemsW:itemsW, itemsH:itemsH, pad:pad, topPad:topPad, headerH:headerH, needsScroll:needsScroll, visibleItemsH:visibleItemsH, totalW:totalW, totalH:totalH}
end computeLayout

on buildChrome(layout)
    set totalW to (totalW of layout)
    set totalH to (totalH of layout)
    set pad to (pad of layout)
    set topPad to (topPad of layout)
    set headerH to (headerH of layout)
    set itemsW to (itemsW of layout)
    set itemsH to (itemsH of layout)
    set needsScroll to (needsScroll of layout)
    set visibleItemsH to (visibleItemsH of layout)
    set footerH to (footerH of layout)

    set theWindow to (current application's NSWindow's alloc()'s initWithContentRect:{{0, 0}, {totalW, totalH}} styleMask:0 backing:(current application's NSBackingStoreBuffered) defer:false)
    (theWindow's setLevel:(current application's NSPopUpMenuWindowLevel))
    (theWindow's setOpaque:false)
    (theWindow's setBackgroundColor:(current application's NSColor's clearColor()))
    (theWindow's setHasShadow:true)

    set contentV to theWindow's contentView()

    -- A blurred, rounded native-menu-style background behind everything.
    -- Matches the deep, high-contrast dark panel look of a real Dock
    -- stack popup (hudWindow) rather than a lighter contextual-menu look.
    set bgView to (current application's NSVisualEffectView's alloc()'s initWithFrame:{{0, 0}, {totalW, totalH}})
    (bgView's setMaterial:(current application's NSVisualEffectMaterialHUDWindow))
    (bgView's setState:(current application's NSVisualEffectStateActive))
    (bgView's setWantsLayer:true)
    ((bgView's layer())'s setCornerRadius:16)
    ((bgView's layer())'s setMasksToBounds:true)
    (contentV's addSubview:bgView)

    -- Header (folder name, non-interactive, centered)
    set headerLabel to (current application's NSTextField's alloc()'s initWithFrame:{{pad, totalH - topPad - headerH}, {totalW - (2 * pad), headerH}})
    (headerLabel's setStringValue:"$folder_name_esc")
    (headerLabel's setBezeled:false)
    (headerLabel's setDrawsBackground:false)
    (headerLabel's setEditable:false)
    (headerLabel's setSelectable:false)
    (headerLabel's setFont:(current application's NSFont's systemFontOfSize:13))
    (headerLabel's setAlignment:(current application's NSTextAlignmentCenter))
    ((headerLabel's cell())'s setLineBreakMode:(current application's NSLineBreakByTruncatingTail))
    (contentV's addSubview:headerLabel)

    -- Items are laid out in their own full-height container, which is
    -- either added directly (fits on screen) or hosted in a scroll view
    -- (doesn't fit -- e.g. a folder with dozens of items), the same way
    -- a long NSMenu would scroll.
    set itemsContainer to (current application's NSView's alloc()'s initWithFrame:{{0, 0}, {itemsW, itemsH}})

    set my builtItemsContainer to itemsContainer
    set my builtItemsH to itemsH
    set my builtNeedsScroll to needsScroll

    if needsScroll then
        set itemsScroll to (current application's NSScrollView's alloc()'s initWithFrame:{{pad, footerH + pad}, {itemsW, visibleItemsH}})
        (itemsScroll's setDocumentView:itemsContainer)
        (itemsScroll's setDrawsBackground:false)
        (itemsScroll's setHasVerticalScroller:true)
        (itemsScroll's setAutohidesScrollers:true)
        (contentV's addSubview:itemsScroll)
    else
        (itemsContainer's setFrameOrigin:{pad, footerH + pad})
        (contentV's addSubview:itemsContainer)
    end if

    -- Footer: "Show in Finder" (list view only -- grid view puts this
    -- in the grid itself, as its trailing cell, above.)
    if not my isGridView then
        set finderButton to (current application's NSButton's alloc()'s initWithFrame:{{pad, 4}, {totalW - (2 * pad), footerH - 4}})
        (finderButton's setTitle:"Show in Finder")
        (finderButton's setBordered:false)
        (finderButton's setFont:(current application's NSFont's systemFontOfSize:12))
        (finderButton's setAlignment:(current application's NSTextAlignmentCenter))
        (finderButton's setTarget:me)
        (finderButton's setAction:"showFolderInFinder:")
        (contentV's addSubview:finderButton)
    end if

    -- An invisible button wires the Escape key to closing the popup,
    -- the same as dismissing a menu.
    set escButton to (current application's NSButton's alloc()'s initWithFrame:{{0, 0}, {1, 1}})
    (escButton's setBordered:false)
    (escButton's setTitle:"")
    (escButton's setTarget:me)
    (escButton's setAction:"closePopupWindow:")
    (escButton's setKeyEquivalent:(character id 27))
    (contentV's addSubview:escButton)

    return {theWindow:theWindow, contentV:contentV, itemsContainer:itemsContainer}
end buildChrome

on buildItemView(i, itemCount, aName, itemPath, columns, cellW, cellH, itemsH, iconSize, labelFontSize, ws, itemsContainer, loadRealThumbNow)
    set nsItemMsg to (current application's NSString's stringWithString:"showFolderMenu: processing item ")
    set nsItemMsg to (nsItemMsg's stringByAppendingString:((i as text) as text))
    set nsItemMsg to (nsItemMsg's stringByAppendingString:" of ")
    set nsItemMsg to (nsItemMsg's stringByAppendingString:((itemCount as text) as text))
    set nsItemMsg to (nsItemMsg's stringByAppendingString:": ")
    set nsItemMsg to (nsItemMsg's stringByAppendingString:(current application's NSString's stringWithString:aName))
    my logEvent(nsItemMsg as text)

    -- Display name: strip .app extension for cleaner look.
    -- Done via NSString ("hasSuffix:"/"stringByDeletingPathExtension"),
    -- not AppleScript's native "ends with"/"text X thru Y of": those
    -- run through the same legacy string engine as "&" (see logEvent
    -- above), and this check runs on every single item -- easily 50+
    -- times per click -- making it another realistic contributor to
    -- the same crash.
    set displayName to aName
    set nsAName to (current application's NSString's stringWithString:aName)
    if (nsAName's hasSuffix:".app") then
        set displayName to ((nsAName's stringByDeletingPathExtension()) as text)
    end if

    set {cellX, cellY} to my cellOriginForIndex(i, columns, cellW, cellH, itemsH)

    -- The icon/label are drawn by plain sibling views, not by the
    -- button itself: NSButtonCell's image-above-title layout sizes
    -- the image area from the button's own bounds, not from the
    -- image's actual size, so a deliberately shrunk-down icon just
    -- gets scaled back up to fill that area (confirmed directly:
    -- cell's imageRectForBounds: came back 118x118 for a 64x64
    -- image on a 118-wide button). Nesting them AS the button's own
    -- subviews doesn't work either -- adding subviews to a button
    -- makes AppKit allocate its own internal helper view that can
    -- steal hit-testing from a click landing on a sibling area
    -- (confirmed directly too). So: icon/label as siblings in the
    -- container, then a separate, subview-free, fully transparent
    -- button of the same size layered on top, purely for clicks.
    -- Only genuinely on-screen items get a real thumbnail up front --
    -- everything else gets the cheap generic per-type icon for now and
    -- picks up its real one later, if and when it's actually scrolled
    -- into view (see updateVisibleThumbnails). Building 300+ item views
    -- is fine; decoding 300+ real photos/PDFs before the popup can even
    -- appear is not.
    set gotRealThumb to false
    if loadRealThumbNow then
        set itemIcon to my realThumbnailForPath(itemPath)
        if itemIcon is not missing value then
            my fitImageToSize(itemIcon, iconSize)
            set gotRealThumb to true
        end if
    end if
    if not gotRealThumb then
        set itemIcon to (ws's iconForFile:itemPath)
        (itemIcon's setSize:{width:iconSize, height:iconSize})
    end if

    if my isGridView then
        set iconX to cellX + ((cellW - iconSize) / 2)
        set iconY to cellY + (cellH - iconSize) -- flush with the cell's top
        set labelX to cellX + 2
        set labelW to cellW - 4
        set labelY to cellY + 2
        set labelH to cellH - iconSize - 4
        set labelAlign to (current application's NSTextAlignmentCenter)
    else
        set iconX to cellX + 4
        set iconY to cellY + ((cellH - iconSize) / 2)
        set labelX to cellX + iconSize + 8
        set labelW to cellW - iconSize - 12
        set labelY to cellY + ((cellH - 18) / 2)
        set labelH to 18
        set labelAlign to (current application's NSTextAlignmentLeft)
    end if

    set iconView to (current application's NSImageView's alloc()'s initWithFrame:{{iconX, iconY}, {iconSize, iconSize}})
    (iconView's setImage:itemIcon)
    (iconView's setImageScaling:(current application's NSImageScaleProportionallyUpOrDown))
    (itemsContainer's addSubview:iconView)

    -- Recorded by position (item i of ...), not appended: a failed
    -- item earlier in the loop (caught by showFolderMenu's per-item
    -- try) must not shift every later index out of alignment with
    -- allNames/itemPaths -- both arrays are pre-filled to itemCount
    -- length before the loop starts specifically so this assignment is
    -- always valid.
    set item i of my itemIconViews to iconView
    set item i of my itemHasRealThumb to gotRealThumb
    if gotRealThumb then set end of my loadedThumbOrder to i

    set labelField to (current application's NSTextField's alloc()'s initWithFrame:{{labelX, labelY}, {labelW, labelH}})
    (labelField's setStringValue:displayName)
    (labelField's setBezeled:false)
    (labelField's setDrawsBackground:false)
    (labelField's setEditable:false)
    (labelField's setSelectable:false)
    (labelField's setFont:(current application's NSFont's systemFontOfSize:labelFontSize))
    (labelField's setAlignment:labelAlign)
    -- Truncate long names with an ellipsis instead of wrapping and
    -- overflowing into neighboring cells.
    ((labelField's cell())'s setWraps:false)
    ((labelField's cell())'s setLineBreakMode:(current application's NSLineBreakByTruncatingTail))
    ((labelField's cell())'s setTruncatesLastVisibleLine:true)
    (itemsContainer's addSubview:labelField)

    set theButton to (current application's NSButton's alloc()'s initWithFrame:{{cellX, cellY}, {cellW, cellH}})
    (theButton's setTitle:"")
    (theButton's setBordered:false)
    (theButton's setTarget:me)
    (theButton's setAction:"openItemAtTag:")
    (theButton's setTag:i)

    -- Right-click (secondary click) context menu for this item. AppKit
    -- shows a view's .menu automatically on a secondary click -- no
    -- event-handling code needed for that part, as long as the view
    -- isn't hosted inside another menu's own tracking loop.
    set ctxMenu to (current application's NSMenu's alloc()'s initWithTitle:"")
    set ctxOpen to (current application's NSMenuItem's alloc()'s initWithTitle:"Open" action:"openItemAtTag:" keyEquivalent:"")
    (ctxOpen's setTarget:me)
    (ctxOpen's setTag:i)
    (ctxMenu's addItem:ctxOpen)
    set ctxReveal to (current application's NSMenuItem's alloc()'s initWithTitle:"Show in Finder" action:"revealItemAtTag:" keyEquivalent:"")
    (ctxReveal's setTarget:me)
    (ctxReveal's setTag:i)
    (ctxMenu's addItem:ctxReveal)
    set ctxInfo to (current application's NSMenuItem's alloc()'s initWithTitle:"Get Info" action:"getInfoForItemAtTag:" keyEquivalent:"")
    (ctxInfo's setTarget:me)
    (ctxInfo's setTag:i)
    (ctxMenu's addItem:ctxInfo)
    (ctxMenu's addItem:(current application's NSMenuItem's separatorItem()))
    set ctxDup to (current application's NSMenuItem's alloc()'s initWithTitle:"Duplicate" action:"duplicateItemAtTag:" keyEquivalent:"")
    (ctxDup's setTarget:me)
    (ctxDup's setTag:i)
    (ctxMenu's addItem:ctxDup)
    set ctxTrash to (current application's NSMenuItem's alloc()'s initWithTitle:"Move to Trash" action:"trashItemAtTag:" keyEquivalent:"")
    (ctxTrash's setTarget:me)
    (ctxTrash's setTag:i)
    (ctxMenu's addItem:ctxTrash)
    (theButton's setMenu:ctxMenu)

    (itemsContainer's addSubview:theButton)
end buildItemView

on buildFinderSlotView(itemCount, columns, cellW, cellH, iconSize, itemsH, itemsContainer)
    -- "Open in Finder" is the grid's trailing slot (itemCount + 1), not
    -- a separate footer bar -- icon only, same as macOS's own Dock-stack
    -- grid.
    set i to itemCount + 1
    set {cellX, cellY} to my cellOriginForIndex(i, columns, cellW, cellH, itemsH)

    set finderIcon to missing value
    try
        set finderIcon to (current application's NSImage's imageWithSystemSymbolName:"arrow.up.forward.square" accessibilityDescription:"Open in Finder")
        -- Setting .size on a symbol image doesn't make the glyph
        -- itself bigger (it stays at its default point size, just
        -- with more empty canvas around it) -- a symbol configuration
        -- is what actually controls how large it renders.
        set symConfig to (current application's NSImageSymbolConfiguration's configurationWithPointSize:(iconSize * 0.6) weight:(current application's NSFontWeightRegular))
        set finderIcon to (finderIcon's imageWithSymbolConfiguration:symConfig)
    end try
    if finderIcon is not missing value then
        set finderIconX to cellX + ((cellW - iconSize) / 2)
        set finderIconY to cellY + (cellH - iconSize)
        set finderIconView to (current application's NSImageView's alloc()'s initWithFrame:{{finderIconX, finderIconY}, {iconSize, iconSize}})
        (finderIconView's setImage:finderIcon)
        -- No scaling at all here (unlike the item icons): the symbol
        -- configuration above already chose its exact rendered size
        -- on purpose, so it should be centered as-is, not stretched
        -- to fill this (deliberately larger, for grid alignment) view.
        (finderIconView's setImageScaling:(current application's NSImageScaleNone))
        (finderIconView's setImageAlignment:(current application's NSImageAlignCenter))
        (itemsContainer's addSubview:finderIconView)
    else
        -- No SF Symbols available (older macOS) -- fall back to text.
        set finderLabel to (current application's NSTextField's alloc()'s initWithFrame:{{cellX + 2, cellY + ((cellH - 18) / 2)}, {cellW - 4, 18}})
        (finderLabel's setStringValue:"Open in Finder")
        (finderLabel's setBezeled:false)
        (finderLabel's setDrawsBackground:false)
        (finderLabel's setEditable:false)
        (finderLabel's setSelectable:false)
        (finderLabel's setFont:(current application's NSFont's systemFontOfSize:11))
        (finderLabel's setAlignment:(current application's NSTextAlignmentCenter))
        (itemsContainer's addSubview:finderLabel)
    end if

    -- Plain, subview-free button on top purely for clicks -- see the
    -- note in buildItemView() for why it can't host the icon view
    -- itself as a subview.
    set gridFinderButton to (current application's NSButton's alloc()'s initWithFrame:{{cellX, cellY}, {cellW, cellH}})
    (gridFinderButton's setBordered:false)
    (gridFinderButton's setTitle:"")
    (gridFinderButton's setTarget:me)
    (gridFinderButton's setAction:"showFolderInFinder:")
    (itemsContainer's addSubview:gridFinderButton)
end buildFinderSlotView

on fitImageToSize(img, targetSize)
    -- A real photo's native pixel size has nothing to do with our
    -- chosen icon size, unlike the generic per-type icons (already
    -- explicitly sized) -- scale it down to fit within targetSize on
    -- its longer edge, preserving aspect ratio, so it actually honors
    -- the same icon size everything else uses. img is already a small,
    -- resampled thumbnail (see resampleToSquare) by the time this runs,
    -- so this is a cheap cosmetic resize, not a memory concern.
    set nativeSize to img's |size|()
    set nw to (nativeSize's width) as real
    set nh to (nativeSize's height) as real
    if nw > 0 and nh > 0 then
        set scale to targetSize / nw
        set scaleH to targetSize / nh
        if scaleH < scale then set scale to scaleH
        (img's setSize:{width:(nw * scale), height:(nh * scale)})
    end if
end fitImageToSize

on resampleToSquare(img, targetSize)
    -- Draws img -- at whatever its native size is -- into a freshly
    -- allocated small bitmap, scaled to fit within targetSize x
    -- targetSize (preserving aspect ratio, centered). This is a real
    -- resample, not the cosmetic setSize: in fitImageToSize above: the
    -- returned image's actual pixel data is small, so the caller can
    -- drop a huge original right after this returns and only the small
    -- bitmap stays resident -- the difference between one photo costing
    -- a few hundred KB in memory versus tens of megabytes.
    set nativeSize to img's |size|()
    set nw to (nativeSize's width) as real
    set nh to (nativeSize's height) as real
    if nw <= 0 or nh <= 0 then return missing value
    set scale to targetSize / nw
    set scaleH to targetSize / nh
    if scaleH < scale then set scale to scaleH
    set dw to nw * scale
    set dh to nh * scale
    set dx to (targetSize - dw) / 2
    set dy to (targetSize - dh) / 2

    set smallRep to (current application's NSBitmapImageRep's alloc()'s initWithBitmapDataPlanes:(missing value) pixelsWide:targetSize pixelsHigh:targetSize bitsPerSample:8 samplesPerPixel:4 hasAlpha:true isPlanar:false colorSpaceName:(current application's NSCalibratedRGBColorSpace) bytesPerRow:0 bitsPerPixel:0)
    set smallCtx to (current application's NSGraphicsContext's graphicsContextWithBitmapImageRep:smallRep)
    current application's NSGraphicsContext's setCurrentContext:smallCtx
    img's drawInRect:{origin:{x:dx, y:dy}, |size|:{width:dw, height:dh}}
    current application's NSGraphicsContext's setCurrentContext:(missing value)

    set smallImg to (current application's NSImage's alloc()'s initWithSize:{width:targetSize, height:targetSize})
    smallImg's addRepresentation:smallRep
    return smallImg
end resampleToSquare

on thumbCacheFileForPath(p)
    -- Cache key: the full path (so two same-named files in different
    -- folders don't collide), sanitized, plus the file's modification
    -- time and size (so an edited file gets a fresh entry instead of
    -- serving a stale thumbnail -- the old entry is simply never
    -- touched again, not actively pruned). missing value means "don't
    -- cache this one" (attributes unavailable), not an error -- the
    -- caller just skips the cache and falls through to generating it
    -- fresh.
    --
    -- Deliberately NOT NSString's hash(): that returns a 64-bit
    -- NSUInteger, and AppleScript can only hold a value that large as
    -- a double once it crosses back from Objective-C -- confirmed
    -- directly, the precision loss happens the moment the raw hash is
    -- read into a plain variable, not just when formatting it
    -- afterward, silently truncating it to a handful of significant
    -- digits and defeating the entire point of hashing for collision
    -- avoidance (it broke item processing outright in testing: two
    -- items landing on the same truncated "hash" trips the later
    -- write's "already exists"/permissions edge cases). The sanitized
    -- full path has no such ceiling.
    set fm to current application's NSFileManager's defaultManager()
    set attrs to (fm's attributesOfItemAtPath:p |error|:(missing value))
    if attrs is missing value then return missing value
    set modDate to (attrs's objectForKey:(current application's NSFileModificationDate))
    set fileSizeNum to (attrs's objectForKey:(current application's NSFileSize))
    if modDate is missing value or fileSizeNum is missing value then return missing value
    set modEpoch to ((modDate's timeIntervalSince1970()) as integer)
    set fileSizeInt to (fileSizeNum as integer)

    set nsPath to (current application's NSString's stringWithString:p)
    set sanitized to (nsPath's stringByReplacingOccurrencesOfString:"/" withString:"_") as text
    -- A very deep path could exceed the filesystem's per-component name
    -- limit once the mtime/size suffix is added -- keep just the tail
    -- (the filename and its closest parents, the most distinguishing
    -- part) if so.
    if (length of sanitized) > 150 then
        set sanitized to (text -150 thru -1 of sanitized)
    end if
    set cacheFileName to sanitized & "-" & modEpoch & "-" & fileSizeInt & ".png"
    return (my thumbCacheDir) & "/" & cacheFileName
end thumbCacheFileForPath

on realThumbnailForPath(p)
    -- NSWorkspace's iconForFile: mostly returns the generic per-type
    -- icon (with a small extension badge), not a real content preview
    -- the way Finder's own icon view renders one -- load the real
    -- content directly for the types where that matters visually.
    --
    -- Always generated/cached at the one fixed thumbCacheSize
    -- (independent of the caller's requested display size, list vs.
    -- grid) so the same on-disk thumbnail is reused across both views
    -- instead of keeping a separate cache entry per view; fitImageToSize
    -- at the call site handles the (cheap, since this is already small)
    -- cosmetic fit down to whatever size is actually being displayed.
    set cacheFile to my thumbCacheFileForPath(p)

    if cacheFile is not missing value then
        set fm to current application's NSFileManager's defaultManager()
        if (fm's fileExistsAtPath:cacheFile) then
            try
                set cachedURL to (current application's NSURL's fileURLWithPath:cacheFile)
                set cachedImg to (current application's NSImage's alloc()'s initWithContentsOfURL:cachedURL)
                if cachedImg is not missing value then return cachedImg
            end try
        end if
    end if

    set fileURL to current application's NSURL's fileURLWithPath:p
    set ext to ((fileURL's pathExtension())'s lowercaseString()) as text
    set imageExts to {"png", "jpg", "jpeg", "gif", "tiff", "tif", "heic", "heif", "bmp", "webp"}
    set rawImg to missing value

    if imageExts contains ext then
        try
            -- Skip decoding unusually large images synchronously on the
            -- main thread -- a very high-resolution photo can take long
            -- enough to look like (or plausibly contribute to) a hang,
            -- for a plain file-type icon most people wouldn't notice
            -- was generic instead of a real preview.
            set fm to current application's NSFileManager's defaultManager()
            set attrs to (fm's attributesOfItemAtPath:p |error|:(missing value))
            set fileSize to 0
            if attrs is not missing value then
                set fileSizeNum to (attrs's objectForKey:(current application's NSFileSize))
                if fileSizeNum is not missing value then set fileSize to (fileSizeNum as integer)
            end if
            if fileSize < 20000000 then
                set rawImg to (current application's NSImage's alloc()'s initWithContentsOfURL:fileURL)
            end if
        end try
    else if ext is "pdf" then
        try
            set pdfDoc to (current application's PDFDocument's alloc()'s initWithURL:fileURL)
            if pdfDoc is not missing value then
                if (pdfDoc's pageCount()) > 0 then
                    set pdfPage to (pdfDoc's pageAtIndex:0)
                    if pdfPage is not missing value then
                        set rawImg to (pdfPage's thumbnailOfSize:{width:(my thumbCacheSize), height:(my thumbCacheSize)} forBox:(current application's kPDFDisplayBoxCropBox))
                    end if
                end if
            end if
        end try
    end if

    if rawImg is missing value then return missing value

    -- The real fix: resample down to the fixed cache size right away,
    -- then drop rawImg -- so a 12MP photo's full decode is a brief,
    -- transient allocation freed within this handler, not something
    -- that stays resident for as long as the app keeps running (which
    -- is indefinitely -- see the note on activeWindow near the top of
    -- this file).
    set smallImg to my resampleToSquare(rawImg, my thumbCacheSize)
    set rawImg to missing value
    if smallImg is missing value then return missing value

    if cacheFile is not missing value then
        try
            set smallRepForSave to ((smallImg's representations())'s firstObject())
            set pngData to (smallRepForSave's representationUsingType:4 |properties|:(missing value))
            if pngData is not missing value then
                (pngData's writeToFile:cacheFile atomically:true)
            end if
        end try
    end if

    return smallImg
end realThumbnailForPath

on updateVisibleThumbnails()
    -- Nothing to do for a popup that fits on screen without scrolling
    -- -- every item was loaded with a real thumbnail up front in that
    -- case (see the initialVisibleCount note in showFolderMenu), since
    -- everything really is visible at once and there's no off-screen
    -- set to defer.
    if not my builtNeedsScroll then return
    if my builtItemsContainer is missing value then return
    set totalItems to (count of my itemIconViews)
    if totalItems is 0 then return

    set visRect to (my builtItemsContainer)'s visibleRect()
    set visOrigin to item 1 of visRect
    set visSize to item 2 of visRect
    set visY to (item 2 of visOrigin) as real
    set visH to (item 2 of visSize) as real

    set itemsHVal to my currentItemsH
    set cellHVal to my currentCellH
    set columnsVal to my currentColumns
    if cellHVal <= 0 or columnsVal < 1 then return

    -- itemsContainer isn't flipped -- row 0 (the first items) sits at
    -- the top, i.e. the highest y (see cellOriginForIndex) -- so a
    -- larger y is an earlier row, and the visible rect's top edge
    -- (visY + visH) is where the first visible row is.
    set topY to visY + visH
    set bottomY to visY
    set firstRow to ((itemsHVal - topY) / cellHVal) as integer
    if firstRow < 0 then set firstRow to 0
    set lastRow to ((itemsHVal - bottomY) / cellHVal) as integer
    set maxRow to ((totalItems - 1) div columnsVal)
    if lastRow > maxRow then set lastRow to maxRow
    if lastRow < firstRow then set lastRow to firstRow

    set firstIdx to (firstRow * columnsVal) + 1
    set lastIdx to ((lastRow + 1) * columnsVal)
    if lastIdx > totalItems then set lastIdx to totalItems
    if firstIdx < 1 then set firstIdx to 1

    -- Same range as last tick (nothing scrolled) -- nothing to do.
    -- Cheap early-out so an idle, unscrolled popup does no real work on
    -- the other 4 out of 5 ticks a second.
    if firstIdx = (my lastVisibleFirstIndex) and lastIdx = (my lastVisibleLastIndex) then
        return
    end if
    set my lastVisibleFirstIndex to firstIdx
    set my lastVisibleLastIndex to lastIdx

    -- Load a real thumbnail for anything newly visible that's still
    -- showing its generic-icon placeholder. A cache hit (the common
    -- case for anything seen before, in this show or a past one) is
    -- just reading back a small PNG, so this stays fast even though
    -- it's running on the main thread mid-scroll.
    repeat with idx from firstIdx to lastIdx
        if (item idx of my itemHasRealThumb) is false then
            set targetView to (item idx of my itemIconViews)
            if targetView is not missing value then
                set itemPath to (item idx of my itemPaths)
                set realImg to my realThumbnailForPath(itemPath)
                if realImg is not missing value then
                    my fitImageToSize(realImg, my currentIconSize)
                    (targetView's setImage:realImg)
                    set item idx of my itemHasRealThumb to true
                    set end of my loadedThumbOrder to idx
                end if
            end if
        end if
    end repeat

    -- Evict the least-recently-visible real thumbnails once over
    -- budget, swapping each back to the cheap generic icon -- but never
    -- anything in the current visible range, regardless of budget.
    --
    -- A single front-to-back pass, not a pop-the-front-and-give-up-on-
    -- the-first-still-visible-one loop: that first approach looked
    -- correct but wasn't -- a re-queued visible entry goes to the back,
    -- so the front can end up occupied by another visible entry (one
    -- that was re-queued on an earlier tick) while genuinely stale
    -- entries sit further back in the same queue, and bailing out at
    -- that first non-evictable front entry left those later, actually-
    -- evictable ones untouched (confirmed directly in testing: items
    -- scrolled fully out of view stayed loaded indefinitely once this
    -- happened, defeating the whole cap). Evicting the oldest
    -- evictable entries wherever they fall in the queue, in one pass,
    -- doesn't have that blind spot.
    set stillNeeded to (count of my loadedThumbOrder) - (my maxLoadedThumbnails)
    if stillNeeded > 0 then
        set keptOrder to {}
        repeat with idx in (my loadedThumbOrder)
            set idx to idx as integer
            if stillNeeded > 0 and (idx < firstIdx or idx > lastIdx) then
                if (item idx of my itemHasRealThumb) is true then
                    set targetView to (item idx of my itemIconViews)
                    if targetView is not missing value then
                        set itemPath to (item idx of my itemPaths)
                        set placeholderWs to current application's NSWorkspace's sharedWorkspace()
                        set placeholderImg to (placeholderWs's iconForFile:itemPath)
                        (placeholderImg's setSize:{width:(my currentIconSize), height:(my currentIconSize)})
                        (targetView's setImage:placeholderImg)
                        set item idx of my itemHasRealThumb to false
                    end if
                end if
                set stillNeeded to stillNeeded - 1
            else
                set end of keptOrder to idx
            end if
        end repeat
        set my loadedThumbOrder to keptOrder
    end if
end updateVisibleThumbnails

on showFolderMenu()
    -- Reentrancy guard: a "reopen" arriving while a previous call is
    -- still mid-flight (a real risk -- the forced contentV's display()
    -- below pumps the run loop, which can let an already-queued reopen
    -- dispatch back into this same handler before the first call
    -- returns) mutates shared properties like itemPaths/activeWindow
    -- out from under the in-progress call. Confirmed as a real, if rare,
    -- crash under rapid repeated triggering; bailing out immediately
    -- instead of proceeding is far cheaper than making every line below
    -- safe under concurrent mutation.
    if my isBuildingMenu then
        my logEvent("showFolderMenu: already in progress, ignoring reentrant call")
        return
    end if
    set my isBuildingMenu to true

    -- A click while the popup is already showing toggles it closed --
    -- matching a real Dock stack. Just hides it (see closePopupWindow:)
    -- rather than destroying anything, so activeWindow and its whole
    -- view hierarchy survive for the next open to reuse.
    if my popupVisible then
        -- Wrapped in its own try: isBuildingMenu must be reset no
        -- matter what happens in here. An error that escapes this
        -- handler entirely is caught only by the outer "on run"/
        -- "on reopen" handler, which has no idea this flag exists --
        -- leaving it stuck true would silently lock up every future
        -- click ("already in progress") until the app is relaunched.
        try
            my closePopupWindow:me
            my logEvent("showFolderMenu: popup was already open, closed it")
        on error errMsg number errNum
            my logEvent("showFolderMenu: error while closing: " & errNum & ": " & errMsg)
        end try
        set my isBuildingMenu to false
        return
    end if

    my stopDismissTimer()

    -- Directly pinpointed via logging: a real reopen-after-click-away
    -- hangs specifically inside "list folder" below, which is the first
    -- thing that touches the TCC-protected Desktop/Documents/Downloads
    -- folder -- and this happens before AppKit has ever been told this
    -- app wants to be the foreground app. Activating first, before any
    -- TCC-gated access, removes that ambiguity up front rather than
    -- leaving the permission check to resolve it mid-call.
    (current application's NSApp's activateIgnoringOtherApps:true)

    -- currentFolderPath is the first source folder -- used for "Show in
    -- Finder" (the footer button / grid's trailing slot) and in error
    -- messages. A combined app's individual items still resolve to
    -- their own real source folder regardless (see itemPaths below);
    -- this is only the one general "reveal the source" fallback.
    set my currentFolderPath to (item 1 of my sourceFolderPaths)

    my logEvent("showFolderMenu: listing " & (count of my sourceFolderPaths) & " source folder(s)")
    set listing to my listCombinedFolder(my sourceFolderPaths)
    if not (anyReadable of listing) then
        my logEvent("showFolderMenu: listing FAILED")
        display dialog "Cannot read folder: " & (my currentFolderPath) buttons {"OK"} default button "OK" with icon caution
        set my isBuildingMenu to false
        return
    end if
    set allNames to (names of listing)
    set pathsByName to (pathsByName of listing)

    -- Sort names alphabetically (A-Z, case-insensitive) using Cocoa
    set cocoaArray to current application's NSMutableArray's arrayWithArray:allNames
    cocoaArray's sortUsingSelector:"localizedCaseInsensitiveCompare:"
    set allNames to cocoaArray as list

    if (count of allNames) is 0 then
        display dialog "Folder is empty." buttons {"OK"} default button "OK"
        set my isBuildingMenu to false
        return
    end if

    -- If a window already exists and the folder's contents haven't
    -- changed since it was built, just reshow that exact window --
    -- same items, same icons, same menus, nothing rebuilt (see the
    -- property declarations above for why that matters).
    set contentUnchanged to false
    if my activeWindow is not missing value then
        try
            if allNames = my lastItemNames then set contentUnchanged to true
        end try
    end if

    if contentUnchanged then
        my logEvent("showFolderMenu: contents unchanged, reusing existing popup")
        my presentWindow(my activeWindow, my builtTotalW)
        ((my activeWindow)'s contentView())'s display()
        set my isBuildingMenu to false
        return
    end if

    -- Contents changed (or this is the first time) -- if an old
    -- window from previous contents is still around, it has to go
    -- before building its replacement.
    if my activeWindow is not missing value then
        (my activeWindow)'s |close|()
        set my activeWindow to missing value
        set my popupVisible to false
    end if

    my logEvent("showFolderMenu: building popup for " & (count of allNames) & " item(s)")
    try
    set itemCount to count of allNames
    set my itemPaths to {}
    repeat with aName in allNames
        -- The real path came directly from listCombinedFolder's own
        -- enumeration (see the note there), not rebuilt by joining a
        -- single folder path with the name -- there's no longer one
        -- single folder to join against, now that a name can have come
        -- from any of sourceFolderPaths.
        set end of my itemPaths to ((pathsByName's objectForKey:aName) as text)
    end repeat

    -- Reset lazy-thumbnail-loading state for this (re)build. The two
    -- tracking arrays are pre-filled to itemCount length up front, not
    -- appended to as the item loop runs, so buildItemView can always
    -- write to "item i of ..." even if an earlier item in the loop
    -- failed and was skipped -- see the note there for why that
    -- matters. missing value / false are safe placeholders: nothing
    -- reads them for an index whose view was never actually built.
    set my itemIconViews to {}
    set my itemHasRealThumb to {}
    repeat itemCount times
        set end of my itemIconViews to missing value
        set end of my itemHasRealThumb to false
    end repeat
    set my loadedThumbOrder to {}
    set my lastVisibleFirstIndex to 0
    set my lastVisibleLastIndex to 0

    set ws to current application's NSWorkspace's sharedWorkspace()

    set layout to my computeLayout(itemCount)
    set columns to (columns of layout)
    set cellW to (cellW of layout)
    set cellH to (cellH of layout)
    set iconSize to (iconSize of layout)
    set labelFontSize to (labelFontSize of layout)
    set itemsH to (itemsH of layout)
    set totalW to (totalW of layout)
    set my currentColumns to columns
    set my currentCellH to cellH
    set my currentItemsH to itemsH
    set my currentIconSize to iconSize

    -- Only the items that will actually be visible the moment this
    -- popup appears get a real thumbnail loaded synchronously in the
    -- build loop below -- everything else starts with the cheap
    -- generic icon and picks up its real one lazily, on scroll (see
    -- updateVisibleThumbnails). A popup that fits without scrolling has
    -- no off-screen items to defer, so everything loads now, same as
    -- before this existed. +1 row over the strict fit is a small,
    -- fixed prefetch margin -- covers the sliver of a partially-visible
    -- row at the bottom of the viewport, not a general scroll buffer.
    if (needsScroll of layout) then
        set visRows to (((visibleItemsH of layout) / cellH) as integer) + 1
        set initialVisibleCount to columns * visRows
        if initialVisibleCount > itemCount then set initialVisibleCount to itemCount
    else
        set initialVisibleCount to itemCount
    end if

    set chrome to my buildChrome(layout)
    set theWindow to (theWindow of chrome)
    set contentV to (contentV of chrome)
    set itemsContainer to (itemsContainer of chrome)

    -- Show the window now, before the (potentially slow -- real photo/PDF
    -- thumbnails) item loop below runs, so the popup appears immediately
    -- and icons fill in a moment later, rather than nothing appearing at
    -- all until every icon is ready.
    set my activeWindow to theWindow
    set my builtTotalW to totalW
    my presentWindow(theWindow, totalW)
    -- makeKeyAndOrderFront: (inside presentWindow) only schedules the
    -- window to be shown -- on this single-threaded app, it wouldn't
    -- actually get painted until control returns to the run loop, which
    -- won't happen until the item loop below finishes. Force a
    -- synchronous paint now, so the (empty) window shell genuinely
    -- appears on screen before that loop runs.
    contentV's display()

    repeat with i from 1 to itemCount
      try
        set aName to (item i of allNames) as text
        set itemPath to (item i of my itemPaths)
        set loadNow to (i <= initialVisibleCount)
        my buildItemView(i, itemCount, aName, itemPath, columns, cellW, cellH, itemsH, iconSize, labelFontSize, ws, itemsContainer, loadNow)
      on error errMsg number errNum
        my logEvent("showFolderMenu: item at index " & i & " failed, skipping: " & errNum & ": " & errMsg)
      end try
    end repeat

    if my isGridView then
        my buildFinderSlotView(itemCount, columns, cellW, cellH, iconSize, itemsH, itemsContainer)
    end if
    set my lastItemNames to allNames
    my logEvent("showFolderMenu: popup shown successfully")
    set my isBuildingMenu to false
    on error errMsg number errNum
        set my isBuildingMenu to false
        my logEvent("showFolderMenu: UNCAUGHT ERROR " & errNum & ": " & errMsg)
        try
            display dialog "Dock Folders hit an unexpected error showing this folder:" & return & return & errMsg & return & return & "(error " & errNum & ") -- see ~/Library/Application Support/dock-folders/debug.log for details." buttons {"OK"} default button "OK" with icon caution
        end try
    end try

end showFolderMenu

on openItemAtTag:sender
    try
        set idx to (sender's tag()) as integer
        set p to item idx of my itemPaths
        (current application's NSWorkspace's sharedWorkspace()'s openURL:(current application's NSURL's fileURLWithPath:p))
    on error errMsg number errNum
        my logEvent("openItemAtTag: failed: " & errNum & ": " & errMsg)
    end try
    my closePopupWindow:me
end openItemAtTag:

on revealItemAtTag:sender
    try
        set idx to (sender's tag()) as integer
        set p to item idx of my itemPaths
        (current application's NSWorkspace's sharedWorkspace()'s selectFile:p inFileViewerRootedAtPath:"")
    on error errMsg number errNum
        my logEvent("revealItemAtTag: failed: " & errNum & ": " & errMsg)
    end try
    my closePopupWindow:me
end revealItemAtTag:

on getInfoForItemAtTag:sender
    -- The only way to show the real Finder "Get Info" panel is to ask
    -- Finder for it, which needs one-time Automation permission for
    -- Finder (only requested the first time this menu item is used).
    try
        set idx to (sender's tag()) as integer
        set p to item idx of my itemPaths
        tell application "Finder" to open information window of (POSIX file p as alias)
    on error errMsg number errNum
        my logEvent("getInfoForItemAtTag: failed: " & errNum & ": " & errMsg)
    end try
    my closePopupWindow:me
end getInfoForItemAtTag:

on duplicateItemAtTag:sender
    try
        set idx to (sender's tag()) as integer
        set p to item idx of my itemPaths
        set fm to current application's NSFileManager's defaultManager()
        set baseURL to current application's NSURL's fileURLWithPath:p
        set dirURL to baseURL's URLByDeletingLastPathComponent()
        set nameNoExt to (baseURL's URLByDeletingPathExtension())'s lastPathComponent() as text
        set ext to baseURL's pathExtension() as text

        set n to 2
        set candidateName to nameNoExt & " copy"
        if ext is not "" then set candidateName to candidateName & "." & ext
        set candidateURL to (dirURL's URLByAppendingPathComponent:candidateName)
        repeat while (fm's fileExistsAtPath:(candidateURL's |path|())) as boolean
            set candidateName to nameNoExt & " copy " & n
            if ext is not "" then set candidateName to candidateName & "." & ext
            set candidateURL to (dirURL's URLByAppendingPathComponent:candidateName)
            set n to n + 1
        end repeat

        set didCopy to (fm's copyItemAtURL:baseURL toURL:candidateURL |error|:(missing value)) as boolean
        if not didCopy then
            my logEvent("duplicateItemAtTag: copyItemAtURL failed for " & p)
            display dialog "Couldn't duplicate that item." buttons {"OK"} default button "OK" with icon caution
        end if
    on error errMsg number errNum
        my logEvent("duplicateItemAtTag: failed: " & errNum & ": " & errMsg)
    end try
    my closePopupWindow:me
end duplicateItemAtTag:

on trashItemAtTag:sender
    try
        set idx to (sender's tag()) as integer
        set p to item idx of my itemPaths
        set fm to current application's NSFileManager's defaultManager()
        set didTrash to (fm's trashItemAtURL:(current application's NSURL's fileURLWithPath:p) resultingItemURL:(missing value) |error|:(missing value)) as boolean
        if not didTrash then
            my logEvent("trashItemAtTag: trashItemAtURL failed for " & p)
            display dialog "Couldn't move that item to the Trash." buttons {"OK"} default button "OK" with icon caution
        end if
    on error errMsg number errNum
        my logEvent("trashItemAtTag: failed: " & errNum & ": " & errMsg)
    end try
    my closePopupWindow:me
end trashItemAtTag:

on showFolderInFinder:sender
    try
        (current application's NSWorkspace's sharedWorkspace()'s openURL:(current application's NSURL's fileURLWithPath:(my currentFolderPath)))
    on error errMsg number errNum
        my logEvent("showFolderInFinder: failed: " & errNum & ": " & errMsg)
    end try
    my closePopupWindow:me
end showFolderInFinder:
APPLESCRIPT
}

# ─── Main loop ───────────────────────────────────────────────────────────────────
echo "🗂  Dock Folders Generator"
echo "   Output: $OUTPUT_DIR"
echo ""

for spec in "${APP_SPECS[@]}"; do
    # Each spec is "NAME<TAB>path1,path2,..." -- already resolved to
    # absolute, real paths when APP_SPECS was built above, so there's
    # nothing left to validate here regardless of whether this is a
    # plain single folder or a --combine group.
    IFS=$'\t' read -r folder_name folder_paths_csv <<< "$spec"
    # First path only: what a combined app's icon and (if extraction
    # fails) fallback default should come from -- there's no single real
    # folder to derive one from otherwise.
    icon_source_path="${folder_paths_csv%%,*}"

    app_name="${folder_name}.app"
    app_path="$OUTPUT_DIR/$app_name"

    echo "📁 Processing: $folder_name"

    # If a previous build of this app is still running (it's a stay-open
    # agent, so clicking its Dock icon again just sends the *existing*
    # process a reopen event instead of launching the freshly rebuilt
    # binary), kill it so the next launch picks up what we're about to build.
    if [[ -d "$app_path" ]]; then
        app_exe_prefix="$app_path/Contents/MacOS/"
        killed_stale=false
        while read -r pid cmd; do
            if [[ "$cmd" == "$app_exe_prefix"* ]]; then
                kill "$pid" 2>/dev/null || true
                killed_stale=true
            fi
        done < <(ps -eo pid=,args=)
        # Give the Dock/LaunchServices a moment to fully register the kill
        # before we rebuild and relaunch at the same path -- interacting
        # with the old process's Dock tile right as it's being torn down
        # (e.g. clicking it during this exact rebuild) is a plausible way
        # to hit a stray system-level error unrelated to this app's own
        # logic.
        if $killed_stale; then
            sleep 0.5
        fi
    fi

    # Everything from here on is built in a private temporary directory
    # first, and only moved into $OUTPUT_DIR once finished and signed.
    # Building directly inside $OUTPUT_DIR (the old approach) left a
    # real window -- a freshly-written .applescript source file, then a
    # partially-built, not-yet-signed .app sitting at the final path --
    # that anyone else able to write to that directory (it doesn't have
    # to be ours; --output-dir can point anywhere) could race or
    # symlink-swap during. mktemp's directory is private (mode 700,
    # owned by us) regardless of what $OUTPUT_DIR's own permissions
    # turn out to be.
    build_dir="$(mktemp -d "${TMPDIR:-/tmp}/dock-folders-build.XXXXXX")"
    trap 'rm -rf "$build_dir"' EXIT

    # Follow Finder's own icon-view settings (View Options > Icon size),
    # the same ones used for every regular Finder window -- not the
    # Desktop's own separate, larger default (96pt), which read as too big.
    grid_icon_size="$(finder_icon_view_setting "FK_StandardViewSettings" "iconSize" 64)"
    grid_text_size="$(finder_icon_view_setting "FK_StandardViewSettings" "textSize" 12)"
    grid_spacing="$(finder_icon_view_setting "FK_StandardViewSettings" "gridSpacing" 54)"

    # 1. Generate AppleScript source
    tmp_script="$build_dir/app.applescript"
    generate_applescript "$folder_paths_csv" "$folder_name" "$IS_GRID_LITERAL" "$grid_icon_size" "$grid_text_size" "$grid_spacing" "$PREWARM_SUPPORT_DIR/debug.log" "$THUMB_CACHE_DIR" > "$tmp_script"

    # 2. Compile to .app bundle (stay-open so it handles reopen events)
    echo "  ⚙ Compiling app..."
    build_app_path="$build_dir/$app_name"
    osacompile -s -o "$build_app_path" "$tmp_script" 2>/dev/null

    # 3. Extract and set custom icon
    echo "  🎨 Extracting folder icon..."
    tmp_icns="$build_dir/icon.icns"

    if create_icns "$icon_source_path" "$tmp_icns"; then
        cp "$tmp_icns" "$build_app_path/Contents/Resources/applet.icns"
        # Remove the asset catalog — it contains the default applet icon and
        # takes precedence over applet.icns on modern macOS
        rm -f "$build_app_path/Contents/Resources/Assets.car"
        echo "  ✅ Icon applied"
    else
        echo "  ⚠ Could not extract icon, using system default"
    fi

    # 4. Update Info.plist with a proper bundle identifier
    bundle_id="com.dock-folders.$(printf '%s' "$folder_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$build_app_path/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$build_app_path/Contents/Info.plist" 2>/dev/null

    # Set a proper display name
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $folder_name" "$build_app_path/Contents/Info.plist" 2>/dev/null

    # Hide from CMD+Tab app switcher (agent app — no Dock bounce, no menu bar)
    /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$build_app_path/Contents/Info.plist" 2>/dev/null || true

    # Add usage descriptions so macOS can prompt for permissions
    /usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string This app needs permission to show folder contents." "$build_app_path/Contents/Info.plist" 2>/dev/null || true

    # 5. Ad-hoc code-sign so macOS TCC can track the app's identity
    #    Without signing, TCC silently blocks access to ~/Documents, ~/Desktop, etc.
    echo "  🔏 Code-signing..."
    xattr -cr "$build_app_path" 2>/dev/null
    codesign --force --sign - "$build_app_path" 2>&1 || echo "  ⚠ Code-signing failed (non-fatal)"

    # 6. Only now -- fully built and signed -- replace any previous
    #    build (already stopped, above) and move it into place. Nothing
    #    half-built or swappable was ever visible outside $build_dir.
    if [[ -d "$app_path" ]]; then
        rm -rf "$app_path"
    fi
    mv "$build_app_path" "$app_path"
    rm -rf "$build_dir"
    trap - EXIT

    # Touch to refresh icon cache
    touch "$app_path"

    # 7. Silently launch it now (no window shown -- see the app's own
    #    "on run" handler) so it's already a warm, running process by the
    #    time it's actually clicked. Without this, every click has to pay
    #    for a full cold start (process launch, loading AppKit/PDFKit)
    #    on top of the popup's own (much smaller) setup cost.
    echo "  🔥 Warming up..."
    open --env DOCK_FOLDERS_PREWARM=1 -g "$app_path" 2>/dev/null || true
    record_prewarmed_app "$app_path"

    echo "  ✅ Created: $app_path"
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done! Drag the .app files from '$OUTPUT_DIR' into your Dock."
echo ""
echo "💡 First launch: if the folder is in ~/Documents, ~/Desktop,"
echo "   or ~/Downloads, macOS may ask for permission — click Allow."
echo ""
echo "🔁 A per-user login item (LaunchAgent \"$PREWARM_AGENT_LABEL\") now"
echo "   silently re-warms every app this script has generated each time"
echo "   you log in, so the first click of a session is fast too:"
echo "   $PREWARM_AGENT_PLIST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

