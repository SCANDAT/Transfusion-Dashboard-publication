import { createHash } from 'node:crypto'
import { lstatSync, readFileSync, readdirSync } from 'node:fs'
import path from 'node:path'
import { parseDisplayJson, validateDisplayManifest, validateStudyScope } from '../src/data/displayManifest.mjs'
import { validateDashboardAsset } from '../src/data/validateDisplay'

function requireDirectory(directory: string) {
  if (!lstatSync(directory).isDirectory()) throw new Error('Expected a dashboard data directory')
}

function readFile(file: string) {
  if (!lstatSync(file).isFile()) throw new Error('Expected a regular dashboard file')
  return readFileSync(file)
}

function parse(bytes: Buffer) {
  return parseDisplayJson(new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes))
}

function digest(bytes: Buffer) {
  return createHash('sha256').update(bytes).digest('hex')
}

export function readDashboard(directory: string) {
  requireDirectory(directory)
  const index = readFile(path.join(directory, 'reader.json'))
  const manifest = validateDisplayManifest(parse(index))
  const expected = new Map<string, [string, string]>()
  const folders = new Set<string>()
  for (const [key, checksum] of Object.entries(manifest.assets)) {
    if (checksum === null) throw new Error('Missing data for dashboard selection ' + key)
    const name = 'results/' + key + '.json'
    expected.set(name, [key, checksum])
    for (let parent = path.posix.dirname(name); parent !== '.'; parent = path.posix.dirname(parent)) {
      folders.add(parent)
    }
  }

  const found = new Set<string>()
  function visit(relative: string) {
    for (const entry of readdirSync(path.join(directory, relative), { withFileTypes: true })) {
      const name = relative ? relative + '/' + entry.name : entry.name
      if (entry.isDirectory() && !entry.isSymbolicLink() && folders.has(name)) visit(name)
      else if (entry.isFile() && !entry.isSymbolicLink() && (name === 'reader.json' || expected.has(name))) found.add(name)
      else throw new Error('Unexpected file or directory in reader-data')
    }
  }
  visit('')
  if (found.size !== expected.size + 1) throw new Error('Incomplete dashboard data directory')

  const files = new Map<string, Buffer>([['reader.json', index]])
  for (const [name, [key, checksum]] of expected) {
    const bytes = readFile(path.join(directory, name))
    if (digest(bytes) !== checksum) throw new Error('Dashboard checksum mismatch for ' + key)
    const value = parse(bytes)
    validateDashboardAsset(key, value)
    if (key.startsWith('study/')) validateStudyScope(value, manifest)
    files.set(name, bytes)
  }
  return { files, manifestDigest: digest(index) }
}
