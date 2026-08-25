//! Icon subsystem re-exports.
pub const path = @import("icon/path.zig");
pub const stroke = @import("icon/stroke.zig");
pub const builtin = @import("icon/builtin.zig");
pub const Id = builtin.Id;
pub const pathFor = builtin.pathFor;
pub const CellMark = builtin.CellMark;
pub const cellMarkFor = builtin.cellMarkFor;
pub const torii = builtin.torii;
pub const Point = path.Point;
pub const Verb = path.Verb;
pub const Path = path.Path;
pub const Builder = path.Builder;
pub const Cap = path.Cap;
pub const Join = path.Join;
pub const Stroke = path.Stroke;
pub const expand = stroke.expand;
