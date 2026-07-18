# Scout third-party notices

Scout's packaged Gateway includes a self-contained Node.js runtime and the JavaScript dependencies
recorded in `Gateway/package-lock.json` and `Gateway/sbom.cdx.json`.

- Node.js is distributed under the MIT license and includes third-party components under their
  respective licenses. Release operators must provide the matching upstream Node.js `LICENSE` file
  through `SCOUT_NODE_LICENSE_PATH` for Developer ID builds.
- JavaScript dependency names, versions, package URLs, hashes, and declared licenses are recorded in
  the build-specific CycloneDX SBOM bundled with each release. Complete installed production
  dependency license and notice texts are bundled as `GATEWAY_THIRD_PARTY_LICENSES.txt` and are
  regenerated deterministically from the pinned lockfile before Gateway bundling.

Scout-owned source remains all rights reserved under the repository `LICENSE`; identified third-party
components remain governed by their respective terms. Public source visibility and this notice grant
no permission to redistribute Scout-owned source or binaries. Distributable builds require the
matching Node.js license, complete Gateway dependency licenses, this notice, and the generated SBOM.
