const std = @import("std");

const Self = @This();
const Renderer = @import("Renderer.zig");
const RID = Renderer.RID;
const Format = Renderer.Format;

const rdr = Renderer.rdr;

rid: RID,
