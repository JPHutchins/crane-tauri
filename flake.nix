{
  description = "Build Tauri v2 apps with crane dependency caching";

  inputs = { };

  outputs =
    { ... }:
    {
      lib.buildTauriApp = import ./lib/buildTauriApp.nix;

      templates.default = {
        description = "Tauri v2 app with Nix build using crane-tauri";
        path = ./templates/default;
      };
    };
}
