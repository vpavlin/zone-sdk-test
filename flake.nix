{
  description = "Yolo Board — censorship-resistant bulletin board for Logos Basecamp";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/e9f00bd893984bc8ce46c895c3bf7cac95331127";
    nixpkgs-rust.url = "github:NixOS/nixpkgs/bfc1b8a4574108ceef22f02bafcf6611380c100d";
    logos-module-builder = {
      url = "github:logos-co/logos-module-builder";
    };
    logos-cpp-sdk = {
      url = "github:logos-co/logos-cpp-sdk/4b66dac015e4b977d33cfae80a4c8e1d518679f3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    logos-liblogos = {
      url = "github:logos-co/logos-liblogos/7df61954851c0782195b9663f41e982ed74e73e9";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-cpp-sdk.follows = "logos-cpp-sdk";
    };
    logos-package = {
      url = "github:logos-co/logos-package/9e3730d5c0e3ec955761c05b50e3a6047ee4030b";
    };
    zone-sequencer-module = {
      url = "github:vpavlin/logos-zone-sequencer-module/96d3bf6";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-cpp-sdk.follows = "logos-cpp-sdk";
      inputs.logos-liblogos.follows = "logos-liblogos";
    };
    zone-sequencer-rs = {
      url = "github:vpavlin/zone-sequencer-rs/31ee86a";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixpkgs-rust, logos-module-builder,
              logos-cpp-sdk, logos-liblogos, logos-package,
              zone-sequencer-module, zone-sequencer-rs, ... }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        pkgs = import nixpkgs { inherit system; };
        pkgsRust = import nixpkgs-rust { inherit system; };
        logosSdk = logos-cpp-sdk.packages.${system}.default;
        logosLiblogos = logos-liblogos.packages.${system}.default;
        lgxTool = logos-package.packages.${system}.lgx;
        zonePlugin = zone-sequencer-module.packages.${system}.plugin;
      });
    in
    {
      packages = forAllSystems ({ pkgs, pkgsRust, logosSdk, logosLiblogos, lgxTool, zonePlugin }:
        let
          buildInputs = [
            pkgs.qt6.qtbase
            pkgs.qt6.qtdeclarative
          ];

          circuits = builtins.fetchTarball {
            url = "https://github.com/logos-blockchain/logos-blockchain/releases/download/0.2.1/logos-blockchain-circuits-v0.4.1-linux-x86_64.tar.gz";
            sha256 = "1xnhl4y2zpxvcgm0xx95v0v6av2amp5isfi0s92cxrjg7dqmp5z8";
          };

          rustLib = pkgsRust.rustPlatform.buildRustPackage {
            pname = "zone-sequencer-rs";
            version = "0.1.0";
            src = zone-sequencer-rs;
            cargoLock = {
              lockFile = "${zone-sequencer-rs}/Cargo.lock";
              outputHashes = {
                "jf-crhf-0.1.1" = "sha256-TUm91XROmUfqwFqkDmQEKyT9cOo1ZgAbuTDyEfe6ltg=";
                "jf-poseidon2-0.1.0" = "sha256-QeCjgZXO7lFzF2Gzm2f8XI08djm5jyKI6D8U0jNTPB8=";
                "logos-blockchain-blend-crypto-0.2.1" = "sha256-gZfVABdtKAMJ6JB3x1xs+qCU1ieo8GQ2Vs6UI6hU1LY=";
                "overwatch-0.1.0" = "sha256-L7R1GdhRNNsymYe3RVyYLAmd6x1YY08TBJp4hG4/YwE=";
              };
            };
            LOGOS_BLOCKCHAIN_CIRCUITS = circuits;
            nativeBuildInputs = [ pkgsRust.pkg-config pkgsRust.perl ];
            buildInputs = [ pkgsRust.openssl ];
            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib
              find target -name 'libzone_sequencer_rs.so' -path '*/release/*' -exec install -m755 {} $out/lib/ \;
              runHook postInstall
            '';
          };

          cmakeFlagsCommon = [
            "-DLOGOS_CPP_SDK_ROOT=${logosSdk}"
            "-DZONE_SEQUENCER_RS_LIB_DIR=${rustLib}/lib"
            "-GNinja"
          ];

          # ── Basecamp plugin ───────────────────────────────────────────────
          plugin = pkgs.stdenv.mkDerivation {
            pname = "yolo-board-plugin";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.cmake pkgs.ninja pkgs.pkg-config pkgs.patchelf ];
            inherit buildInputs;
            cmakeFlags = cmakeFlagsCommon;
            buildPhase = ''
              runHook preBuild
              ninja yolo_board_plugin -j''${NIX_BUILD_CORES:-1}
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib
              cp libyolo_board_plugin.so $out/lib/yolo_board.so
              cp ${rustLib}/lib/libzone_sequencer_rs.so $out/lib/
              cp $src/resources/Yolo.png $out/lib/yolo.png
              mkdir -p $out/qml
              cp $src/src/qml/Main.qml $out/qml/
              runHook postInstall
            '';
            postFixup = ''
              patchelf --set-rpath "$out/lib:${logosLiblogos}/lib:${pkgs.lib.makeLibraryPath buildInputs}" \
                $out/lib/yolo_board.so
            '';
            dontWrapQtApps = true;
          };

          # ── Standalone app ────────────────────────────────────────────────
          app = pkgs.stdenv.mkDerivation {
            pname = "yolo-board";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.cmake pkgs.ninja pkgs.pkg-config pkgs.patchelf pkgs.qt6.wrapQtAppsHook ];
            buildInputs = buildInputs ++ [ pkgs.qt6.qtwayland pkgs.openssl ];
            cmakeFlags = cmakeFlagsCommon;
            buildPhase = ''
              runHook preBuild
              ninja yolo_board_app -j''${NIX_BUILD_CORES:-1}
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/lib
              cp yolo_board_app $out/bin/yolo-board
              cp ${rustLib}/lib/libzone_sequencer_rs.so $out/lib/
              runHook postInstall
            '';
            preFixup = ''
              qtWrapperArgs+=(
                --prefix LD_LIBRARY_PATH : "${pkgs.openssl.out}/lib"
                --prefix LD_LIBRARY_PATH : "$out/lib"
                --set QML_DISABLE_DISK_CACHE 1
                --set-default QT_QUICK_BACKEND software
              )
            '';
          };

          # ── LGX bundle ───────────────────────────────────────────────────
          patchManifest = name: metadataFile: ''
            python3 - ${name}.lgx ${metadataFile} <<'PY'
            import json, sys, tarfile, io
            lgx_path = sys.argv[1]
            with open(sys.argv[2]) as f:
                metadata = json.load(f)
            built_variants = {'linux-x86_64-dev', 'linux-amd64-dev'}
            with tarfile.open(lgx_path, 'r:gz') as tar:
                members = [(m, tar.extractfile(m).read() if m.isfile() else None) for m in tar.getmembers()]
            patched = []
            for member, data in members:
                if member.name == 'manifest.json':
                    manifest = json.loads(data)
                    for key in ('name', 'version', 'description', 'type', 'category', 'dependencies'):
                        if key in metadata:
                            manifest[key] = metadata[key]
                    if 'main' in manifest and isinstance(manifest['main'], dict):
                        # Keep `-dev` suffix — basecamp matches the installed
                        # `variant` file (e.g. linux-x86_64-dev) against manifest
                        # `main` keys. Stripping `-dev` silently breaks loading.
                        manifest["main"] = {k: v for k, v in manifest["main"].items() if k in built_variants}
                    data = json.dumps(manifest, indent=2).encode()
                    member.size = len(data)
                patched.append((member, data))
            with tarfile.open(lgx_path, 'w:gz', format=tarfile.GNU_FORMAT) as tar:
                for member, data in patched:
                    if data is not None:
                        tar.addfile(member, io.BytesIO(data))
                    else:
                        tar.addfile(member)
            PY
          '';

          lgx = pkgs.runCommand "yolo-board.lgx" {
            nativeBuildInputs = [ lgxTool pkgs.python3 ];
          } ''
            lgx create yolo-board
            mkdir -p variant-files
            cp ${plugin}/lib/yolo_board.so variant-files/
            cp ${plugin}/lib/libzone_sequencer_rs.so variant-files/
            cp ${plugin}/lib/yolo.png variant-files/
            cp ${plugin}/qml/Main.qml variant-files/
            lgx add yolo-board.lgx --variant linux-x86_64-dev --files ./variant-files --main yolo_board.so -y
            lgx add yolo-board.lgx --variant linux-amd64-dev  --files ./variant-files --main yolo_board.so -y
            lgx verify yolo-board.lgx
            ${patchManifest "yolo-board" "${self}/metadata.json"}
            mkdir -p $out
            cp yolo-board.lgx $out/yolo-board.lgx
          '';

        in {
          inherit plugin app lgx rustLib;
          default = lgx;
        }
      );

      apps = nixpkgs.lib.genAttrs [ "x86_64-linux" ] (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.app}/bin/yolo-board";
        };
      });
    };
}
