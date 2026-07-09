import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectDirectory = path.resolve(scriptDirectory, "..");
const require = createRequire(path.join(projectDirectory, "ArgusWeb/package.json"));
const { build } = require("esbuild");

await build({
  entryPoints: [path.join(projectDirectory, "ArgusWeb/src/pierre-diffs-entry.js")],
  outfile: path.join(projectDirectory, "Argus/Resources/pierre-diffs-bundle.js"),
  bundle: true,
  format: "iife",
  platform: "browser",
  target: "safari17",
  minify: true,
  legalComments: "none",
  define: {
    "process.env.NODE_ENV": '"production"',
  },
});
