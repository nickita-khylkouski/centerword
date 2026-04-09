#!/usr/bin/env node

import { createWriteStream, existsSync, mkdirSync, rmSync } from "node:fs";
import { homedir, platform, arch, tmpdir } from "node:os";
import { basename, join } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { spawnSync } from "node:child_process";

const repo = "nickita-khylkouski/centerword";
const appName = "CenterWord";
const assetPattern = /^CenterWord-.*-macos-arm64\.zip$/;
const targetDirectory = join(homedir(), "Applications");
const targetAppPath = join(targetDirectory, `${appName}.app`);

const command = process.argv[2] ?? "install";

if (platform() !== "darwin") {
  console.error("CenterWord only supports macOS.");
  process.exit(1);
}

if (arch() !== "arm64") {
  console.error("The published installer currently targets Apple Silicon Macs only.");
  process.exit(1);
}

if (command !== "install") {
  console.error("Usage: centerword [install]");
  process.exit(1);
}

const release = await fetchLatestRelease();
const asset = release.assets.find((candidate) => assetPattern.test(candidate.name));

if (!asset) {
  console.error("No macOS release asset was found. Open GitHub releases and install manually:");
  console.error(`https://github.com/${repo}/releases`);
  process.exit(1);
}

const workingDirectory = join(tmpdir(), `centerword-install-${Date.now()}`);
mkdirSync(workingDirectory, { recursive: true });
mkdirSync(targetDirectory, { recursive: true });

const downloadedZipPath = join(workingDirectory, basename(asset.name));
const extractedAppPath = join(workingDirectory, `${appName}.app`);

console.log(`Downloading ${asset.name} from ${release.tag_name}...`);
await downloadFile(asset.browser_download_url, downloadedZipPath);

run("ditto", ["-x", "-k", downloadedZipPath, workingDirectory]);

if (!existsSync(extractedAppPath)) {
  console.error("The downloaded release did not contain CenterWord.app.");
  process.exit(1);
}

rmSync(targetAppPath, { recursive: true, force: true });
run("cp", ["-R", extractedAppPath, targetAppPath]);
run("open", [targetAppPath]);

console.log(`Installed ${targetAppPath}`);
console.log("First run:");
console.log("- Copy text anywhere");
console.log("- Grant Input Monitoring if macOS asks");
console.log("- Press Cmd+Option+S to open the popup reader");

async function fetchLatestRelease() {
  const response = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
    headers: {
      "User-Agent": "centerword-app-installer",
      "Accept": "application/vnd.github+json"
    }
  });

  if (!response.ok) {
    console.error(`Failed to fetch latest release metadata (${response.status}).`);
    process.exit(1);
  }

  return response.json();
}

async function downloadFile(url, destinationPath) {
  const response = await fetch(url, {
    headers: {
      "User-Agent": "centerword-app-installer"
    }
  });

  if (!response.ok || !response.body) {
    console.error(`Failed to download release asset (${response.status}).`);
    process.exit(1);
  }

  const output = createWriteStream(destinationPath);
  await pipeline(Readable.fromWeb(response.body), output);
}

function run(commandName, args) {
  const result = spawnSync(commandName, args, { stdio: "inherit" });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}
