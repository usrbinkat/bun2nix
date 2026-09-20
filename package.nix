# Standalone callPackage-compatible bun2nix package for nixpkgs by-name.
# Decoupled from flake-parts perSystem wiring. Builds the Rust binary,
# Zig cache-entry-creator, setup hook, and fetchBunDeps infrastructure
# as passthru on a single package attribute.
{
  lib,
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  fetchgit,
  makeSetupHook,
  writeShellApplication,
  bun,
  nodejs,
  yq-go,
  libarchive,
  zig_0_15,
  linkFarm,
  callPackage,
  symlinkJoin,
  runCommandLocal,
  patch,
}:

let
  version = "2.1.2";

  src = fetchFromGitHub {
    owner = "usrbinkat";
    repo = "bun2nix";
    rev = "714af6d3f54fab402a3ee8ac016506c477b52384";
    hash = "sha256-1crWPaBfpNxtqPxfg01ryTeTLJIKkmYIzo49e74+baQ=";
  };

  # Zig cache-entry-creator: computes wyhash cache paths for bun packages
  cacheEntryCreator = stdenvNoCC.mkDerivation {
    pname = "bun2nix-cache-entry-creator";
    inherit version;
    src = src + "/programs/cache-entry-creator";
    nativeBuildInputs = [ zig_0_15.hook ];
    postConfigure = ''
      ln -s ${callPackage (src + "/programs/cache-entry-creator/deps.nix") { }} $ZIG_GLOBAL_CACHE_DIR/p
    '';
    zigBuildFlags = [ "--release=fast" ];
    doCheck = true;
    meta = {
      description = "Cache entry creator for bun packages";
      mainProgram = "cache_entry_creator";
    };
  };

  # Shell script to extract tarballs or copy directories
  extractPackage = writeShellApplication {
    name = "extract-bun-package";
    runtimeInputs = [ libarchive ];
    text = ''
      pkg=""
      out=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --package) shift; pkg="$1" ;;
          --out) shift; out="$1" ;;
          --package=*) pkg="''${1#--package=}" ;;
          --out=*) out="''${1#--out=}" ;;
          *) echo "Unknown: $1"; exit 1 ;;
        esac
        shift
      done
      [ -z "$pkg" ] || [ -z "$out" ] && { echo "Usage: --package <pkg> --out <out>"; exit 1; }
      mkdir -p "$out"
      if [[ "$pkg" = *.tgz ]]; then
        bsdtar --extract --file "$pkg" --directory "$out" --strip-components=1 --no-same-owner --no-same-permissions
      else
        cp -r "$pkg/." "$out"
      fi
      chmod -R u+rwx "$out"
    '';
  };

  # Bun with fake node/npm/npx symlinks for lifecycle scripts
  bunWithNode = stdenvNoCC.mkDerivation {
    name = "bun-with-fake-node";
    dontUnpack = true;
    dontBuild = true;
    installPhase = ''
      cp -r "${bun}/." "$out"
      chmod u+w "$out/bin"
      for node_binary in "node" "npm" "npx"; do
        ln -s "$out/bin/bun" "$out/bin/$node_binary"
      done
    '';
  };

  # No-op bun2nix script (replaces real bun2nix in lifecycle scripts)
  bun2nixNoOp = writeShellApplication {
    name = "bun2nix";
    text = "";
  };

  # Setup hook for bun2nix builds
  hook = makeSetupHook {
    name = "bun2nix-hook";
    propagatedBuildInputs = [
      bun2nixNoOp
      bun
      yq-go
    ];
    substitutions = {
      resolveCatalogTs = src + "/nix/mk-derivation/resolve-catalog.ts";
      bunDefaultInstallFlags =
        if stdenvNoCC.hostPlatform.isDarwin then
          [
            "--linker=isolated"
            "--backend=symlink"
          ]
        else
          [ "--linker=isolated" ];
    };
  } (src + "/nix/mk-derivation/hook.sh");

  # Build a single bun package: extract tarball + create cache entry
  buildPackage =
    name: pkg:
    stdenvNoCC.mkDerivation {
      name = "bun-pkg-${name}";
      nativeBuildInputs = [ bunWithNode ];
      phases = [
        "extractPhase"
        "patchPhase"
        "cacheEntryPhase"
      ];
      extractPhase = ''
        runHook preExtract
        "${lib.getExe extractPackage}" --package "${pkg}" --out "$out/share/bun-packages/${name}"
        runHook postExtract
      '';
      patchPhase = ''
        runHook prePatch
        patchShebangs "$out/share/bun-packages"
        runHook postPatch
      '';
      cacheEntryPhase = ''
        runHook preCacheEntry
        "${lib.getExe cacheEntryCreator}" --out "$out/share/bun-cache" --name "${name}" --package "$out/share/bun-packages/${name}"
        runHook postCacheEntry
      '';
      preferLocalBuild = true;
      allowSubstitutes = false;
    };

  # Convert patchedDependencies attrset to overrides for fetchBunDeps
  patchedDependenciesToOverrides =
    {
      patchedDependencies ? { },
    }:
    lib.mapAttrs (
      name: patchFile:
      let
        safePatchFile = builtins.path {
          path = patchFile;
          name = lib.pipe patchFile [
            toString
            baseNameOf
            lib.strings.sanitizeDerivationName
            builtins.unsafeDiscardStringContext
          ];
        };
      in
      pkg:
      runCommandLocal "patched-${lib.strings.sanitizeDerivationName name}"
        { nativeBuildInputs = [ patch ]; }
        ''
          mkdir $out
          cp -r ${pkg}/. $out
          chmod -R u+w $out
          echo "Applying patch for ${name}..."
          patch -p1 -d $out < ${safePatchFile}
        ''
    ) patchedDependencies;

  # Fetch bun dependencies from a bun.nix lockfile into a cache-compatible symlink farm
  fetchBunDeps =
    {
      bunNix,
      overrides ? { },
      bunfigPath ? null,
      npmrcPath ? null,
      ...
    }:
    let
      attrIsBunPkg = _: value: lib.isStorePath value;
      packages = lib.filterAttrs attrIsBunPkg (callPackage bunNix { });

      overridePackage =
        name: pkg:
        if (overrides ? "${name}") then
          let
            preExtracted = runCommandLocal "pre-extract-${name}" { } ''
              "${lib.getExe extractPackage}" --package "${pkg}" --out "$out"
            '';
          in
          overrides.${name} preExtracted
        else
          pkg;
    in
    assert lib.asserts.assertEachOneOf "overrides" (builtins.attrNames overrides) (
      builtins.attrNames packages
    );
    assert lib.assertMsg (builtins.all builtins.isFunction (builtins.attrValues overrides))
      "All attr values of `overrides` must be functions taking the old package and returning the new source.";
    symlinkJoin {
      name = "bun-cache";
      paths = lib.pipe packages [
        (builtins.mapAttrs overridePackage)
        (builtins.mapAttrs buildPackage)
        builtins.attrValues
      ];
    };

in
rustPlatform.buildRustPackage {
  pname = "bun2nix";
  inherit version src;

  sourceRoot = "${src.name}/programs/bun2nix";

  cargoLock = {
    lockFile = src + "/programs/bun2nix/Cargo.lock";
  };

  passthru = {
    inherit
      hook
      fetchBunDeps
      cacheEntryCreator
      extractPackage
      patchedDependenciesToOverrides
      ;
  };

  meta = {
    description = "Create nix expressions from bun lockfiles";
    homepage = "https://github.com/nix-community/bun2nix";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [
      baileylu
      usrbinkat
    ];
    mainProgram = "bun2nix";
    platforms = lib.platforms.unix;
  };
}
