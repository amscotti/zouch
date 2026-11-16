test {
    _ = @import("util/checksum.zig");
    _ = @import("doc/rev.zig");
    _ = @import("doc/tree.zig");
    _ = @import("store/format.zig");
    _ = @import("store/db.zig");
    _ = @import("http/jsonw.zig");
    _ = @import("http/server.zig");
    _ = @import("views/quickjs.zig");
    _ = @import("views/collate.zig");
    _ = @import("views/hnsw.zig");
    _ = @import("replicator.zig");
}
