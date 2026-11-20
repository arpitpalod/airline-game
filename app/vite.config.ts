import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// Each build gets an id, baked into the app and written to version.json. An open app compares the two and offers to update.
const BUILD = (process.env.GITHUB_SHA ?? '').slice(0, 12) || Date.now().toString(36);

// Served from https://<owner>.github.io/airline-game/ in production.
export default defineConfig(({ command, isPreview }) => ({
  base: command === 'build' || isPreview ? '/airline-game/' : '/',
  define: { __BUILD__: JSON.stringify(BUILD) },
  plugins: [
    react(),
    { name: 'version-file', generateBundle() { this.emitFile({ type: 'asset', fileName: 'version.json', source: JSON.stringify({ build: BUILD }) }); } },
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['favicon.svg', 'apple-touch-icon.png'],
      manifest: {
        name: 'Airline Game',
        short_name: 'Airline',
        description: 'Run an airline against your colleagues.',
        theme_color: '#0E7C70',
        background_color: '#F2F4F7',
        display: 'standalone',
        start_url: '.',
        scope: '.',
        icons: [
          { src: 'icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: 'icon-512.png', sizes: '512x512', type: 'image/png' },
          { src: 'icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,svg,png,woff2}'],
        navigateFallback: 'index.html',
        runtimeCaching: [],   // game data always comes live from the server
      },
    }),
  ],
  build: { chunkSizeWarningLimit: 900 },
}));
