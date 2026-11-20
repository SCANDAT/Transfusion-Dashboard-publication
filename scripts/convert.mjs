import { createHash } from 'node:crypto'
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createServer } from 'vite'
import { displayKeys, validateDisplayManifest } from '../src/data/displayManifest.mjs'

const root = fileURLToPath(new URL('..', import.meta.url))
const checksum = bytes => createHash('sha256').update(bytes).digest('hex')
const encode = value => Buffer.from(JSON.stringify(value) + '\n', 'utf8')

function readJson(directory, name, expected) {
  const file = path.join(directory, name)
  if (realpathSync(file) !== file || !lstatSync(file).isFile()) throw new Error('Expected a regular result file')
  const bytes = readFileSync(file)
  const sha256 = checksum(bytes)
  if (expected !== undefined && sha256 !== expected) throw new Error('Result checksum mismatch')
  return { data: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)), sha256 }
}

async function convert(args) {
  if (args.length !== 3 && args.length !== 5) {
    throw new Error('Usage: node scripts/convert.mjs <tables-directory> <new-display-directory> <release-id> [<recorded-method-code> <recorded-unit-code>]')
  }
  const [input, output, releaseId, methodAdoptionStatus, nativeUnitStatus] = args
  const directory = realpathSync(input)
  const destination = path.join(realpathSync(path.dirname(path.resolve(output))), path.basename(path.resolve(output)))
  const relative = path.relative(directory, destination)
  if (existsSync(destination) || !(path.isAbsolute(relative) || relative === '..' || relative.startsWith('..' + path.sep))) {
    throw new Error('Use a new output directory outside the input directory')
  }
  const keys = displayKeys()
  const manifest = validateDisplayManifest({ schemaVersion: 'transfusion-dashboard/display-v2', releaseId,
    assets: Object.fromEntries(keys.map(key => [key, null])) })
  const core = readJson(directory, 'release.json')
  const supplement = readJson(directory, 'supplements.json')
  const loess = readJson(directory, 'loess.json')
  const runtime = await createServer({ configFile: false, envFile: false, root, appType: 'custom',
    server: { middlewareMode: true, hmr: false, watch: null }, optimizeDeps: { noDiscovery: true, include: [] } })
  try {
    const { prepareSources, projectSelection } = await runtime.ssrLoadModule('/scripts/display_projection.ts')
    const sources = prepareSources(core.data, supplement.data, loess.data, core.sha256)
    const sourceId = sources.release.manifest.releaseId
    function readReference(ref) {
      const parts = ref.url.split('/')
      if (ref.releaseId !== sourceId || parts.length < 4 || parts[0] !== 'data' || parts[1] !== 'releases' ||
        parts[2] !== sourceId || !parts.slice(3, -1).every(part => /^[A-Za-z0-9_-]+$/.test(part)) ||
        !/^[A-Za-z0-9_-][A-Za-z0-9._-]*[.]json$/.test(parts.at(-1))) throw new Error('Unexpected result reference')
      return readJson(directory, ref.url, ref.sha256).data
    }
    const archived = methodAdoptionStatus && nativeUnitStatus ? { methodAdoptionStatus, nativeUnitStatus, coreManifestSha256: core.sha256 } : undefined
    const files = new Map()
    for (const key of keys) {
      const bytes = encode(projectSelection(key, sources, readReference, archived, true))
      manifest.assets[key] = checksum(bytes)
      files.set('results/' + key + '.json', bytes)
    }
    files.set('reader.json', encode(manifest))
    const stage = mkdtempSync(path.join(path.dirname(destination), '.display-'))
    for (const [name, bytes] of files) {
      const file = path.join(stage, name)
      mkdirSync(path.dirname(file), { recursive: true })
      writeFileSync(file, bytes, { flag: 'wx' })
    }
    renameSync(stage, destination)
  } finally {
    await runtime.close()
  }
}
convert(process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode = 1 })
