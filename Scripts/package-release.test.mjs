import assert from "node:assert/strict";
import test from "node:test";
import {
  assertDescendant,
  parsePackagingMode,
  releasePaths,
  validateBuildNumber,
  validateReleaseVersion,
} from "./release-policy.mjs";

test("release mode is explicit and singular", () => {
  assert.equal(parsePackagingMode(["--adhoc"]), "adhoc");
  assert.equal(parsePackagingMode(["--notarize"]), "notarize");
  for (const invalid of [[], ["--unknown"], ["--adhoc", "--notarize"], ["--adhoc", "extra"]]) {
    assert.throws(() => parsePackagingMode(invalid));
  }
});

test("release versions are strict SemVer path components", () => {
  for (const valid of ["0.1.0", "1.2.3-beta.1", "10.20.30-rc.1+build.5"]) {
    assert.equal(validateReleaseVersion(valid), valid);
  }
  for (const invalid of ["1", "01.2.3", "1.02.3", "1.2.03", "1.2.3-01", "../../../victim", "1.2.3/../../victim", "v1.2.3", ""]) {
    assert.throws(() => validateReleaseVersion(invalid));
  }
});

test("build numbers are bounded positive integers", () => {
  assert.equal(validateBuildNumber("1"), "1");
  assert.equal(validateBuildNumber("999999999999999999"), "999999999999999999");
  for (const invalid of ["0", "01", "-1", "1.2", "../1", "", "1000000000000000000"]) {
    assert.throws(() => validateBuildNumber(invalid));
  }
});

test("every destructive release target remains below dist", () => {
  const paths = releasePaths("/tmp/scout-workspace", "1.2.3-beta.1", 42);
  for (const path of [paths.outputRoot, paths.zip, paths.dmg, paths.dmgStaging]) {
    assert.equal(path.startsWith(`${paths.distRoot}/`), true);
  }
  assert.throws(() => assertDescendant(paths.distRoot, paths.distRoot, "root"));
  assert.throws(() => assertDescendant(paths.distRoot, "/tmp/outside", "outside"));
});
