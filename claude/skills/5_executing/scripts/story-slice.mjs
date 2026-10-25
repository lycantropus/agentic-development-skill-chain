#!/usr/bin/env node
import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import { resolveInputs, checkExternalStories, externalStory } from "./resolve-inputs.mjs";
import { slice, parseStories } from "./document-parser.mjs";
function sliceMain([planPath, id]) {
  if (!planPath || !id) {
    console.error("usage: story-slice.mjs <wave-plan.md> <US-ID>");
    process.exit(2);
  }
  try {
    const text = readFileSync(planPath, "utf8");
    const inputs = resolveInputs(dirname(dirname(planPath)));
    checkExternalStories(inputs, parseStories(text));
    process.stdout.write(slice(text, id) + externalStory(inputs, id));
  } catch (error) {
    if (error.count === undefined) throw error;
    console.error(`story-slice.mjs: ${id} has ${error.count} sections in ${planPath} (need exactly 1)`);
    process.exit(1);
  }
}

const isMain = () => { try { return realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); } catch { return false; } };
if (isMain()) sliceMain(process.argv.slice(2));
