import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// Served from https://<owner>.github.io/airline-game/ in production.
export default defineConfig(({ command, isPreview }) => ({
  base: command === 'build' || isPreview ? '/airline-game/' : '/',
  plugins: [
    react(),
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
