import { defineConfig } from 'vite';

export default defineConfig({
  // The site is published at https://alex-sherwin.github.io/godot-ai-test/.
  // CI overrides this with `--base="${{ steps.pages.outputs.base_path }}/"` so
  // the workflow keeps working if the repo is ever renamed; the trailing slash
  // is required in both places.
  base: '/godot-ai-test/',

  build: {
    target: 'es2022',
    // The Godot export lives in `public/` and is copied verbatim — never
    // hashed, inlined or transformed. Godot derives `index.wasm` / `index.pck`
    // from its own basename at runtime, so those filenames must not change.
    assetsInlineLimit: 0,
  },
});
