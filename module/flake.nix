{
  description = "Yolo Board Module for Logos App";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/e9f00bd893984bc8ce46c895c3bf7cac95331127";
    logos-cpp-sdk = {
      url = "github:logos-co/logos-cpp-sdk";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    logos-liblogos = {
      url = "github:logos-co/logos-liblogos";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.logos-cpp-sdk.follows = "logos-cpp-sdk";
    };
    # Note: no logos-storage-module flake input. Storage's generated client
    # headers (storage_module_api.{h,cpp}) are vendored under
    # module/vendor/storage_module_api/. Pulling the full flake transitively
    # requires a git+https?submodules=1 fetch of logos-storage-nim whose
    # NAR hash is not reproducible across environments, which broke CI.
    # The storage_module .lgx is installed into basecamp profiles by
    # scaffold at deploy time — nothing in this flake needs to build it.
    logos-delivery-module = {
      url = "github:logos-co/logos-delivery-module/1.1.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    logos-package = {
      url = "github:logos-co/logos-package/9e3730d5c0e3ec955761c05b50e3a6047ee4030b";
    };
  };

  outputs = { self, nixpkgs, logos-cpp-sdk, logos-liblogos, logos-delivery-module, logos-package, ... }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        pkgs = import nixpkgs { inherit system; };
        logosSdk = logos-cpp-sdk.packages.${system}.default;
        logosLiblogos = logos-liblogos.packages.${system}.default;
        logosDelivery = logos-delivery-module.packages.${system}.default;
        lgxTool = logos-package.packages.${system}.lgx;
      });
    in
    {
      packages = forAllSystems ({ pkgs, logosSdk, logosLiblogos, logosDelivery, lgxTool }:
        let
          buildInputs = [ pkgs.qt6.qtbase ];

          plugin = pkgs.stdenv.mkDerivation {
            pname = "logos-yolo-board-module";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [
              pkgs.cmake
              pkgs.ninja
              pkgs.pkg-config
              pkgs.patchelf
            ];

            inherit buildInputs;

            # Note: LOGOS_DELIVERY_ROOT intentionally omitted — the module is
            # consumed via raw QRO IPC, no typed wrapper compile-time includes
            # needed. The flake input stays so `nix build` can resolve/pin
            # delivery_module alongside storage for reproducibility.
            cmakeFlags = [
              "-DLOGOS_CPP_SDK_ROOT=${logosSdk}"
              "-GNinja"
            ];

            buildPhase = ''
              runHook preBuild
              ninja yolo_board_module -j''${NIX_BUILD_CORES:-1}
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib
              cp libyolo_board_module.so $out/lib/
              runHook postInstall
            '';

            postFixup = ''
              patchelf --set-rpath "$out/lib:${logosLiblogos}/lib:${pkgs.lib.makeLibraryPath buildInputs}" \
                $out/lib/libyolo_board_module.so
            '';

            dontWrapQtApps = true;
          };

          # `built_variants` is the set of variant keys we preserve in the
          # packaged manifest's `main` field. Dev vs portable differ only in
          # the variant-name suffix and in the RPATH bundling of the plugin
          # .so (portable strips /nix/store paths and co-locates Qt runtime
          # deps next to the .so). Basecamp's variant selector matches the
          # on-disk `variant` file against `main` keys — drop non-matching
          # entries so AppImage basecamps (which read `linux-amd64`) and
          # dev basecamps (which read `linux-amd64-dev`) each see a
          # matching key.
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

          # Portable plugin: same build as `plugin`, but patchelf the .so's
          # RPATH to $ORIGIN only (no /nix/store refs) and co-locate the
          # Qt runtime libraries next to the plugin in the lgx variant-files
          # dir. An AppImage basecamp's Qt is at a different path than
          # ours; without this patchelf + bundle step the dynamic linker
          # can't resolve Qt symbols at load time.
          pluginPortable = plugin.overrideAttrs (old: {
            pname = "${old.pname}-portable";
            postFixup = ''
              patchelf --set-rpath '$ORIGIN' $out/lib/libyolo_board_module.so
            '';
          });

          # Runtime Qt6 libraries the plugin needs co-located with the .so
          # for the portable flavour. Walked by `ldd` and filtered to
          # Qt6Core/Qt6Concurrent (the only Qt modules the plugin links).
          # glibc/gcc runtime libs are expected to come from the AppImage
          # base system — bundling them would fight the AppImage's own
          # libc and routinely break.
          qtRuntimeLibs = pkgs.runCommand "yolo-board-module-qt-runtime" {} ''
            mkdir -p $out
            cp -L ${pkgs.qt6.qtbase}/lib/libQt6Core.so.6     $out/ 2>/dev/null || true
            cp -L ${pkgs.qt6.qtbase}/lib/libQt6Concurrent.so.6 $out/ 2>/dev/null || true
            cp -L ${pkgs.qt6.qtbase}/lib/libQt6Network.so.6  $out/ 2>/dev/null || true
            cp -L ${pkgs.qt6.qtbase}/lib/libQt6DBus.so.6     $out/ 2>/dev/null || true
            cp -L ${pkgs.icu}/lib/libicui18n.so.*            $out/ 2>/dev/null || true
            cp -L ${pkgs.icu}/lib/libicuuc.so.*              $out/ 2>/dev/null || true
            cp -L ${pkgs.icu}/lib/libicudata.so.*            $out/ 2>/dev/null || true
            chmod 0644 $out/*.so* 2>/dev/null || true
          '';

          mkLgx = { variant-suffix, variant-set, extra-files ? null }:
            pkgs.runCommand "yolo-board-module.lgx${variant-suffix}" {
              nativeBuildInputs = [ lgxTool pkgs.python3 ];
            } ''
              lgx create yolo-board-module

              mkdir -p variant-files
              cp ${if variant-suffix == "" then plugin else pluginPortable}/lib/libyolo_board_module.so variant-files/
              ${if extra-files != null then "cp -L ${extra-files}/* variant-files/ 2>/dev/null || true" else ""}

              ${if variant-suffix == "" then ''
                lgx add yolo-board-module.lgx --variant linux-x86_64-dev --files ./variant-files --main libyolo_board_module.so -y
                lgx add yolo-board-module.lgx --variant linux-amd64-dev --files ./variant-files --main libyolo_board_module.so -y
              '' else ''
                lgx add yolo-board-module.lgx --variant linux-x86_64 --files ./variant-files --main libyolo_board_module.so -y
                lgx add yolo-board-module.lgx --variant linux-amd64 --files ./variant-files --main libyolo_board_module.so -y
              ''}

              lgx verify yolo-board-module.lgx

              ${patchManifest "yolo-board-module" "${self}/metadata.json" variant-set}

              mkdir -p $out
              cp yolo-board-module.lgx $out/yolo-board-module.lgx
            '';

          lgx          = mkLgx { variant-suffix = "";          variant-set = "linux-x86_64-dev,linux-amd64-dev"; };
          lgx-portable = mkLgx { variant-suffix = "-portable"; variant-set = "linux-x86_64,linux-amd64"; extra-files = qtRuntimeLibs; };

        in {
          inherit plugin pluginPortable lgx lgx-portable;
          default = lgx;
        }
      );
    };
}
