#!/bin/sh
# Builds the panels off-screen and writes PNGs, from the windows on this Space into $1.
# --readme instead opens fixture windows in fresh copies of stock apps, renders only those over
# stock wallpapers in light and dark, and writes the README images to docs/images.
cd "$(dirname "$0")/.." || exit 1
swift build 2>&1 | grep -E 'error' && exit 1

render() {
    .build/debug/mFix --render "$1" &
    pid=$!
    i=0
    while [ $i -lt 40 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i+1)); done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "render check timed out"; return 1; fi
    wait "$pid"
}

if [ "$1" != "--readme" ]; then
    OUT="${1:-$HOME/scratch/mfix-render}"
    mkdir -p "$OUT"
    render "$OUT"
    exit $?
fi

command -v ffmpeg >/dev/null || { echo "--readme needs ffmpeg for the stock wallpapers"; exit 1; }
WORK=$(mktemp -d)
mkdir -p "$WORK/out" docs/images
PIDS=""
cleanup() {
    for p in $(echo "$PIDS" | tr , ' '); do kill "$p" 2>/dev/null; done
    PIDS=""
}
trap 'cleanup; rm -rf "$WORK"' EXIT

WALL="/System/Library/Desktop Pictures/.wallpapers"
ffmpeg -v error -y -i "$WALL/Tahoe Day/Tahoe Day.mov" -frames:v 1 "$WORK/wall-light.png" || exit 1
ffmpeg -v error -y -ss 5 -i "$WALL/Sonoma/Sonoma Graphic Dark Landscape.mov" -frames:v 1 "$WORK/wall-dark.png" || exit 1
sips --resampleWidth 1600 "$WORK/wall-light.png" --out "$WORK/Lake Tahoe.png" >/dev/null

doc() {
    printf '<body style="font-family: Helvetica Neue; font-size: 15px">%s</body>' "$2" > "$WORK/$1.html"
    textutil -convert rtf -output "$WORK/$1.rtf" "$WORK/$1.html"
}
doc "About mFix" '<h1>mFix</h1>
<p>Windows 11 window management for the Mac, as a small menu bar app.</p>
<h2>What it does</h2>
<ul>
<li>Snaps windows to halves, quarters and thirds from the keyboard, or by dragging them to an edge.</li>
<li>Snap Assist offers your other windows for the space that is left.</li>
<li>Cmd+Tab switches between windows, not apps.</li>
<li>Hovering the green button opens Snap Layouts.</li>
<li>Hovering an icon in the Dock shows that app&#39;s windows.</li>
</ul>
<h2>Keys</h2>
<p>Cmd+Option stands in for the Windows key, and Settings can change it.</p>
<ul>
<li>Cmd+Option+Left or Right: snap to that half</li>
<li>Cmd+Option+Up: maximize</li>
<li>Cmd+Option+Z: Snap Layouts</li>
<li>Cmd+Option+D: show the desktop</li>
<li>Cmd+Tab: every window, most recent first</li>
</ul>
<h2>Getting started</h2>
<p>Drag mFix to Applications, open it, and allow Accessibility and Screen Recording when it asks.</p>'
doc "Release notes" '<h1>Release notes</h1>
<h2>Snap Layouts</h2>
<p>Suggested layouts now place the windows you used last.</p>
<h2>Switcher</h2>
<p>Snap groups show as one card, and thumbnails stay live while the switcher is open.</p>
<h2>Dock</h2>
<p>Clicking the icon of the app in front minimizes its window, as on the taskbar.</p>'
doc "Shopping list" '<h1>Shopping list</h1>
<ul><li>Coffee beans</li><li>Oat milk</li><li>Lemons</li><li>Bread</li><li>Basil</li></ul>'

launch() {
    open -n -g -a "/System/Applications/$1.app" ${2:+"$2"} ${3:+"$3"} ${4:+"$4"} --args $STYLE -CheckSpellingWhileTyping NO -ApplePersistence NO -ApplePersistenceIgnoreState YES || exit 1
    sleep 1.5
    PIDS="$PIDS${PIDS:+,}$(pgrep -n -f "/System/Applications/$1.app/Contents/MacOS/")"
}

for look in light dark; do
    if [ $look = light ]; then STYLE="-NSRequiresAquaSystemAppearance YES"; else STYLE="-AppleInterfaceStyle Dark"; fi
    launch Tips
    launch Dictionary
    launch Preview "/System/Library/Desktop Pictures/.wallpapers/Sonoma Horizon/Sonoma Horizon.heic"
    launch Preview "$WORK/Lake Tahoe.png"
    launch TextEdit "$WORK/Shopping list.rtf" "$WORK/Release notes.rtf" "$WORK/About mFix.rtf"
    sleep 4
    mkdir -p "$WORK/$look"
    MFIX_RENDER_PIDS="$PIDS" MFIX_RENDER_APPEARANCE=$look MFIX_RENDER_WALLPAPER="$WORK/wall-$look.png" render "$WORK/$look" || exit 1
    cleanup
    for name in switcher snap-assist layouts dock settings; do
        src="$WORK/$look/$name-$look.png"
        [ $name = settings ] && src="$WORK/$look/settings-$look-snapping.png"
        [ -f "$src" ] || { echo "not rendered: $name-$look"; exit 1; }
        if [ "$(sips -g pixelWidth "$src" | awk '/pixelWidth/ {print $2}')" -gt 1600 ]; then
            sips --resampleWidth 1600 "$src" >/dev/null
        fi
        cp "$src" "$WORK/out/$name-$look.png"
    done
done
command -v pngquant >/dev/null && pngquant --quality 80-95 --skip-if-larger --force --ext .png "$WORK"/out/*.png
cp "$WORK"/out/*.png docs/images/
/bin/ls -l docs/images
