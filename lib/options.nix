/*
  Option schema for one declarative Sikarugir instance.

  This mirrors Sikarugir's own modern config model, `SikarugirWineAppConfig`
  (from `SikarugirSdk.framework`, shared by the Template runtime, Configure.app
  and Creator.app) rather than the legacy `Info.plist` key strings it maps
  onto underneath.

  Every default below is taken from the existing Sikarugir defaults. Where a
  setting's *value format* (as opposed to its default) hasn't been observed
  in the wild (Resolution, Associations' exact syntax), it's exposed as a
  raw string passthrough rather than guessing a format that might be wrong.
*/
{ lib, versions }:
let
  legacyPlistBool = default: description: lib.options.mkOption {
    type = lib.types.bool;
    inherit default;
    description = description + ''

      (Legacy `Info.plist` representation: Sikarugir writes most of these
      as `<integer>0/1</integer>` and one as a real `<true/>`/`<false/>`
      depending on which tool last touched them. Both are valid CFBoolean
      encodings and Sikarugir reads them with `-intValue`, so this module
      always emits real boolean tags for clarity.)
    '';
  };
in
{
  name = lib.options.mkOption {
    type = lib.types.strMatching "[A-Za-z0-9_-]+";
    example = "MySikarugirInstance";
    description = ''
      Instance name. Used as the `.app` bundle's filename (`''${name}.app`)
      and, unless overridden, as the `CFBundleName`.

      Restricted to filesystem/bundle-safe characters, since this becomes a
      literal path component and Info.plist string.
    '';
  };

  bundleIdentifier = lib.options.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "com.sikarugir.MySikarugirInstance";
    description = ''
      `CFBundleIdentifier` for the built wrapper. Defaults to
      `"com.sikarugir.''${name}"` if left `null`.

      Real Creator-built instances append a random numeric suffix
      (e.g. `com.sikarugir.SatisfactoryCX915024761`) to avoid collisions
      between multiple wrapped apps sharing a name; this module doesn't
      replicate that randomness (it would break reproducibility between
      evaluations) and instead relies on `name` already being unique across
      your declared instances.
    '';
  };

  templateVersion = lib.options.mkOption {
    type = lib.types.enum (lib.attrsets.attrNames versions.templates);
    default = versions.defaultTemplateVersion;
    description = ''
      The pinned Sikarugir template release that this instance should be built
      from. See `lib/versions.nix` for the set of versions this module has
      downloaded and hashed.
    '';
  };

  engine = lib.options.mkOption {
    type = lib.types.enum (lib.attrsets.attrNames versions.engines);
    default = versions.defaultEngine;
    description = ''
      Which pinned Wine engine to install into this instance (Sikarugir's
      "Engine": a portable Wine build, extracted and flattened
      onto `Contents/SharedSupport/wine`). See `lib/versions.nix` for the
      pinned catalog.

      Naming convention: `WS<n>` is the Wineskin config-schema version;
      `WineSikarugir` is Sikarugir's own Wine fork (the current default);
      `WineCX` is a CrossOver-derived build; `WhiskyWine`/`WineGPTK` are
      imported from other projects; a `32Bit` suffix is the i386 build of
      the same version.
    '';
  };

  runPath = lib.options.mkOption {
    type = lib.types.str;
    default = "/nothing.exe";
    example = "/Program Files/Epic Games/SatisfactoryEarlyAccess/FactoryGame/Binaries/Win64/FactoryGame-Win64-Shipping.exe";
    description = ''
      The wrapped Windows executable, as a path inside this instance's
      `drive_c`. Maps to legacy `Program Name and Path`.

      Written with forward slashes and no drive-letter prefix.

      `"/nothing.exe"` is Sikarugir's placeholder for "nothing selected
      yet". Launching a wrapper in this default state opens a generic run
      dialog rather than auto-launching.

      This module cannot install the game itself for you. Set this once
      you've installed the game into this instance's `drive_c` by hand.
    '';
  };

  runFlags = lib.options.mkOption {
    type = lib.types.str;
    default = "";
    description = "Command-line flags passed to `runPath`. Maps to legacy `Program Flags`.";
  };

  cliCommands = lib.options.mkOption {
    type = lib.types.str;
    default = "";
    description = "Extra shell commands passed to Sikarugir.";
  };

  associations = lib.options.mkOption {
    type = lib.types.str;
    default = "";
    description = "File-extension associations, legacy `Associations` key.";
  };

  renderer = {
    enableD9vk = legacyPlistBool true ''
      D9VK: DirectX 9 via Vulkan. Enabled by default. Legacy key `D9VK`.
    '';
    enableCncddraw = legacyPlistBool true ''
      cnc_ddraw: supports DirectX 8 and below. Enabled by default. Legacy key `CNC_DDRAW`.
    '';
    enableDxvk = legacyPlistBool false ''
      DXVK: DirectX 10 & 11 via Vulkan. Legacy key `DXVK`.
    '';
    enableD3dMetal = legacyPlistBool false ''
      D3DMetal (Apple's GPTK): 64-bit Direct3D 11 & 12 via Metal, Apple
      Silicon only. Closed-source with a restrictive license: not usable
      for commercial ports. Legacy key `D3DMETAL`.
    '';
    enableDxmt = legacyPlistBool false ''
      DXMT: DirectX 10 & 11 via Metal. Requires wine-8.0 or greater and
      macOS Sonoma+.
    '';
  };

  sync = {
    enableEsync = legacyPlistBool true "Wine ESYNC. Legacy key `WINEESYNC`.";
    enableMsync = legacyPlistBool true "Wine MSYNC. Legacy key `WINEMSYNC`.";
  };

  moltenVk = {
    enableMoltenVkCx = legacyPlistBool false ''
      Use CrossOver's own MoltenVK rather than Sikarugir's bundled one.
      Legacy key `MOLTENVKCX`. Only meaningful with a CrossOver-derived
      (`WineCX`) engine.
    '';
    enableFastMath = legacyPlistBool false ''
      MoltenVK fast-math. Legacy key `FASTMATH`.
    '';
  };

  enableMetalHud = legacyPlistBool false ''
    Overlay Apple's Metal HUD (frame time / GPU counters). Legacy key
    `METAL_HUD`.
  '';

  enableDebugMode = legacyPlistBool false ''
    Sikarugir/Wine debug mode. Legacy key `Debug Mode`.
  '';

  enableSingleCpu = legacyPlistBool false ''
    Restrict the wrapped process to a single CPU. Legacy key
    `Disable CPUs` (the legacy key name is the inverse phrasing of what it
    does: `1` means "yes, disable the others").
  '';

  enableAutomaticGpuDetection = legacyPlistBool false ''
    Allows Sikarugir to auto-detect your GPU via `system_profiler` and adjust
    renderer defaults accordingly. Legacy key `Try To Use GPU Info`.

    Left off by default in this module: this queries live hardware state
    at *runtime* inside Sikarugir's own Swift code
    (`GraphicCard.bestGraphicCard()`), which has no equivalent at Nix
    evaluation or build time. Pick renderer flags explicitly above
    instead of relying on this.
  '';

  enableFnToggle = legacyPlistBool true ''
    Whether the Fn key toggles between hardware function-key behavior and
    the wrapped app receiving raw Fn-modified keys. Legacy key `IsFnToggleEnabled`.
  '';

  enableAvx = legacyPlistBool false ''
    AVX support (`SikarugirWineAppConfig.enableAvx`). No legacy Info.plist
    key surfaced this in either sample inspected. It may be derived from
    CPU capabilities rather than stored, or only settable in a Template
    version newer than 1.0.19.
  '';

  wineDebugEnvironmentVariable = lib.options.mkOption {
    type = lib.types.str;
    default = "-plugplay,+loaddll";
    description = "The `WINEDEBUG` environment variable Sikarugir launches Wine with.";
  };

  gammaCorrection = lib.options.mkOption {
    type = lib.types.str;
    default = "default";
    description = "Legacy `Gamma Correction` key. Only `\"default\"` observed in the wild so far.";
  };

  disableGecko = legacyPlistBool false ''
    Skip installing Wine Gecko (bundled offline inside the engine tarball,
    not fetched over the network at prefix-creation time). Legacy key
    `Skip Gecko`.
  '';
  disableMono = legacyPlistBool false ''
    Skip installing Wine Mono (also bundled offline; confirmed present as
    `wine-mono-9.0.0` inside the `WS12WineCX24.0.7_7` engine and installed
    into the prefix during the `WSS-wineboot` run). Legacy key
    `Skip Mono`.
  '';

  installerShouldIgnoreScreenOptions = legacyPlistBool false ''
    Legacy `force Installer to normal windows`. 
  '';

  winetricks = {
    force = legacyPlistBool false "Legacy `Winetricks force`.";
    silent = legacyPlistBool true "Legacy `Winetricks silent`. `true` by default.";
    noLogs = legacyPlistBool true "Legacy `Winetricks disable logging`. `true` by default.";

    verbs = lib.options.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "vcrun2019" "dotnet48" "corefonts" ];
      description = ''
        Winetricks verbs to install into this instance's Wine prefix.
        These verbs are applied declaratively on every activation.
      '';
    };
  };

  symlinks = {
    enable = legacyPlistBool false ''
      Map this instance's Windows-side user folders (Desktop, Documents,
      Downloads, Music, Pictures, Videos, Templates) to real folders in
      your macOS home directory. Legacy key `Symlinks In User Folder`.

      Defaults to `false`. When enabled, each `*Path` option below
      is created as a real absolute-path symlink from inside the
      prefix out to your Mac filesystem. Sikarugir's wineboot step
      does this, not this module; setting `enable = true` here just
      flips the flag it reads.
    '';
    desktopPath = lib.options.mkOption {
      type = lib.types.str;
      default = "$HOME/Desktop";
      description = "Legacy `Symlink Desktop`. `$HOME` is expanded by Sikarugir itself, not Nix.";
    };
    downloadsPath = lib.options.mkOption {
      type = lib.types.str;
      default = "$HOME/Downloads";
      description = "Legacy `Symlink Downloads`.";
    };
    documentsPath = lib.options.mkOption {
      type = lib.types.str;
      default = "$HOME/Documents";
      description = "Legacy `Symlink My Documents`.";
    };
    musicPath = lib.options.mkOption {
      type = lib.types.str;
      default = "$HOME/Music";
      description = "Legacy `Symlink My Music`.";
    };
    picturesPath = lib.options.mkOption {
      type = lib.types.str;
      default = "$HOME/Pictures";
      description = "Legacy `Symlink My Pictures`.";
    };
    moviesPath = lib.options.mkOption {
      type = lib.types.str;
      default = "$HOME/Movies";
      description = "Legacy `Symlink My Videos`.";
    };
    templatesPath = lib.options.mkOption {
      type = lib.types.str;
      default = "$HOME/Templates";
      description = "Legacy `Symlink Templates`. Most Mac users don't have a literal `~/Templates` folder; it's created empty if missing.";
    };
  };

  spaceOptimized = lib.options.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Share this instance's Template+Engine files with every other instance
      that uses the same `templateVersion`/`engine` pair, instead of
      physically duplicating them, by symlinking `Contents/{Frameworks,Resources}`
      and `Contents/SharedSupport/wine` out of a shared `/nix/store`
      derivation (see `lib/build-base.nix`). `Contents/MacOS` and
      `Contents/Configure.app` are always real per-instance copies (well
      under 5 MB), since the launcher locates its wrapper from its own path
      and macOS resolves that through symlinks.
    '';
  };

  extraPlist = lib.options.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    example = { "Resolution" = "1920x1080"; };
    description = ''
      Extra literal `Info.plist` keys merged in verbatim
      (after everything above, so this can override any generated key too).
      Use this for settings this module doesn't model yet (e.g., `Resolution`,
      `Fullscreen`, `Use RandR` and multi-value `Associations`).
    '';
  };
}
