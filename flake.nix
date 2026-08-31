{
  description = "haskell-datahub reproducible build and development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
      };

      haskellPackages = pkgs.haskell.packages.ghc9103;

      rawDatahubPackage =
        haskellPackages.callCabal2nix
          "haskell-datahub"
          ./.
          { };

      datahubPackage =
        pkgs.lib.pipe rawDatahubPackage [
          pkgs.haskell.lib.compose.dontCheck
          pkgs.haskell.lib.compose.dontHaddock
          pkgs.haskell.lib.compose.disableParallelBuilding
        ];
    in
    {
      packages.${system}.default = datahubPackage;

      checks.${system}.build = datahubPackage;

      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = [
          haskellPackages.ghc
          pkgs.cabal-install
          pkgs.pkg-config
          pkgs.git
          pkgs.curl
        ];

        buildInputs = [
          pkgs.postgresql
          pkgs.zlib
          pkgs.openssl
          pkgs.gmp
          pkgs.libffi
        ];

        shellHook = ''
          echo
          echo "============================================"
          echo " HASKELL DATAHUB NIX DEVELOPMENT SHELL"
          echo "============================================"
          echo
          ghc --version
          cabal --version | head -1
          echo
        '';
      };
    };
}
