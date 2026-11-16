//! Single source of truth for the version string that `GET /` and
//! `zouch --version` report. `scripts/ci.sh` fails when this disagrees with
//! `.version` in `build.zig.zon`, and `zig build.zon` pins the same value for
//! the package metadata.

pub const string = "0.1.0";

/// The git commit the binary was built from, as CouchDB reports in `GET /`.
/// Overridden by the release script; the default marks a build that was not cut
/// from a tagged commit.
pub const git_sha = "unknown";
