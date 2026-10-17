# `sikarugir.nix`

A Nix flake that allows for declarative management of [Sikarugir](https://github.com/Sikarugir-App) instances.

Sikarugir is a Wine wrapper for macOS. Given a (pinned and reproducible) Template and Engine version and a description of your settings and configuration, `sikarugir.nix` will create a `.app` wrapper.

## Requirements

- macOS 14.6+ on an Apple Silicon or Intel Mac (based on Sikarugir's minimum supported macOS version)
- Lix (or any other Nix distribution/derivative) (with flakes enabled)
- Rosetta 2 (via `softwareupdate --install-rosetta --agree-to-license`)
  - Template.app is still x86_64 only. This is expected to change in macOS 28, where Rosetta will be deprecated entirely. You may get a warning about this on macOS 27 Golden Gate; it is safe to ignore it.

## Quick start (home-manager)

```nix
{
    inputs.sikarugir-nix.url = "github:depressionlab/sikarugir.nix";

    outputs = { self, home-manager, sikarugir-nix, ... }: {
        homeConfigurations.you = home-manager.lib.homeManagerConfiguration {
            modules = [
                sikarugir-nix.homeManagerModules.default
                {
                    programs.sikarugir.enable = true;
                    programs.sikarugir.instances.SatisfactoryCX = {
                        engine = "WS12WineCX24.0.7_7";
                        runPath = ''/Program Files/Epic Games/SatisfactoryEarlyAccess/FactoryGame/Binaries/Win64/FactoryGame-Win64-Shipping.exe'';
                    };
                };
            ];
        };
    };
}
```

```console
$ home-manager switch
==> Building SatisfactoryCX.app into /Users/you/Applications/Sikarugir
==> Running first-time WSS-wineprefixcreate (creates Contents/SharedSupport/prefix)
==> SatisfactoryCX.app is ready at /Users/you/Applications/Sikarugir/SatisfactoryCX.app
```

To update an existing managed instance, simply change your configuration and re-run `home-manager switch`. This will not change any of your prefix-specific save data and is fully reversible.

## Quick start (nix-darwin)

If your `nix-darwin` configuration already uses home-manager in per-user, you can use the `nix-darwin` module instead of touching that user's home-manager configuration directly:

```nix
{
    inputs.sikarugir-nix.url = "github:depressionlab/sikarugir.nix";

    # in your darwinConfiguration's modules:
    imports = [
        home-manager.darwinModules.home-manager
        sikarugir-nix.darwinModules.default
    ];

    programs.sikarugir.enable = true;
    programs.sikarugir.user = "myuser"; # the macOS account these instances belong to.
    programs.sikarugir.instances = {
        SatisfactoryCX = {
            engine = "WS12WineCX24.0.7_7";
            runPath = ''/Program Files/Epic Games/SatisfactoryEarlyAccess/FactoryGame/Binaries/Win64/FactoryGame-Win64-Shipping.exe'';
        };
    };
}
```

The supplied `nix-darwin` `darwinModule` is a thin wrapper which forwards into `home-manager.users.<user>`. It is intended as a convenience for when you'd rather setup `programs.sikarugir` once at the top nix-darwin level, instead of within a specific user's `home-manager` configuration block.

## Quick start (flake-parts)

If your flake is built using [flake-parts](https://flake.parts), we supply a flake-parts module:

```nix
{
    imports = [ inputs.sikarugir-nix.flakeModules.default ];
}
```

The flake-parts module is a wrapper for `homeManagerModules.default` and `darwinModules.default` and allows you to reference them via `self.` the same way other flake-parts modules are referenced.

## Quick start (standalone)

```console
nix build github:depressionlab/sikarugir.nix#satisfactory-example
open result/SatisfactoryCX.app
```

## Functionality

This flake is a full Nix re-implementation of Sikarugir's `Sikarugir Creator.app` and `Configure.app`. It works by vendoring two parts and fusing them together:

1. Template.app: a Wine wrapper `.app` skeleton published by Sikarugir at [Sikarugir-App/Template](https://github.com/Sikarugir-App/Template). It includes the base settings and all renderers (DXVK, D9VK, DXMT, D3DMetal, cnc_ddraw).
2. Engine: a portable Wine build from [Sikarugir-App/Engines](https://github.com/Sikarugir-App/Engines). They are packaged into `.tar.xz` bundles containing `wswine.bundle/{bin,lib,share,version}` directories.

These two components are pulled from a pinned version registry based on Sikarugir's API (see `versions.json`) and fused together based on the LGPL-licensed [`Configure.app`](https://github.com/Sikarugir-App/Sikarugir-foss-sources) (`WineskinAppDelegate.m`'s `-changeEngineUsedOkButtonPressed:`).

The Engine's `wswine.bundle` contents are flattened onto the wrapper's `Contents/SharedSupport/wine` and `WSS-wineprefixcreate` (supplied from `Template.app`'s binary bundle) does an initial `wineboot` to create `Contents/SharedSupport/prefix/`. This last step is impure, as it writes absolute, machine-specific paths into the prefix's registry, and installs Wine Mono/Gecko from files bundled inside the Engine tarball.

As such, this flake is split into two steps:

- a reproducible, pure Nix derivation (`skeleton`) which combines a pinned Template and Engine version (since if those two inputs are the same, they will always create a byte-identical `.app`), and
- a one-time impure activation script step that copies the skeleton into a writable and safe location before running `WSS-wineprefixcreate`.

It doesn't make sense to make the `wineboot` step reproducible, since it would just move the Wine installer and registry steps into Nix without increasing reproducibility, as installing a Windows game into the instances is unavoitably stateful and is the whole purpose of having a separate instance prefix.

### Updating and removing instances

- **Changing the Template/Engine pin** (or `spaceOptimized`) on an existing instance replaces its shared `Contents/*` with the new version on the next activation and runs `WSS-wineboot` to refresh the prefix. `drive_c` and your saves are left alone. Each instance records what it was last built from in `Contents/SharedSupport/.sikarugir-nix-base`.
- **Removing an instance** from `instances` (or changing its `name`) moves its `.app` to the macOS Trash on the next activation. Because the Wine prefix lives inside the `.app`, this includes its saves, which is why it's never deleted outright. Set `programs.sikarugir.removedInstances = "keep";` to leave removed `.app`s in place instead. Only `.app`s this module created are ever touched; they're tracked in `<instancesDirectory>/.sikarugir-nix-managed`.

### Game shortcuts

Install Windows Steam in an instance (for example `instances.Steam`, with `runPath = "/Program Files (x86)/Steam/steam.exe"`), install games from it, then give any of them a Mac app icon:

```nix
programs.sikarugir.shortcuts = {
  Noita.steamAppId = 881100;
  "Dwarf Fortress".steamAppId = 975370;
  # instance = "Steam" is the default; icon = ./noita.png overrides the icon.
};
```

Each becomes `<instancesDirectory>/<name>.app`. Opening it hands `steam://rungameid/<id>` to the instance, which starts Steam if needed and launches the game. Icons come from the game's own Steam icon when it's at least 128px, otherwise its Steam library cover art; mostly transparent ones get a light backing. Removing a shortcut deletes its `.app` (it holds no game data). The app ID is in the game's store URL, or in `steamapps/appmanifest_<id>.acf` inside the instance.

## Options

All available options and settings are available in `lib/options.nix`. Option names are recovered from Sikarugir's `SikarugirWineAppConfig` Swift type rather than the legacy `Info.plist` values.

`programs.sikarugir` itself also takes `instancesDirectory` (an absolute path; `~` isn't expanded) and `removedInstances` (`"trash"`, the default, or `"keep"`).

## Known limitations

- **GPU auto-detection isn't reproducible**: Sikarugir runs `system_profiler` to query hardware at runtime when `enableAutomaticGpuDetection` is enabled. We haven't implemented that yet, so it is left off by default.

## License

Licensed under the EUPL. See [LICENSE](./LICENSE).
