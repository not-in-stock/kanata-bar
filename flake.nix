{
  description = "Native macOS menu bar app for kanata keyboard remapper";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          swift-format # Swift code formatter
          swiftlint # Swift linter
        ];

        shellHook = ''
          echo "kanata-bar dev shell"
          echo "Swift: $(swiftc --version 2>&1 | head -1)"
          echo ""
          echo "Commands:"
          echo "  ./build.sh        — compile kanata-bar"
          echo "  ./build.sh clean  — remove build artifacts"
        '';
      };
    };
}
