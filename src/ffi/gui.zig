pub const c = @cImport({
    @cInclude("app/app.h");
    @cInclude("renderer/renderer.h");
    @cInclude("ui/ui.h");
    @cInclude("player/playback_core.h");
});
