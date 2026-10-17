# Handles instances that were removed from programs.sikarugir.instances.
#
# usage: sikarugir-prune-removed <instancesDirectory> <trash|keep> [current app names...]
#
# Instance names this module has created are tracked in
# <instancesDirectory>/.sikarugir-nix-managed. Any name listed there that's
# no longer configured has its .app moved to the macOS Trash ("trash") or
# left alone ("keep"). Nothing is ever deleted outright, because an
# instance's Wine prefix (and so its save data) lives inside its .app, and
# nothing that isn't listed in the manifest is ever touched.

set -euo pipefail

DIR="${1:?usage: sikarugir-prune-removed <instancesDirectory> <trash|keep> [names...]}"
MODE="${2:?usage: sikarugir-prune-removed <instancesDirectory> <trash|keep> [names...]}"
shift 2

MANIFEST="$DIR/.sikarugir-nix-managed"
still_tracked=()

is_configured() {
  local candidate
  for candidate in "${CURRENT[@]}"; do
    if [ "$candidate" = "$1" ]; then
      return 0
    fi
  done
  return 1
}

move_to_trash() {
  local app="$1" name="$2" stamp dest
  stamp="$(date +%Y-%m-%d-%H%M%S)"

  # macOS 15+ ships /usr/bin/trash, which goes through Finder's own
  # Trash handling (so "Put Back" works).
  if [ -x /usr/bin/trash ] && /usr/bin/trash "$app" 2>/dev/null; then
    echo "    moved to the Trash"
    return 0
  fi

  # Older macOS: move it into ~/.Trash directly.
  dest="$HOME/.Trash/$name.app"
  if [ -e "$dest" ]; then
    dest="$HOME/.Trash/$name $stamp.app"
  fi
  if mv "$app" "$dest" 2>/dev/null; then
    echo "    moved to the Trash"
    return 0
  fi

  # If even that is refused (e.g. no permission to write ~/.Trash), park
  # it in a hidden folder next to the instances rather than delete it.
  mkdir -p "$DIR/.removed"
  dest="$DIR/.removed/$name $stamp.app"
  mv "$app" "$dest"
  echo "    couldn't reach the Trash, so moved it to $dest instead (delete it yourself when you're sure)"
}

CURRENT=("$@")

mkdir -p "$DIR"

if [ -f "$MANIFEST" ]; then
  while IFS= read -r old || [ -n "$old" ]; do
    [ -n "$old" ] || continue

    # Instance names are restricted to [A-Za-z0-9_-]+ by the module's
    # options, so anything else in the manifest was edited by hand. Never
    # build a path out of it.
    case "$old" in
      *[!A-Za-z0-9_-]*)
        echo "sikarugir-nix: ignoring unexpected entry '$old' in $MANIFEST" >&2
        continue
        ;;
    esac

    if is_configured "$old"; then
      continue
    fi

    app="$DIR/$old.app"
    if [ ! -e "$app" ]; then
      # Already gone (deleted by hand); stop tracking it.
      continue
    fi

    if [ "$MODE" = "trash" ]; then
      echo "==> $old is no longer in programs.sikarugir.instances: removing $app"
      move_to_trash "$app" "$old"
    else
      echo "==> $old is no longer in programs.sikarugir.instances: leaving $app in place (removedInstances = \"keep\")"
      # Keep tracking it, so switching to "trash" later still cleans it up.
      still_tracked+=("$old")
    fi
  done < "$MANIFEST"
fi

for n in "${CURRENT[@]}" "${still_tracked[@]}"; do
  printf '%s\n' "$n"
done | sort -u > "$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
