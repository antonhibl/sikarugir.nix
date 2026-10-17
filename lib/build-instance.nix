/*
  Builds one declarative Sikarugir instance.

  Returns two outputs:
  - `skeleton`: a Nix derivation containing Template + Engine already
  combined with this instance's `Info.plist` settings applied on top.
  This part is fully reproducible and cacheable.
  - `activationScript`: a `writeShellApplication` that turns that
  skeleton into a writable location (since Nix store paths are
  read-only, and a wine prefix has to be writable as drive_c gets
  written to the moment you install or play a game) and runs Sikarugir's
  `WSS-wineprefixcreate`. It is idempotent, but unlike the first version
  of this module, it does NOT just no-op on every later run: it always
  re-applies this instance's `Info.plist` settings (see `plistPatches`
  below), so changing a setting in Nix and re-activating is enough on
  its own. It will NOT touch `Contents/SharedSupport/prefix` on an
  existing instance except to refresh it (`WSS-wineboot`, never
  `WSS-wineprefixcreate` again) if the Template/Engine pin itself changed.
*/
{ pkgs, lib, versions }:
let
  patchInfoPlistScript = pkgs.writeText "sikarugir-patch-info-plist.py" ''
    import json
    import plistlib
    import sys

    plist_path, patches_path = sys.argv[1], sys.argv[2]

    with open(patches_path, "r", encoding="utf-8") as f:
        patches = json.load(f)

    with open(plist_path, "rb") as f:
        raw = f.read()

    fmt = plistlib.FMT_BINARY if raw[:8] == b"bplist00" else plistlib.FMT_XML
    data = plistlib.loads(raw)

    for patch in patches:
        key, ptype, value = patch["key"], patch["type"], patch["value"]
        if ptype == "bool":
            data[key] = bool(value)
        elif ptype == "integer":
            data[key] = int(value)
        else:
            data[key] = str(value)

    with open(plist_path, "wb") as f:
        plistlib.dump(data, f, fmt=fmt)
  '';
in
cfg:
let
  buildBase = import ./build-base.nix { inherit pkgs versions; };
  base = buildBase { inherit (cfg) templateVersion engine; };

  bundleIdentifier =
    if cfg.bundleIdentifier != null
    then cfg.bundleIdentifier
    else "com.sikarugir.${cfg.name}";

  # One (key, plist-type, value) triple per managed Info.plist key. Every
  # key here is confirmed to exist in a real default Info.plist (see
  # lib/options.nix's per-option doc comments for the provenance of each default).
  plistPatches =
    [
      { key = "CFBundleName"; type = "string"; value = cfg.name; }
      { key = "CFBundleIdentifier"; type = "string"; value = bundleIdentifier; }
      { key = "Program Name and Path"; type = "string"; value = cfg.runPath; }
      { key = "Program Flags"; type = "string"; value = cfg.runFlags; }
      { key = "CLI Custom Commands"; type = "string"; value = cfg.cliCommands; }
      { key = "Associations"; type = "string"; value = cfg.associations; }

      { key = "D9VK"; type = "integer"; value = cfg.renderer.enableD9vk; }
      { key = "CNC_DDRAW"; type = "integer"; value = cfg.renderer.enableCncddraw; }
      { key = "DXVK"; type = "integer"; value = cfg.renderer.enableDxvk; }
      { key = "D3DMETAL"; type = "integer"; value = cfg.renderer.enableD3dMetal; }
      { key = "DXMT"; type = "integer"; value = cfg.renderer.enableDxmt; }

      { key = "WINEESYNC"; type = "integer"; value = cfg.sync.enableEsync; }
      { key = "WINEMSYNC"; type = "integer"; value = cfg.sync.enableMsync; }

      { key = "MOLTENVKCX"; type = "integer"; value = cfg.moltenVk.enableMoltenVkCx; }
      { key = "FASTMATH"; type = "integer"; value = cfg.moltenVk.enableFastMath; }

      { key = "METAL_HUD"; type = "integer"; value = cfg.enableMetalHud; }
      { key = "Debug Mode"; type = "integer"; value = cfg.enableDebugMode; }
      { key = "Disable CPUs"; type = "integer"; value = cfg.enableSingleCpu; }
      { key = "Try To Use GPU Info"; type = "integer"; value = cfg.enableAutomaticGpuDetection; }
      { key = "IsFnToggleEnabled"; type = "integer"; value = cfg.enableFnToggle; }

      { key = "WINEDEBUG"; type = "string"; value = cfg.wineDebugEnvironmentVariable; }
      { key = "Gamma Correction"; type = "string"; value = cfg.gammaCorrection; }

      { key = "Skip Gecko"; type = "integer"; value = cfg.disableGecko; }
      { key = "Skip Mono"; type = "integer"; value = cfg.disableMono; }
      { key = "force Installer to normal windows"; type = "integer"; value = cfg.installerShouldIgnoreScreenOptions; }

      { key = "Winetricks force"; type = "integer"; value = cfg.winetricks.force; }
      { key = "Winetricks silent"; type = "integer"; value = cfg.winetricks.silent; }
      { key = "Winetricks disable logging"; type = "integer"; value = cfg.winetricks.noLogs; }

      { key = "Symlinks In User Folder"; type = "bool"; value = cfg.symlinks.enable; }
      { key = "Symlink Desktop"; type = "string"; value = cfg.symlinks.desktopPath; }
      { key = "Symlink Downloads"; type = "string"; value = cfg.symlinks.downloadsPath; }
      { key = "Symlink My Documents"; type = "string"; value = cfg.symlinks.documentsPath; }
      { key = "Symlink My Music"; type = "string"; value = cfg.symlinks.musicPath; }
      { key = "Symlink My Pictures"; type = "string"; value = cfg.symlinks.picturesPath; }
      { key = "Symlink My Videos"; type = "string"; value = cfg.symlinks.moviesPath; }
      { key = "Symlink Templates"; type = "string"; value = cfg.symlinks.templatesPath; }
    ]
    ++ lib.attrsets.mapAttrsToList
      (key: value: {
        inherit key;
        type =
          if builtins.isBool value then "bool"
          else if builtins.isInt value then "integer"
          else if builtins.isString value then "string"
          else throw "sikarugir-nix: extraPlist.\"${key}\" for instance '${cfg.name}' is a ${builtins.typeOf value}! use a bool, int or string.";
        value = if builtins.isBool value then value else toString value;
      })
      cfg.extraPlist;

  plistPatchesFile = pkgs.writeText "sikarugir-info-plist-patches-${cfg.name}.json" (builtins.toJSON plistPatches);
  patchInfoPlistCommand = plistPath: ''${pkgs.python3}/bin/python3 ${patchInfoPlistScript} "${plistPath}" ${plistPatchesFile}'';

  # Parameterized over which Info.plist to patch, so both the build-time
  # skeleton and the runtime activation script (re-syncing an *existing*
  # instance on every activation) can share this exact same logic instead
  # of two copies drifting apart.
  patchInfoPlist = patchInfoPlistCommand "$APP/Contents/Info.plist";

  skeleton = pkgs.stdenvNoCC.mkDerivation {
    pname = "sikarugir-instance-${cfg.name}-skeleton";
    version = cfg.templateVersion;
    dontUnpack = true;
    # This whole derivation is already a pre-built, already-codesigned
    # macOS .app bundle out of upstream binaries. None of Nix's usual
    # fixup steps (stripping, shebang patching, rpath shrinking) are
    # appropriate here and some would actively break codesigning / bundled
    # Mach-O loader paths that Sikarugir's binaries rely on.
    dontFixup = true;
    dontStrip = true;
    dontPatchShebangs = true;
    nativeBuildInputs = [ ];

    buildPhase = ''
      runHook preBuild

      APP="$PWD/${cfg.name}.app"
      mkdir -p "$APP/Contents"

      ${if cfg.spaceOptimized then ''
        # Space-saving default (see the `spaceOptimized` option): these are
        # large, and never differ between two instances built from the same
        # (templateVersion, engine) pair, so they're symlinked straight out
        # of the shared base derivation instead of copied.
        ln -s "${base}/Contents/Configure.app" "$APP/Contents/Configure.app"
        ln -s "${base}/Contents/Frameworks" "$APP/Contents/Frameworks"
        ln -s "${base}/Contents/MacOS" "$APP/Contents/MacOS"
        ln -s "${base}/Contents/Resources" "$APP/Contents/Resources"
      '' else ''
        cp -a "${base}/Contents/Configure.app" "$APP/Contents/Configure.app"
        cp -a "${base}/Contents/Frameworks" "$APP/Contents/Frameworks"
        cp -a "${base}/Contents/MacOS" "$APP/Contents/MacOS"
        cp -a "${base}/Contents/Resources" "$APP/Contents/Resources"
        chmod -R u+w "$APP/Contents/Configure.app" "$APP/Contents/Frameworks" "$APP/Contents/MacOS" "$APP/Contents/Resources"
      ''}

      cp -a "${base}/Contents/PkgInfo" "$APP/Contents/PkgInfo"

      # Contents/Logs and Contents/drive_c are Template's own *relative*
      # symlinks (into SharedSupport/Logs and SharedSupport/prefix/drive_c
      # respectively, confirmed against a bare Template extraction).
      # Copying the symlink files themselves (not what they point to) is
      # correct and instance-scoped, since SharedSupport itself is always a
      # real, per-instance directory below, regardless of spaceOptimized.
      cp -a "${base}/Contents/Logs" "$APP/Contents/Logs"
      cp -a "${base}/Contents/drive_c" "$APP/Contents/drive_c"

      mkdir -p "$APP/Contents/SharedSupport"
      # Everything else Template keeps in SharedSupport (currently just the
      # empty Logs/ that Contents/Logs points at, where the launcher writes
      # its exec*.bat and run logs; without it every launch fails with
      # "Error while writting file").
      for entry in "${base}/Contents/SharedSupport/"* "${base}/Contents/SharedSupport/".[!.]*; do
        [ -e "$entry" ] || continue
        [ "$(basename "$entry")" = wine ] && continue
        cp -a "$entry" "$APP/Contents/SharedSupport/"
      done
      mkdir -p "$APP/Contents/SharedSupport/Logs"
      ${if cfg.spaceOptimized then ''
        ln -s "${base}/Contents/SharedSupport/wine" "$APP/Contents/SharedSupport/wine"
      '' else ''
        cp -a "${base}/Contents/SharedSupport/wine" "$APP/Contents/SharedSupport/wine"
        chmod -R u+w "$APP/Contents/SharedSupport/wine"
      ''}

      cp -a "${base}/Contents/Info.plist" "$APP/Contents/Info.plist"
      chmod u+w "$APP/Contents/Info.plist"
      ${patchInfoPlist}

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a "${cfg.name}.app" "$out/${cfg.name}.app"
      runHook postInstall
    '';
  };

  activationScript = pkgs.writeShellApplication {
    name = "sikarugir-activate-${cfg.name}";
    runtimeInputs = [ ];
    text = ''
      set -euo pipefail

      DEST="''${1:?usage: sikarugir-activate-${cfg.name} <parent-directory>}"
      APP="$DEST/${cfg.name}.app"
      RUN_PATH=${lib.escapeShellArg cfg.runPath}
      # Records which base derivation (and layout) this instance's shared
      # Contents/* currently come from, so a pin change is always noticed.
      BASE_STAMP="$APP/Contents/SharedSupport/.sikarugir-nix-base"
      DESIRED_STAMP=${lib.escapeShellArg "${base} spaceOptimized=${lib.boolToString cfg.spaceOptimized}"}

      launcher_bin() {
        local name
        name="$(${pkgs.python3}/bin/python3 -c '
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f).get("CFBundleExecutable") or "")
' "$APP/Contents/Info.plist" 2>&1)" || name=""

        if [ -n "$name" ] && [ -e "$APP/Contents/MacOS/$name" ]; then
          echo "$name"
          return 0
        fi

        for candidate in Sikarugir launcher wineskinlauncher; do
          if [ -e "$APP/Contents/MacOS/$candidate" ]; then
            echo "$candidate"
            return 0
          fi
        done

        echo "sikarugir-nix: could not determine the launcher binary name in" \
             "$APP/Contents/MacOS (CFBundleExecutable read back '$name'," \
             "and none of the known candidate names exist there either)" >&2
        return 1
      }

      mkdir -p "$DEST"

      if [ ! -e "$APP" ]; then
        echo "==> Building ${cfg.name}.app into $DEST"
        cp -a "${skeleton}/${cfg.name}.app" "$APP"
        # Neither GNU chmod (which home-manager's activation puts first on
        # PATH) nor macOS's follows symlinks found while recursing, so the
        # shared store paths are never touched. Don't pass BSD-only -P here:
        # GNU chmod rejects it and the whole activation would fail.
        chmod -R u+w "$APP"

        # Same as Configure's engine-install step: clear the quarantine
        # attribute Nix's own fetch (and this re-copy) leaves behind, or
        # Gatekeeper will refuse to run the wrapper's own binaries. -s: act
        # on a symlink itself, never follow it into the store, same reason
        # as chmod's -P just above.
        /usr/bin/xattr -drs com.apple.quarantine "$APP" || true

        echo "==> Running first-time WSS-wineprefixcreate (creates Contents/SharedSupport/prefix)"
        "$APP/Contents/MacOS/$(launcher_bin)" WSS-wineprefixcreate
        sleep 6
        printf '%s\n' "$DESIRED_STAMP" > "$BASE_STAMP"
      else
        echo "==> $APP already exists! Re-syncing settings only."

        # Work out which (Template, Engine, layout) this instance was last
        # activated against. Newer instances record it in $BASE_STAMP.
        # Instances activated by an older version of this module have no
        # stamp; those were always spaceOptimized (symlinked) if their
        # Frameworks is a symlink, so infer it from where that points.
        # Anything else (an old copied instance) has an unknown base, so it
        # gets refreshed once to be safe.
        CURRENT_STAMP=""
        if [ -f "$BASE_STAMP" ]; then
          CURRENT_STAMP="$(cat "$BASE_STAMP")"
        elif [ -L "$APP/Contents/Frameworks" ]; then
          CURRENT_STAMP="$(dirname "$(dirname "$(readlink "$APP/Contents/Frameworks")")") spaceOptimized=true"
        fi

        if [ "$CURRENT_STAMP" != "$DESIRED_STAMP" ]; then
          # The Template/Engine pin (or spaceOptimized) changed. Replace the
          # shared Contents/* with the new base's, in whichever layout
          # (symlinked or copied) is now configured, then refresh (not
          # recreate) the prefix against it. drive_c is never touched.
          echo "    Template/Engine pin or layout changed. Replacing shared Contents/* and refreshing the prefix"
          for d in Configure.app Frameworks MacOS Resources SharedSupport/wine; do
            target="$APP/Contents/$d"
            if [ -L "$target" ]; then
              rm -f "$target"
            elif [ -e "$target" ]; then
              chmod -R u+w "$target"
              rm -rf "$target"
            fi
            ${if cfg.spaceOptimized then ''
            ln -s "${base}/Contents/$d" "$target"
            '' else ''
            cp -a "${base}/Contents/$d" "$target"
            chmod -R u+w "$target"
            /usr/bin/xattr -dr com.apple.quarantine "$target" || true
            ''}
          done

          echo "    Running WSS-wineboot to refresh the existing prefix (drive_c is left untouched)"
          "$APP/Contents/MacOS/$(launcher_bin)" WSS-wineboot
          sleep 6
          printf '%s\n' "$DESIRED_STAMP" > "$BASE_STAMP"
        fi

        chmod u+w "$APP/Contents/Info.plist"
      fi

      # The launcher writes into Logs/ on every run. Instances created by
      # older versions of this module never got it, so make sure it's there.
      mkdir -p "$APP/Contents/SharedSupport/Logs"

      # Always re-apply Info.plist patches on every activation.
      ${patchInfoPlist}

      ${lib.strings.optionalString (cfg.winetricks.verbs != [ ]) ''
      echo "==> Applying winetricks verbs: ${lib.strings.concatStringsSep ", " cfg.winetricks.verbs}"
      ${lib.strings.concatMapStringsSep "\n" (verb: ''
        "$APP/Contents/MacOS/$(launcher_bin)" WSS-winetricks ${lib.escapeShellArg verb}
      '') cfg.winetricks.verbs}
      ''}

      echo "==> ${cfg.name}.app is ready at $APP"
      echo "    Program Name and Path is currently: $RUN_PATH"
      if [ "$RUN_PATH" = "/nothing.exe" ]; then
        echo "    (no game pointed at yet! install one into drive_c, then set"
        echo "     programs.sikarugir.instances.\"${cfg.name}\".runPath and re-activate)"
      fi
    '';
  };
in
{
  inherit skeleton activationScript base;
  inherit bundleIdentifier;
}
