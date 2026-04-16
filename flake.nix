{
  description = "Yolo Board — censorship-resistant bulletin board for Logos Basecamp";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/e9f00bd8319eb51abcd46a45b5da21c9a67d4f65";
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
    # zone-sequencer-module provides blockchain inscription capabilities
    zone-sequencer-module = {
      url = "github:jimmy-claw/logos-zone-sequencer-module";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-cpp-sdk.follows = "logos-cpp-sdk";
      inputs.logos-liblogos.follows = "logos-liblogos";
    };
  };

  outputs = { self, nixpkgs, logos-cpp-sdk, logos-liblogos, logos-package, zone-sequencer-module, ... }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        pkgs = import nixpkgs { inherit system; };
        logosSdk = logos-cpp-sdk.packages.${system}.default;
        logosLiblogos = logos-liblogos.packages.${system}.default;
        lgxTool = logos-package.packages.${system}.lgx;
        zoneModule = zone-sequencer-module.packages.${system}.plugin;
      });
    in
    {
      packages = forAllSystems ({ pkgs, logosSdk, logosLiblogos, lgxTool, zoneModule }:
        let
          buildInputs = [
            pkgs.qt6.qtbase
            pkgs.qt6.qtdeclarative
          ];

          plugin = pkgs.stdenv.mkDerivation {
            pname = "yolo-board";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [
              pkgs.cmake
              pkgs.ninja
              pkgs.pkg-config
              pkgs.patchelf
            ];

            inherit buildInputs;

            cmakeFlags = [
              "-DLOGOS_CPP_SDK_ROOT=${logosSdk}"
              "-GNinja"
            ];

            buildPhase = ''
              runHook preBuild
              ninja yolo_board_plugin -j''${NIX_BUILD_CORES:-1}
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib $out/qml
              cp libyolo_board_plugin.so $out/lib/
              runHook postInstall
            '';

            postFixup = ''
              patchelf --set-rpath "${logosLiblogos}/lib:${pkgs.lib.makeLibraryPath buildInputs}" \
                $out/lib/libyolo_board_plugin.so
            '';

            dontWrapQtApps = true;
          };

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
                        manifest["main"] = {k.replace("-dev", ""): v for k, v in manifest["main"].items() if k in built_variants}
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
            cp ${plugin}/lib/libyolo_board_plugin.so variant-files/

            lgx add yolo-board.lgx --variant linux-x86_64-dev --files ./variant-files --main libyolo_board_plugin.so -y
            lgx add yolo-board.lgx --variant linux-amd64-dev --files ./variant-files --main libyolo_board_plugin.so -y

            lgx verify yolo-board.lgx

            ${patchManifest "yolo-board" "${self}/metadata.json"}

            mkdir -p $out
            cp yolo-board.lgx $out/yolo-board.lgx
          '';

        in {
          inherit plugin lgx;
          default = lgx;
        }
      );
    };
}
