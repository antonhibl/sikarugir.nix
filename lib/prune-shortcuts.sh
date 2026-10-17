# Removes shortcut .apps that were dropped from programs.sikarugir.shortcuts.
#
# usage: sikarugir-prune-shortcuts <instancesDirectory> [current shortcut names...]
#
# Shortcuts this module made are listed in
# <instancesDirectory>/.sikarugir-nix-shortcuts. A shortcut holds no data
# of its own (just a launcher script and an icon), so a removed one is
# deleted, but only if it still carries this module's marker file.

set -euo pipefail

DIR="${1:?usage: sikarugir-prune-shortcuts <instancesDirectory> [names...]}"
shift
MANIFEST="$DIR/.sikarugir-nix-shortcuts"
CURRENT=("$@")

is_configured() {
  local candidate
  for candidate in "${CURRENT[@]}"; do
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

mkdir -p "$DIR"

if [ -f "$MANIFEST" ]; then
  while IFS= read -r old || [ -n "$old" ]; do
    [ -n "$old" ] || continue
    case "$old" in
      */* | .*)
        echo "sikarugir-nix: ignoring unexpected entry '$old' in $MANIFEST" >&2
        continue
        ;;
    esac
    is_configured "$old" && continue
    app="$DIR/$old.app"
    if [ -f "$app/Contents/Resources/sikarugir-nix-shortcut" ]; then
      echo "==> Shortcut $old was removed from programs.sikarugir.shortcuts: deleting $app"
      rm -rf "$app"
    fi
  done < "$MANIFEST"
fi

for n in "${CURRENT[@]}"; do
  printf '%s\n' "$n"
done | sort -u > "$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
