const std = @import("std");
const httpz = @import("httpz");

const Ts = extern struct { sec: i64, nsec: i64 };
extern "c" fn nanosleep(req: *const Ts, rem: ?*Ts) c_int;

pub fn main(init: std.process.Init) !void {
    var server = try httpz.Server(void).init(init.io, init.gpa, .{
        .address = .localhost(8099),
    }, {});
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("/get", get, .{});
    router.get("/feed", feed, .{});
    std.debug.print("listening 8099\n", .{});
    try server.listen();
}

fn get(_: *httpz.Request, res: *httpz.Response) !void {
    res.body = "{\"ok\":true}";
}

fn feed(_: *httpz.Request, res: *httpz.Response) !void {
    var ts = Ts{ .sec = 10, .nsec = 0 };
    _ = nanosleep(&ts, null);
    res.body = "{}";
}
