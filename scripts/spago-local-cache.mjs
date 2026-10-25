import os from "node:os";
import path from "node:path";
import { syncBuiltinESMExports } from "node:module";

const projectLocalHome = path.resolve(".cache/spago-home");
process.env.PATH = `${path.resolve("node_modules/.bin")}${path.delimiter}${process.env.PATH ?? ""}`;
os.homedir = () => projectLocalHome;
syncBuiltinESMExports();

await import("../node_modules/spago/bin/bundle.js");
