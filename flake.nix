{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The shared mattware pin: Go's toolchain selection lives there, and
    # following baskingspot's input keeps one rev across the org.
    mattware.follows = "baskingspot/mattware";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, including the
      # toolchain version: pick that once, in the import.
      imports = with inputs.baskingspot.flakeModules; [
        base
        zig."0.16"
      ];

      perSystem =
        {
          pkgs,
          config,
          system,
          ...
        }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells."zig-0-16"
            ];

            # Project-specific tools. Go builds `tools/hpack-interop`, which
            # regenerates the HPACK interop fixture. `fromGoMod` takes the
            # toolchain from the module's go.mod, not from nixpkgs.
            packages = [
              (inputs.mattware.packages.${system}.go-bin.fromGoMod ./tools/hpack-interop/go.mod)
              pkgs.gopls
              pkgs.h2spec
              pkgs.nghttp2
              # ziglint with the target std's doc comments, so the deprecation
              # rule checks the oldest API surface this repo supports.
              config.packages."ziglint-0-16"
            ];
          };
        };
    };
}
