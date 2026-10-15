#!/usr/bin/env node
import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { slice } from "./document-parser.mjs";
function sliceMain([planPath, id]) {
  if (!planPath || !id) {
    console.error("usage: story-slice.mjs <wave-plan.md> <US-ID>");
    process.exit(2);
  }
  try {
    process.stdout.write(slice(readFileSync(planPath, "utf8"), id));
  } catch (error) {
    if (error.count === undefined) throw error;
    console.error(`story-slice.mjs: ${id} has ${error.count} sections in ${planPath} (need exactly 1)`);
    process.exit(1);
  }
}

const isMain = () => { try { return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; } };
if (isMain()) sliceMain(process.argv.slice(2));
