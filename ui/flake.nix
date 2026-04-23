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
            # Was 0.2.1/v0.4.1 — that release asset is gone from GitHub.
            # Updated to the current shipped circuits release (0.1.2/v0.4.2).
            url = "https://github.com/logos-blockchain/logos-blockchain/releases/download/0.1.2/logos-blockchain-circuits-v0.4.2-linux-x86_64.tar.gz";
            sha256 = "0ad5b8czj36zfi01ibvnj7cy0fag14v87pd0bjwnwncbyarq8dcf";
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
          # Portable flavour strips /nix/store from the plugin's RPATH and
          # co-locates Qt + QtDeclarative + ICU runtime libs next to the .so
          # so AppImage basecamps can resolve them via $ORIGIN.
          pluginPortable = plugin.overrideAttrs (old: {
            pname = "${old.pname}-portable";
            postFixup = ''
              patchelf --set-rpath '$ORIGIN' $out/lib/yolo_board.so
              patchelf --set-rpath '$ORIGIN' $out/lib/libzone_sequencer_rs.so 2>/dev/null || true
            '';
          });

          qtRuntimeLibs = pkgs.runCommand "yolo-board-qt-runtime" {} ''
            mkdir -p $out
            for lib in libQt6Core libQt6Concurrent libQt6Qml libQt6QmlMeta libQt6QmlModels \
                       libQt6QmlWorkerScript libQt6Quick libQt6QuickControls2 \
                       libQt6QuickControls2Impl libQt6QuickLayouts libQt6QuickTemplates2 \
                       libQt6Gui libQt6Network libQt6DBus libQt6OpenGL; do
              cp -L ${pkgs.qt6.qtbase}/lib/$lib.so.6        $out/ 2>/dev/null || true
              cp -L ${pkgs.qt6.qtdeclarative}/lib/$lib.so.6 $out/ 2>/dev/null || true
            done
            cp -L ${pkgs.icu}/lib/libicui18n.so.*   $out/ 2>/dev/null || true
            cp -L ${pkgs.icu}/lib/libicuuc.so.*     $out/ 2>/dev/null || true
            cp -L ${pkgs.icu}/lib/libicudata.so.*   $out/ 2>/dev/null || true
            chmod 0644 $out/*.so* 2>/dev/null || true
          '';

          patchManifest = name: metadataFile: variantSet: ''
            python3 - ${name}.lgx ${metadataFile} ${variantSet} <<'PY'
            import json, sys, tarfile, io
            lgx_path = sys.argv[1]
            with open(sys.argv[2]) as f:
                metadata = json.load(f)
            built_variants = set(sys.argv[3].split(','))
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

          mkLgx = { variant-suffix, variant-set, bundle-qt ? false }:
            pkgs.runCommand "yolo-board.lgx${variant-suffix}" {
              nativeBuildInputs = [ lgxTool pkgs.python3 ];
            } ''
              lgx create yolo-board
              mkdir -p variant-files
              cp ${if variant-suffix == "" then plugin else pluginPortable}/lib/yolo_board.so variant-files/
              cp ${if variant-suffix == "" then plugin else pluginPortable}/lib/libzone_sequencer_rs.so variant-files/
              cp ${plugin}/lib/yolo.png variant-files/
              cp ${plugin}/qml/Main.qml variant-files/
              ${if bundle-qt then "cp -L ${qtRuntimeLibs}/*.so* variant-files/ 2>/dev/null || true" else ""}

              ${if variant-suffix == "" then ''
                lgx add yolo-board.lgx --variant linux-x86_64-dev --files ./variant-files --main yolo_board.so -y
                lgx add yolo-board.lgx --variant linux-amd64-dev  --files ./variant-files --main yolo_board.so -y
              '' else ''
                lgx add yolo-board.lgx --variant linux-x86_64 --files ./variant-files --main yolo_board.so -y
                lgx add yolo-board.lgx --variant linux-amd64  --files ./variant-files --main yolo_board.so -y
              ''}

              lgx verify yolo-board.lgx
              ${patchManifest "yolo-board" "${self}/metadata.json" variant-set}
              mkdir -p $out
              cp yolo-board.lgx $out/yolo-board.lgx
            '';

          lgx          = mkLgx { variant-suffix = "";          variant-set = "linux-x86_64-dev,linux-amd64-dev"; };
          lgx-portable = mkLgx { variant-suffix = "-portable"; variant-set = "linux-x86_64,linux-amd64"; bundle-qt = true; };

        in {
          inherit plugin pluginPortable app lgx lgx-portable rustLib;
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
