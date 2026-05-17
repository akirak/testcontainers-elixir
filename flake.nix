{
  description = "A flake template for Phoenix 1.7 projects.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      overlay = final: prev: {
        erlang = final.beamPackages.erlang;
        beamPackages = prev.beam28Packages;
        elixir = final.beamPackages.elixir_1_20;
        hex = final.beamPackages.hex;
        final.mix2nix = prev.mix2nix.overrideAttrs {
          nativeBuildInputs = [ final.elixir ];
          buildInputs = [ final.erlang ];
        };
      };

      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      nixpkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor system;
        in
        {
          default = pkgs.beamPackages.mixRelease {
            pname = "testcontainers-elixir-lib";
            src = ./.;
            version = "0.1.0";
          };
        }
      );
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor system;
        in
        {
          default = self.devShells.${system}.dev;
          dev = pkgs.callPackage ./shell.nix {
            dbName = "db_dev";
            mixEnv = "dev";
          };
          test = pkgs.callPackage ./shell.nix {
            dbName = "db_test";
            mixEnv = "test";
          };
          prod = pkgs.callPackage ./shell.nix {
            dbName = "db_prod";
            mixEnv = "prod";
          };
        }
      );
    };
}
