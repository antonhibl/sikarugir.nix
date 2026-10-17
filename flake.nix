{
  description = "Declarative Sikarugir (Wine wrapper) instances for macOS, as Nix";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "aarch64-darwin" "x86_64-darwin" ];
      forEachSystem = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
      versions = import ./lib/versions.nix;
    in
    {
      lib = {
        inherit versions;
        mkOptions = { lib }: import ./lib/options.nix { inherit lib versions; };
        mkInstance = { pkgs, lib }: import ./lib/build-instance.nix { inherit pkgs lib versions; };
      };

      homeManagerModules.default = import ./modules/home-manager.nix;
      homeManagerModules.sikarugir = self.homeManagerModules.default;

      darwinModules.default = import ./modules/nix-darwin.nix;
      darwinModules.sikarugir = self.darwinModules.default;

      # For a consumer flake built with flake-parts (https://flake.parts):
      # `imports = [ inputs.sikarugir-nix.flakeModules.default ];`.
      flakeModules.default = import ./flake-module.nix { inherit self; };
      flakeModules.sikarugir = self.flakeModules.default;

      packages = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          buildInstance = import ./lib/build-instance.nix { inherit pkgs; inherit (pkgs) lib; inherit versions; };
          exampleOptions = import ./lib/options.nix { inherit (pkgs) lib; inherit versions; };
          mkExampleConfig = instanceModule: (pkgs.lib.evalModules {
            modules = [{ options = exampleOptions; } { config = instanceModule; }];
          }).config;

          exampleConfig = mkExampleConfig (import ./examples/satisfactory.nix).config;
          dedupDemo = import ./examples/dedup-demo.nix;
          dedupA = buildInstance (mkExampleConfig dedupDemo.a);
          dedupB = buildInstance (mkExampleConfig dedupDemo.b);
        in
        {
          # `nix build .#satisfactory-example`
          satisfactory-example = (buildInstance exampleConfig).skeleton;

          # `nix build .#dedup-check`
          dedup-check = pkgs.runCommand "sikarugir-dedup-check" { } ''
            for d in Frameworks Resources SharedSupport/wine; do
              a_link="$(readlink "${dedupA.skeleton}/${dedupDemo.a.name}.app/Contents/$d")"
              b_link="$(readlink "${dedupB.skeleton}/${dedupDemo.b.name}.app/Contents/$d")"

              echo "instance A (${dedupDemo.a.name}) shares Contents/$d: $a_link"
              echo "instance B (${dedupDemo.b.name}) shares Contents/$d: $b_link"

              if [ -z "$a_link" ] || [ -z "$b_link" ]; then
                echo "FAIL: Contents/$d wasn't a symlink at all! spaceOptimized dedup isn't happening"
                exit 1
              fi
              if [ "$a_link" != "$b_link" ]; then
                echo "FAIL: two instances on the identical (templateVersion, engine) pair did NOT" \
                     "resolve to the same shared /nix/store path for Contents/$d: the dedup" \
                     "guarantee is broken"
                exit 1
              fi
            done

            if [ -L "${dedupA.skeleton}/${dedupDemo.a.name}.app/Contents/MacOS" ]; then
              echo "FAIL: Contents/MacOS must be a real per-instance copy"
              exit 1
            fi

            echo "OK: Frameworks/wine are shared, MacOS stays real per-instance" > "$out"
          '';
        });

      checks = forEachSystem (system: {
        satisfactory-example = self.packages.${system}.satisfactory-example;
        dedup = self.packages.${system}.dedup-check;
      });

      # `nix fmt`
      formatter = forEachSystem (system: (import nixpkgs { inherit system; }).nixpkgs-fmt);
    };
}
