# Fauxton

The web interface CouchDB ships, unmodified, copied from Apache CouchDB 3.5.3's
`/_utils` build. Served at `/_utils` by `zouch`, embedded in the binary by
`src/www_assets.zig`.

- Upstream: https://github.com/apache/couchdb-fauxton
- License: Apache-2.0, see `LICENSE` in this directory (the same license as zouch,
  so the two travel together without any relicensing). The license text and this
  note are not embedded in the binary, so ship `www/LICENSE` alongside any binary
  distribution.
- Nothing here is modified. If you update the build, regenerate the embedded copy
  with `python3 scripts/embed_www.py` and keep the filenames as the bundle emits
  them: `index.html` and its `dashboard.assets/` tree must stay in step, because
  the bundle loads its chunks and fonts by hashed name.
- `$ZOUCH_WWW` (or a `www` directory in the data directory) overrides this copy,
  which is how a newer Fauxton can be tried without rebuilding.

Bundled third-party libraries (React, lodash, CodeMirror and others) are inside
`dashboard.assets/js/vendor.*.js`; their licenses are those of the components,
all of which are compatible with Apache-2.0 distribution. See the upstream
repository's `package.json` for the exact dependency set.
