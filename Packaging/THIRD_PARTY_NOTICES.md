# Scout third-party notices

Scout's packaged Gateway includes a self-contained Node.js runtime and the JavaScript dependencies
recorded in `Gateway/package-lock.json` and `Gateway/sbom.cdx.json`.

- Node.js is distributed under the MIT license and includes third-party components under their
  respective licenses. Release operators must provide the matching upstream Node.js `LICENSE` file
  through `SCOUT_NODE_LICENSE_PATH` for Developer ID builds.
- JavaScript dependency names, versions, package URLs, hashes, and declared licenses are recorded in
  the generated CycloneDX SBOM bundled with each release.

Scout itself is not granted a public distribution license by this notice. Repository owners must add
the intended project license before making the repository or binaries public.
