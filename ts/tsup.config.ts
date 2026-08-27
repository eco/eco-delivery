import {defineConfig} from "tsup";

export default defineConfig({
  entry: ["src/index.ts", "src/evm.ts", "src/svm.ts"],
  format: ["esm", "cjs"],
  dts: true,
  clean: true,
  sourcemap: true,
  treeshake: true,
});
