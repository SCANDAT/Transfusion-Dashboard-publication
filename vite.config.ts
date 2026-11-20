import { defineConfig, type Plugin, type UserConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import { readDashboard } from './scripts/dashboardData'

const fontLicenses = ['libre-caslon-text-OFL.txt', 'montserrat-OFL.txt', 'source-serif-4-OFL.txt']

function dashboardFiles(files: Map<string, Buffer>): Plugin {
  return {
    name: 'dashboard-data',
    configureServer(server) {
      const base = server.config.base
      server.middlewares.use((request, response, next) => {
        const pathname = request.url?.split('?')[0]
        const file = pathname?.startsWith(base) ? files.get(pathname.slice(base.length)) : undefined
        if (!file || (request.method !== 'GET' && request.method !== 'HEAD')) return next()
        response.setHeader('Content-Type', 'application/json; charset=utf-8')
        response.end(request.method === 'HEAD' ? undefined : file)
      })
    },
    generateBundle() {
      for (const [fileName, source] of files) this.emitFile({ type: 'asset', fileName, source })
      for (const name of fontLicenses) {
        const source = readFileSync(path.join(__dirname, 'src/assets/fonts', name))
        this.emitFile({ type: 'asset', fileName: 'assets/' + name, source })
      }
    },
  }
}

export default defineConfig((): UserConfig => {
  const data = readDashboard(path.join(__dirname, 'reader-data'))
  return {
    plugins: [react(), dashboardFiles(data.files)],
    publicDir: false,
    define: { 'import.meta.env.VITE_READER_DISPLAY_SHA256': JSON.stringify(data.manifestDigest) },
    resolve: { alias: { '@': path.resolve(__dirname, 'src') } },
    server: { host: '127.0.0.1', port: 3000 },
    preview: { host: '127.0.0.1', port: 4173 },
    build: {
      sourcemap: false, target: 'es2020', minify: 'esbuild',
      rollupOptions: { output: { manualChunks: { 'vendor-react': ['react', 'react-dom'] } } },
    },
  }
})
