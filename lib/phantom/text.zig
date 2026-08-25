//! PhantomUI text engine (CPU, native-only). Parses TTF/OTF fonts, rasterizes
//! glyphs to alpha coverage bitmaps, caches them. Web text is HTML (slice B) and
//! does not use this module.
pub const builtin = @import("text/builtin.zig");
pub const Font = @import("text/Font.zig");
pub const Glyph = @import("text/raster.zig").Coverage;
pub const mono = @import("text/mono.zig");
/// Line layout: `layoutLine` measures and positions one run. Exported because a
/// caller that needs to break text itself, or to measure a run before drawing
/// it, otherwise cannot reach the function phantom uses for its own text.
pub const layout = @import("text/layout.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
