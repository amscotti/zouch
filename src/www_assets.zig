//! The Fauxton build served at `/_utils`, embedded so a single binary carries
//! its own UI. Generated from `src/www/` (see its README) by `scripts/embed_www.py`;
//! do not edit by hand.

const std = @import("std");

pub const Asset = struct { path: []const u8, bytes: []const u8 };

pub const assets = [_]Asset{
    .{ .path = "dashboard.assets/css/styles.1f430a8a0c5beabcef6b.css", .bytes = @embedFile("www/dashboard.assets/css/styles.1f430a8a0c5beabcef6b.css") },
    .{ .path = "dashboard.assets/css/styles.36c4d575204c3cda9131.css", .bytes = @embedFile("www/dashboard.assets/css/styles.36c4d575204c3cda9131.css") },
    .{ .path = "dashboard.assets/fonts/fauxtonicon9.ttf", .bytes = @embedFile("www/dashboard.assets/fonts/fauxtonicon9.ttf") },
    .{ .path = "dashboard.assets/fonts/fauxtonicon9.woff", .bytes = @embedFile("www/dashboard.assets/fonts/fauxtonicon9.woff") },
    .{ .path = "dashboard.assets/fonts/fauxtonicon9.woff2", .bytes = @embedFile("www/dashboard.assets/fonts/fauxtonicon9.woff2") },
    .{ .path = "dashboard.assets/img/couch-watermark.png", .bytes = @embedFile("www/dashboard.assets/img/couch-watermark.png") },
    .{ .path = "dashboard.assets/img/couchdb-logo.png", .bytes = @embedFile("www/dashboard.assets/img/couchdb-logo.png") },
    .{ .path = "dashboard.assets/img/idle_fingers-1.png", .bytes = @embedFile("www/dashboard.assets/img/idle_fingers-1.png") },
    .{ .path = "dashboard.assets/js/5bfaed866eef8fb20f4d7aef93a0ef14.js", .bytes = @embedFile("www/dashboard.assets/js/5bfaed866eef8fb20f4d7aef93a0ef14.js") },
    .{ .path = "dashboard.assets/js/bundle.36c4d575204c3cda9131.js", .bytes = @embedFile("www/dashboard.assets/js/bundle.36c4d575204c3cda9131.js") },
    .{ .path = "dashboard.assets/js/cb24550074912ba2d7419fd38824e716.js", .bytes = @embedFile("www/dashboard.assets/js/cb24550074912ba2d7419fd38824e716.js") },
    .{ .path = "dashboard.assets/js/manifest.6787559ca43ea1f7037e.js", .bytes = @embedFile("www/dashboard.assets/js/manifest.6787559ca43ea1f7037e.js") },
    .{ .path = "dashboard.assets/js/vendor.1f430a8a0c5beabcef6b.js", .bytes = @embedFile("www/dashboard.assets/js/vendor.1f430a8a0c5beabcef6b.js") },
    .{ .path = "index.html", .bytes = @embedFile("www/index.html") },
};

pub fn find(path: []const u8) ?[]const u8 {
    for (&assets) |*a| {
        if (std.mem.eql(u8, a.path, path)) return a.bytes;
    }
    return null;
}
