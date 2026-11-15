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
      # imports and inputsFrom below mirror each other: the Zig toolchain is
      # the 0.17 module's, so the shell and the linter agree on one std.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.17"
      ];

      perSystem =
        {
          pkgs,
          config,
          system,
          ...
        }:
        let
          # Project-specific tools. Go builds `tools/hpack-interop`, which
          # regenerates the HPACK interop fixture. `fromGoMod` takes the
          # toolchain from the module's go.mod, not from nixpkgs.
          project = [
            (inputs.mattware.packages.${system}.go-bin.fromGoMod ./tools/hpack-interop/go.mod)
            pkgs.gopls
            pkgs.h2spec
            pkgs.nghttp2
            pkgs.openssl.dev
            pkgs.openssl.out
            pkgs.pkg-config
            # ziglint with the target std's doc comments, so the deprecation
            # rule checks the minimum supported API surface.
            config.packages."ziglint-0-17"
          ];
        in
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-17"
            ];
            packages = project;
          };
        };
    };
}
