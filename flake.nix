{
  description = "C++ -> Ruby transliteration of the OpenCloud desktop client";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
    mine.url = "github:n-at-han-k/flake.nix";
    mine.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, mine, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = mine.lib.${system};

        gemset = import ./gemset.nix;

        treeSitterPack = {
          x86_64-linux = { platform = "x86_64-linux"; sha256 = "1sirqhxgpkbh1mfr3cqis0xa2mmzb64a3zpfpzgr647cxj16di23"; };
          aarch64-linux = { platform = "aarch64-linux"; sha256 = "1bxgpzrncppgd2m9691gr6zrr1rdl27grb5bj0f0rv3qvlxvzg7q"; };
          aarch64-darwin = { platform = "arm64-darwin"; sha256 = "1kyjxnb8n4xc2lcri44x1yx8dzcq76p61fdiarjm7j1r164x26v2"; };
        }.${system};

        gems = pkgs.bundlerEnv {
          name = "opencloud-generated-gems";
          ruby = pkgs.ruby_4_0;
          gemfile = ./Gemfile;
          lockfile = ./Gemfile.lock;
          gemset = gemset // {
            tree_sitter_language_pack = gemset.tree_sitter_language_pack // {
              inherit (treeSitterPack) platform;
              source = gemset.tree_sitter_language_pack.source
                // { inherit (treeSitterPack) sha256; };
            };
          };
        };

        ast-grep = pkgs.runCommand "ast-grep-0.51.3" { } ''
          install -Dm755 ${pkgs.fetchurl {
            url = "https://github.com/n-at-han-k/rust-builds/releases/download/ast-grep-v0.51.3/ast-grep";
            hash = "sha256-PIuXm5sDJQMnTgQ5xqqsa6Kffo9+gcCM6evFcakPViw=";
          }} $out/bin/ast-grep
        '';
      in
      {
        devShells.default = lib.mkRubyShell {
          buildInputs = [
            gems
            gems.wrappedRuby

            ast-grep
            pkgs.python3

            pkgs.unifdef
            pkgs.go-task

            pkgs.clang
            pkgs.castxml
            pkgs.jq
          ];

          shellHook = /* bash */ ''
            # ffi-clang is only bindings; it dlopen()s libclang at require time
            # and otherwise guesses at distro paths, none of which exist here.
            export LIBCLANG="${pkgs.libclang.lib}/lib/libclang${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}"
            export LIBCLANG_RESOURCE_DIR="${pkgs.libclang.lib}/lib/clang/${pkgs.lib.versions.major pkgs.libclang.version}"

            # libclang gets the command line verbatim -- none of the
            # cc-wrapper's NIX_CFLAGS_COMPILE reaches it -- so script.rb has to
            # be told every header root itself.
            export OPENCLOUD_INCLUDE_ROOTS="${pkgs.lib.concatStringsSep ":" ([
              "${pkgs.llvmPackages.libcxx.dev}/include/c++/v1"
              # Qt's headers are in qtbase's "out"; its "dev" holds only mkspecs.
              "${pkgs.qt6.qtbase}/include"
              "${pkgs.kdePackages.qtkeychain}/include"
            ] ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux
              "${pkgs.glibc.dev}/include")}"

            export BUNDLE_GEMFILE="$PWD/Gemfile"
            export BUNDLE_FROZEN=false
          '';
        };
      });
}
