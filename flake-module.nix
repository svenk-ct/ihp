/*
flake-parts module for IHP apps
can be imported in a flake inside an IHP app repo
*/

# with ihpFlake we receive arguments from the IHP flake in this repo itself
ihpFlake:

# these arguments on the other hand are from the flake where this module is imported
# i.e. from the flake of any particular IHP app
{ flake-parts-lib, lib, config, ... }:

{

    imports = [
        # we import devenv from ihpFlake so we can lock the version on IHP's side
        ihpFlake.inputs.devenv.flakeModule
    ];

    # the app can configure IHP using these options from its flake
    options.perSystem = flake-parts-lib.mkPerSystemOption (
        { config, pkgs, system, ...}: {
            options.ihp.enable = lib.mkEnableOption "Enable IHP support";

            options.ihp.ghcCompiler = lib.mkOption {
                default = pkgs.haskell.packages.ghc944;
                description = ''
                    The GHC compiler to use for IHP.
                '';
            };

            options.ihp.haskellPackages = lib.mkOption {
                default = p: with p; [
                    cabal-install
                    base
                    wai
                    text
                    hlint
                    ihp
                ];
                description = ''
                    List of Haskell packages to be installed in the IHP environment.
                '';
            };

            options.ihp.projectPath = lib.mkOption {
                type = lib.types.path;
                description = ''
                    Path to the IHP project.
                '';
            };

            options.ihp.dontCheckPackages = lib.mkOption {
                default = [];
                description = ''
                    List of Haskell package names whose tests are skipped during build
                '';
            };

            options.ihp.doJailbreakPackages = lib.mkOption {
                default = [];
                description = ''
                    List of Haskell package names who are jailbreaked before build
                '';
            };

            options.ihp.dontHaddockPackages = lib.mkOption {
                default = [];
                description = ''
                    List of Haskell package names whose haddock is not build during app build
                '';
            };
        }
    );

    config = {
        perSystem = { self', lib, pkgs, system, config, ... }: let
            ihp = ihpFlake.inputs.self;
            ghcCompiler = import "${ihp}/NixSupport/mkGhcCompiler.nix" {
                inherit pkgs;
                inherit (config.ihp) ghcCompiler dontCheckPackages doJailbreakPackages dontHaddockPackages;
                ihp = ihp;
                haskellPackagesDir = config.ihp.projectPath + "/Config/nix/haskell-packages";
            };
        in lib.mkIf config.ihp.enable {
            _module.args.pkgs = import ihpFlake.inputs.nixpkgs { inherit system; };

            # release build package
            packages.default = import "${ihp}/NixSupport/default.nix" {
                ihp = ihp;
                haskellDeps = config.ihp.haskellPackages;
                otherDeps = p: config.devenv.shells.default.packages;  # that's pretty oof
                projectPath = config.ihp.projectPath;

                # Dev tools are not needed in the release build
                includeDevTools = false;

                # Set optimized = true to get more optimized binaries, but slower build times
                # TODO make configurable via option
                optimized = false;
            };

            devenv.shells.default = let cfg = config.ihp; in lib.mkIf cfg.enable {
                packages = [ ghcCompiler.ihp pkgs.postgresql_13 ];

                /*
                we currently don't use devenv containers, and they break nix flake show
                without the proper inputs set
                https://github.com/cachix/devenv/issues/528
                */
                containers = lib.mkForce {};

                languages.haskell.enable = true;
                languages.haskell.package = ghcCompiler.ghc.withPackages cfg.haskellPackages;

                scripts.start.exec = ''
                    ${ghcCompiler.ihp}/bin/RunDevServer
                '';

                processes.devServer.exec = "start";

                # Disabled for now
                # Can be re-enabled once postgres is provided by devenv instead of IHP
                # env.IHP_DEVENV = "1";
                # env.DATABASE_URL = "postgres:///app?host=${config.env.PGHOST}";

                # Disabled for now
                # As the devenv postgres uses a different location for the socket
                # this would break lots of known commands such as `make db`
                services.postgres.enable = false;
                services.postgres.initialDatabases = [
                    {
                    name = "app";
                    schema = pkgs.runCommand "ihp-schema" {} ''
                        touch $out

                        echo "-- IHPSchema.sql" >> $out
                        echo "" >> $out
                        cat ${./lib/IHP/IHPSchema.sql} | sed -e s'/--.*//' | sed -e s'/$/\\/' >> $out
                        echo "" >> $out
                        echo "-- Application/Schema.sql" >> $out
                        echo "" >> $out
                        cat ${cfg.projectPath + "/Application/Schema.sql"} | sed -e s'/--.*//' | sed -e s'/$/\\/' >> $out
                        echo "" >> $out
                        echo "-- Application/Fixtures.sql" >> $out
                        echo "" >> $out
                        cat ${cfg.projectPath + "/Application/Fixtures.sql"} | sed -e s'/--.*//' | sed -e s'/$/\\/' >> $out
                    '';
                    }
                ];
            };
        };

        flake.nixConfig = {
            extra-substituters = "https://digitallyinduced.cachix.org";
            extra-trusted-public-keys = "digitallyinduced.cachix.org-1:y+wQvrnxQ+PdEsCt91rmvv39qRCYzEgGQaldK26hCKE=";
        };
    };

}
