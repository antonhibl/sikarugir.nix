/*
  Usage (in your home-manager config):
  
  ```nix
  {
  imports = [ sikarugir-nix.homeManagerModules.default ];

  programs.sikarugir = {
      enable = true;
      # Defaults to ~/Applications/Sikarugir. Use an absolute path here:
      # "~" is not expanded.
      # instancesDirectory = "/Users/you/Applications/Sikarugir";

      instances.SatisfactoryCX = {
        engine = "WS12WineCX24.0.7_7";
        runPath = "/Program Files/Epic Games/SatisfactoryEarlyAccess/FactoryGame/Binaries/Win64/FactoryGame-Win64-Shipping.exe";
      };
  };
  }
  ```

  Instances are created with a launchd-free activation script hooked into
  home-manager's activation (lib.hm.dag.entryAfter [ "writeBoundary" ]`).
  It runs on `home-manager switch`. For an instance that doesn't exist
  yet, it will create it. For an existing instance, it will sync
  `Info.plist` settings. This never modifies an instance's save data in
  `Contents/SharedSupport/prefix`.

  Removing an instance from your config moves its `.app` (save data
  included) to the macOS Trash on the next activation, so it can still be
  recovered. Set `removedInstances = "keep";` to leave it in place instead.
  Only `.app`s this module itself created are ever moved: they're tracked in
  `<instancesDirectory>/.sikarugir-nix-managed`.

  Each instance's own activation script is also added to `home.packages`,
  so you can re-run just one instance's sync by hand
  (`sikarugir-activate-SatisfactoryCX ~/Applications/Sikarugir`) without a
  full `home-manager switch`.
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.sikarugir;
  versions = import ../lib/versions.nix;
  instanceOptions = import ../lib/options.nix { inherit lib versions; };
  buildInstance = import ../lib/build-instance.nix { inherit pkgs lib versions; };

  # `name` is auto-filled from the attribute name unless overridden
  instanceType = lib.types.submodule ({ name, ... }: {
    options = instanceOptions;
    config = {
      name = lib.modules.mkDefault name;
    };
  });

  built = lib.attrsets.mapAttrs (_: instCfg: buildInstance instCfg) cfg.instances;

  # The `.app` names, which come from each instance's `name` (defaulting
  # to its attribute name, but overridable).
  appNames = lib.attrsets.mapAttrsToList (_: instCfg: instCfg.name) cfg.instances;
  duplicateAppNames =
    lib.lists.filter (n: lib.lists.count (x: x == n) appNames > 1)
      (lib.lists.unique appNames);

  pruneScript = pkgs.writeShellApplication {
    name = "sikarugir-prune-removed";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ../lib/prune-removed.sh;
  };

  shortcutType = lib.types.submodule ({ name, ... }: {
    options = {
      name = lib.options.mkOption {
        type = lib.types.strMatching "[^/.:][^/:]*";
        default = name;
        defaultText = lib.literalMD "the attribute name";
        description = "The shortcut's `.app` name, as shown in Finder, Spotlight and the Dock.";
      };
      instance = lib.options.mkOption {
        type = lib.types.str;
        default = "Steam";
        description = ''
          Name of the entry in `programs.sikarugir.instances` that has Windows
          Steam installed, and that the game is installed in.
        '';
      };
      steamAppId = lib.options.mkOption {
        type = lib.types.ints.positive;
        example = 881100;
        description = ''
          The game's Steam app ID: the number in its store page URL, or in
          the name of its `steamapps/appmanifest_<id>.acf`.
        '';
      };
      icon = lib.options.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
        default = null;
        example = lib.literalExpression "./icons/noita.png";
        description = ''
          An image (PNG, JPEG, ICO or ICNS) to use as the icon. Left `null`,
          the icon is taken from the game's own Steam icon if it's large
          enough, otherwise from its Steam library cover art.
        '';
      };
    };
  });

  shortcutNames = lib.attrsets.mapAttrsToList (_: s: s.name) cfg.shortcuts;
  duplicateShortcutNames =
    lib.lists.filter (n: lib.lists.count (x: x == n) shortcutNames > 1)
      (lib.lists.unique shortcutNames);
  shortcutsClashingWithInstances = lib.lists.filter (n: lib.lists.elem n appNames) shortcutNames;
  shortcutsWithMissingInstance = lib.attrsets.attrNames (lib.attrsets.filterAttrs
    (_: s: !(lib.lists.elem s.instance appNames)) cfg.shortcuts);

  shortcutSpec = pkgs.writeText "sikarugir-shortcuts.json" (builtins.toJSON (lib.attrsets.mapAttrsToList
    (_: s: {
      inherit (s) name instance steamAppId;
      icon = if s.icon == null then null else toString s.icon;
    })
    cfg.shortcuts));

  shortcutsScript = pkgs.writeShellApplication {
    name = "sikarugir-shortcuts";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      DIR="''${1:?usage: sikarugir-shortcuts <instancesDirectory>}"
      ${lib.meta.getExe pruneShortcutsScript} "$DIR" ${lib.strings.escapeShellArgs shortcutNames}
      ${lib.strings.optionalString (cfg.shortcuts != { }) ''
        ${pkgs.python3.withPackages (p: [ p.pillow ])}/bin/python3 -I ${../lib/make-shortcuts.py} "$DIR" ${shortcutSpec}
      ''}
    '';
  };

  pruneShortcutsScript = pkgs.writeShellApplication {
    name = "sikarugir-prune-shortcuts";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ../lib/prune-shortcuts.sh;
  };

  bundleIdentifiers = lib.attrsets.mapAttrsToList (_: inst: inst.bundleIdentifier) built;
  duplicateBundleIdentifiers =
    lib.lists.filter (id: lib.lists.count (x: x == id) bundleIdentifiers > 1)
      (lib.lists.unique bundleIdentifiers);
in
{
  options.programs.sikarugir = {
    enable = lib.options.mkEnableOption "declarative Sikarugir instances";

    instancesDirectory = lib.options.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Applications/Sikarugir";
      description = ''
        The directory where Sikarugir instances are created and managed.
        Matches where Sikarugir's own Homebrew cask suggests putting
        wrapper apps (`~/Applications/Sikarugir`) so Spotlight/Launchpad
        indexing behaves the way you'd expect for a normal app folder.
      '';
    };

    instances = lib.options.mkOption {
      type = lib.types.attrsOf instanceType;
      default = { };
      description = ''
        Declarative Sikarugir instances, keyed by name.
      '';
    };

    shortcuts = lib.options.mkOption {
      type = lib.types.attrsOf shortcutType;
      default = { };
      example = lib.literalExpression ''
        {
          Noita.steamAppId = 881100;
          "Dwarf Fortress".steamAppId = 975370;
        }
      '';
      description = ''
        Mac app icons for games installed through Windows Steam in one of
        your `instances`. Each becomes `<instancesDirectory>/<name>.app`
        with the game's icon; opening it launches the game, starting Steam
        first if it isn't already running. Removing one deletes its `.app`
        (a shortcut holds no game data).
      '';
    };

    removedInstances = lib.options.mkOption {
      type = lib.types.enum [ "trash" "keep" ];
      default = "trash";
      description = ''
        What to do with an instance's `.app` once it's removed from
        `instances` (or renamed). Its Wine prefix, and so its save data,
        lives inside the `.app`.

        - `"trash"`: move it to the macOS Trash on the next activation, so
          it can still be restored from there. It is never deleted outright.
        - `"keep"`: leave it where it is, unmanaged.

        Only `.app`s this module created itself are affected.
      '';
    };
  };

  config = lib.modules.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = ''
          programs.sikarugir only works on macOS since Sikarugir itself,
          and everything this module builds, is macOS-only.
        '';
      }
      {
        assertion = duplicateBundleIdentifiers == [ ];
        message = ''
          programs.sikarugir: more than one instance resolved to the same
          CFBundleIdentifier (${lib.concatStringsSep ", " duplicateBundleIdentifiers})!
          Real Creator-built instances avoid this by appending a random
          numeric suffix; this module doesn't (that would break Nix
          reproducibility) so give colliding instances distinct
          `bundleIdentifier`s explicitly, or rename them.
        '';
      }
      {
        assertion = duplicateShortcutNames == [ ] && shortcutsClashingWithInstances == [ ];
        message = ''
          programs.sikarugir.shortcuts: these names are used twice, or by an
          instance too, so their `.app`s would collide:
          ${lib.concatStringsSep ", " (lib.lists.unique (duplicateShortcutNames ++ shortcutsClashingWithInstances))}
        '';
      }
      {
        assertion = shortcutsWithMissingInstance == [ ];
        message = ''
          programs.sikarugir.shortcuts: ${lib.concatStringsSep ", " shortcutsWithMissingInstance}
          point at an instance that isn't in programs.sikarugir.instances.
        '';
      }
      {
        assertion = duplicateAppNames == [ ];
        message = ''
          programs.sikarugir: more than one instance has the same `name`
          (${lib.concatStringsSep ", " duplicateAppNames}), so they would
          share one `.app`. Give each instance a distinct `name`.
        '';
      }
    ];

    home.activation.sikarugirInstances = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD ${lib.meta.getExe pruneScript} ${lib.strings.escapeShellArg cfg.instancesDirectory} ${cfg.removedInstances} ${lib.strings.escapeShellArgs appNames}
      ${lib.concatStringsSep "\n" (lib.attrsets.mapAttrsToList
        (_: inst: ''
          $DRY_RUN_CMD ${lib.meta.getExe inst.activationScript} ${lib.strings.escapeShellArg cfg.instancesDirectory}
        '')
        built)}
      $DRY_RUN_CMD ${lib.meta.getExe shortcutsScript} ${lib.strings.escapeShellArg cfg.instancesDirectory}
    '';

    home.packages = lib.attrsets.mapAttrsToList (_: inst: inst.activationScript) built;
  };
}
