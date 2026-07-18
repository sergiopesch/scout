import { isAbsolute, relative, resolve, sep } from "node:path";

const numericIdentifier = "(?:0|[1-9]\\d*)";
const nonNumericIdentifier = "(?:\\d*[A-Za-z-][0-9A-Za-z-]*)";
const prereleaseIdentifier = `(?:${numericIdentifier}|${nonNumericIdentifier})`;
const semanticVersionPattern = new RegExp(
  `^${numericIdentifier}\\.${numericIdentifier}\\.${numericIdentifier}`
    + `(?:-${prereleaseIdentifier}(?:\\.${prereleaseIdentifier})*)?`
    + "(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$",
  "u",
);

export function parsePackagingMode(arguments_) {
  if (arguments_.length !== 1 || !["--adhoc", "--notarize"].includes(arguments_[0])) {
    throw new Error("Choose exactly one Scout packaging mode: --adhoc or --notarize");
  }
  return arguments_[0] === "--notarize" ? "notarize" : "adhoc";
}

export function validateReleaseVersion(value) {
  if (typeof value !== "string" || !semanticVersionPattern.test(value)) {
    throw new Error(`SCOUT_RELEASE_VERSION must be strict SemVer; observed ${JSON.stringify(value)}`);
  }
  return value;
}

export function validateBuildNumber(value) {
  if (typeof value !== "string" || !/^[1-9]\d{0,17}$/u.test(value)) {
    throw new Error("SCOUT_BUILD_NUMBER must be a positive integer of at most 18 digits");
  }
  return value;
}

export function assertDescendant(root, candidate, label) {
  const resolvedRoot = resolve(root);
  const resolvedCandidate = resolve(candidate);
  const pathFromRoot = relative(resolvedRoot, resolvedCandidate);
  if (
    pathFromRoot.length === 0
    || pathFromRoot === ".."
    || pathFromRoot.startsWith(`..${sep}`)
    || isAbsolute(pathFromRoot)
  ) {
    throw new Error(`${label} must remain inside ${resolvedRoot}`);
  }
  return resolvedCandidate;
}

export function releasePaths(workspace, version, processID = process.pid) {
  const validatedVersion = validateReleaseVersion(version);
  if (!Number.isSafeInteger(processID) || processID <= 0) {
    throw new Error("Release process identifier must be a positive safe integer");
  }

  const distRoot = resolve(workspace, "dist");
  return {
    distRoot,
    outputRoot: assertDescendant(
      distRoot,
      resolve(distRoot, `Scout-${validatedVersion}`),
      "Release output directory",
    ),
    zip: assertDescendant(
      distRoot,
      resolve(distRoot, `Scout-${validatedVersion}-macOS.zip`),
      "Release ZIP",
    ),
    dmg: assertDescendant(
      distRoot,
      resolve(distRoot, `Scout-${validatedVersion}-macOS.dmg`),
      "Release DMG",
    ),
    dmgStaging: assertDescendant(
      distRoot,
      resolve(distRoot, `.dmg-${processID}`),
      "DMG staging directory",
    ),
  };
}
