const { execFileSync } = require("node:child_process");
const fs = require("node:fs");

function getInput(name) {
  return process.env[`INPUT_${name.replace(/ /g, "_").toUpperCase()}`] ?? "";
}

function setOutput(name, value) {
  const outputFile = process.env.GITHUB_OUTPUT;
  if (!outputFile) {
    throw new Error("GITHUB_OUTPUT is not set");
  }

  if (String(value).includes("\n")) {
    const delimiter = `commander_${name}_${process.pid}`;
    fs.appendFileSync(outputFile, `${name}<<${delimiter}\n${value}\n${delimiter}\n`);
  } else {
    fs.appendFileSync(outputFile, `${name}=${value}\n`);
  }
}

function matches(path, pattern) {
  if (pattern.endsWith("/**")) {
    const prefix = pattern.slice(0, -3);
    return path === prefix || path.startsWith(`${prefix}/`);
  }
  return path === pattern;
}

const force = getInput("force").toLowerCase() === "true";
const head = getInput("head").trim();
const base = getInput("base").trim();
const patterns = getInput("paths")
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean);

if (force) {
  console.log("Release forced by workflow input.");
  setOutput("release", "true");
  setOutput("changed-files", "");
  process.exit(0);
}

if (!head) {
  throw new Error("head input is required");
}

if (!base || /^0+$/.test(base)) {
  console.log("No usable base SHA; conservatively requiring a release.");
  setOutput("release", "true");
  setOutput("changed-files", "");
  process.exit(0);
}

const changedFiles = execFileSync(
  "git",
  ["diff", "--name-only", "--diff-filter=ACMR", base, head],
  { encoding: "utf8" }
)
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean);

const releaseFiles = changedFiles.filter((path) =>
  patterns.some((pattern) => matches(path, pattern))
);

console.log("Changed files:");
for (const path of changedFiles) {
  console.log(`  ${path}`);
}

if (releaseFiles.length > 0) {
  console.log("Release-affecting files:");
  for (const path of releaseFiles) {
    console.log(`  ${path}`);
  }
} else {
  console.log("No release-affecting files changed.");
}

setOutput("release", releaseFiles.length > 0 ? "true" : "false");
setOutput("changed-files", changedFiles.join("\n"));
