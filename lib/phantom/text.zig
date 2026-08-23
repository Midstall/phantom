//! PhantomUI text engine (CPU, native-only). Parses TTF/OTF fonts, rasterizes
//! glyphs to alpha coverage bitmaps, caches them. Web text is HTML (slice B) and
//! does not use this module.
pub const builtin = @import("text/builtin.zig");
pub const Font = @import("text/Font.zig");
pub const Glyph = @import("text/raster.zig").Coverage;
pub const mono = @import("text/mono.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
