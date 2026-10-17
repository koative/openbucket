import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://openbucket.koative.com',
  output: 'static',
  devToolbar: { enabled: false },
  trailingSlash: 'always',
  // Screenshots and the app icon are imported from the repository root, outside site/.
  vite: { server: { fs: { allow: ['..'] } } },
});
