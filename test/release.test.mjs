// The release scripts: scripts/check-version.py (the version check), scripts/check-bump.py (the pull
// request's version gate) and scripts/build-zip.py (the deterministic zip and SHA256SUMS). They are run as the release workflow runs them, on
// copies of this repository's files in a temporary directory, so a test can damage a file
// without touching the real one.
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, it } from './lib/suite.mjs'
import { expect } from './lib/expect.mjs'

const ROOT = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '')
// The zip made from syntheticRepo() below with scripts/build-zip.py. Pinned here so that a change to the
// container (header fields, order, stamp) shows as a changed hash, not as a quiet change of every release.
const SYNTHETIC_SIZE = 574
const SYNTHETIC_SHA256 = '034b5ae998373fc78ed0935e12ec3bb87e8564abea1e7751cfcdf73efd834514'

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')

const temp = () => mkdtempSync(join(tmpdir(), 'toawowchar-addon-'))

/** A copy of what the scripts read: the addon folder and the changelog. */
function copyRepo(into = temp()) {
  mkdirSync(join(into, 'toawowchar'), { recursive: true })
  cpSync(join(ROOT, 'toawowchar'), join(into, 'toawowchar'), { recursive: true })
  cpSync(join(ROOT, 'CHANGELOG.md'), join(into, 'CHANGELOG.md'))
  return into
}

/** A tiny repository with fixed contents: the zip made from it has a fixed sha256. */
function syntheticRepo() {
  const dir = temp()
  mkdirSync(join(dir, 'toawowchar'))
  writeFileSync(join(dir, 'toawowchar', 'toawowchar.toc'), '## Interface: 11507, 16001\n## Title: toawowchar\n## Version: 1.2.3\ntoawowchar.lua\n')
  writeFileSync(join(dir, 'toawowchar', 'toawowchar.lua'), '-- toawowchar 1.2.3\nlocal ADDON_VERSION = "1.2.3"\nreturn 1\n')
  writeFileSync(join(dir, 'toawowchar', 'README.md'), '# toawowchar\n\nVersion 1.2.3, for the tests.\n')
  writeFileSync(join(dir, 'CHANGELOG.md'), '# Changelog\n\n## [Unreleased]\n\n## [1.2.3] - 2026-01-02\n')
  return dir
}

const edit = (dir, file, change) => {
  const path = join(dir, file)
  writeFileSync(path, change(readFileSync(path, 'utf8')))
}

function py(script, args, { env = {}, shell } = {}) {
  const file = join(ROOT, 'scripts', script)
  const full = { ...process.env, ...env }
  const r = shell
    ? spawnSync('sh', ['-c', `${shell} python3 "${file}" ${args.map(a => `"${a}"`).join(' ')}`], { encoding: 'utf8', env: full })
    : spawnSync('python3', [file, ...args], { encoding: 'utf8', env: full })
  if (r.error) throw r.error
  return r
}

const check = (root, ...extra) => py('check-version.py', ['--root', root, ...extra])
const build = (root, out, opts) => py('build-zip.py', ['--root', root, '--out', out], opts)

// ── The version check ──────────────────────────────────────────────────────

describe('scripts/check-version.py', () => {
  it('passes on this repository, and says so', () => {
    const r = py('check-version.py', [])
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
    expect(r.stdout).toMatch(/^version \d+\.\d+\.\d+: OK\n$/)
  })

  it('passes with the tag that matches the version', () => {
    const dir = copyRepo()
    const version = /^## Version: (\S+)$/m.exec(readFileSync(join(dir, 'toawowchar/toawowchar.toc'), 'utf8'))[1]
    const r = check(dir, `v${version}`)
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
  })

  it.each([
    ['the TOC', 'toawowchar/toawowchar.toc', s => s.replace(/^## Version: .*$/m, '## Version: 9.9.9'), /Lua's ADDON_VERSION is \d+\.\d+\.\d+, the TOC's ## Version is 9\.9\.9/],
    ['the Lua', 'toawowchar/toawowchar.lua', s => s.replace(/^local ADDON_VERSION = "[^"]*"/m, 'local ADDON_VERSION = "9.9.9"'), /Lua's ADDON_VERSION is 9\.9\.9/],
    ['the README', 'toawowchar/README.md', s => s.replace(/^Version \d+\.\d+\.\d+/m, 'Version 9.9.9'), /README's version line is 9\.9\.9/],
    ['the changelog', 'CHANGELOG.md', s => s.replace(/^## \[(\d+\.\d+\.\d+)\] - /m, '## [9.9.9] - '), /CHANGELOG\.md: the newest entry is 9\.9\.9/],
  ])('fails when %s names another version than the others', (_who, file, change, message) => {
    const dir = copyRepo()
    edit(dir, file, change)
    const r = check(dir)
    expect(r.status).toBe(1)
    expect(r.stderr).toMatch(message)
    expect(r.stdout).toContain('FAILED')
  })

  it('fails when the first line of the Lua names another version, or is not `-- toawowchar X.Y.Z`', () => {
    for (const [change, message] of [
      [s => s.replace(/^-- toawowchar \S+/, '-- toawowchar 0.0.1'), /Lua's first line says 0\.0\.1, the TOC's ## Version is \d+\.\d+\.\d+/],
      [s => s.replace(/^-- toawowchar \S+\n/, ''), /Lua's first line says no version/],
      [s => s.replace(/^-- toawowchar /, '--toawowchar '), /Lua's first line says no version/],
      [s => `\n${s}`, /Lua's first line says no version/],
    ]) {
      const dir = copyRepo()
      edit(dir, 'toawowchar/toawowchar.lua', change)
      const r = check(dir)
      expect(r.status, String(change)).toBe(1)
      expect(r.stderr, String(change)).toMatch(message)
    }
  })

  it('fails when the README has no version line, the Lua no ADDON_VERSION, the TOC no ## Version', () => {
    for (const [file, change, message] of [
      ['toawowchar/README.md', s => s.replace(/^Version \d+\.\d+\.\d+/m, 'Status'), /README's version line is missing/],
      ['toawowchar/toawowchar.lua', s => s.replace('local ADDON_VERSION =', 'local VERSION ='), /ADDON_VERSION is missing/],
      ['toawowchar/toawowchar.toc', s => s.replace(/^## Version: .*\n/m, ''), /no ## Version: line/],
      ['CHANGELOG.md', s => s.replace(/^## \[\d+\.\d+\.\d+\].*$/gm, ''), /newest entry is missing/],
    ]) {
      const dir = copyRepo()
      edit(dir, file, change)
      const r = check(dir)
      expect(r.status, file).toBe(1)
      expect(r.stderr, file).toMatch(message)
    }
  })

  it('fails when a file is missing, and names it', () => {
    const dir = copyRepo()
    rmSync(join(dir, 'toawowchar/README.md'))
    const r = check(dir)
    expect(r.status).toBe(1)
    expect(r.stderr).toContain('cannot read toawowchar/README.md')
  })

  it.each([
    ['1.2', 'MAJOR.MINOR.PATCH'],
    ['1.2.3.4', 'MAJOR.MINOR.PATCH'],
    ['01.2.3', 'MAJOR.MINOR.PATCH'],
    ['1.2.3-beta', 'MAJOR.MINOR.PATCH'],
    ['v1.2.3', 'MAJOR.MINOR.PATCH'],
  ])('fails for a version that is not MAJOR.MINOR.PATCH: %s', (version, message) => {
    const dir = copyRepo()
    edit(dir, 'toawowchar/toawowchar.toc', s => s.replace(/^## Version: .*$/m, `## Version: ${version}`))
    const r = check(dir)
    expect(r.status).toBe(1)
    expect(r.stderr).toContain(message)
  })

  it('reports every problem, not only the first', () => {
    const dir = copyRepo()
    edit(dir, 'toawowchar/toawowchar.lua', s => s.replace(/^local ADDON_VERSION = "[^"]*"/m, 'local ADDON_VERSION = "9.9.9"'))
    edit(dir, 'toawowchar/README.md', s => s.replace(/^Version \d+\.\d+\.\d+/m, 'Version 8.8.8'))
    edit(dir, 'toawowchar/toawowchar.toc', s => s.replace(/^## Interface: .*$/m, '## Interface: abc'))
    const r = check(dir)
    expect(r.status).toBe(1)
    expect(r.stderr.trim().split('\n')).toHaveLength(3)
  })

  describe('the ## Interface: list', () => {
    const withInterface = (value) => {
      const dir = copyRepo()
      edit(dir, 'toawowchar/toawowchar.toc', s => s.replace(/^## Interface: .*$/m, `## Interface: ${value}`))
      return check(dir)
    }

    it.each(['16001', '11507, 16001', '11507,20505,120105', '10000', '999999'])('accepts %s', (value) => {
      const r = withInterface(value)
      expect(r.stderr).toBe('')
      expect(r.status).toBe(0)
    })

    it.each([
      ['', 'is not a whole number'],
      ['abc', 'is not a whole number'],
      ['16001,', 'is not a whole number'],
      ['16001;11507', 'is not a whole number'],
      ['1.5', 'is not a whole number'],
      ['-16001', 'is not a whole number'],
      ['9999', 'is outside 10000 to 999999'],
      ['1000000', 'is outside 10000 to 999999'],
      ['16001, 16001', 'more than once'],
    ])('refuses "%s"', (value, message) => {
      const r = withInterface(value)
      expect(r.status).toBe(1)
      expect(r.stderr).toContain(message)
    })

    it('refuses a TOC with no ## Interface: line at all', () => {
      const dir = copyRepo()
      edit(dir, 'toawowchar/toawowchar.toc', s => s.replace(/^## Interface: .*\n/m, ''))
      const r = check(dir)
      expect(r.status).toBe(1)
      expect(r.stderr).toContain('no ## Interface: line')
    })
  })

  it('refuses a TOC that loads a file the zip does not contain', () => {
    const dir = copyRepo()
    edit(dir, 'toawowchar/toawowchar.toc', s => `${s}extra.lua\n`)
    const r = check(dir)
    expect(r.status).toBe(1)
    expect(r.stderr).toContain('the TOC loads extra.lua, which the zip does not contain')
  })

  describe('with a tag', () => {
    it('refuses a tag of another version', () => {
      const r = check(copyRepo(), 'v9.9.9')
      expect(r.status).toBe(1)
      expect(r.stderr).toMatch(/the tag is v9\.9\.9, the TOC's ## Version is \d+\.\d+\.\d+/)
    })

    it.each(['0.4.1', 'v0.4', 'V0.4.1', 'v0.4.1-rc1', 'refs/tags/v0.4.1', ''])('refuses the tag "%s"', (tag) => {
      const r = check(copyRepo(), tag)
      expect(r.status).toBe(1)
      expect(r.stderr).toContain('is not vMAJOR.MINOR.PATCH')
    })
  })
})

// ── The version gate of a pull request ─────────────────────────────────────

const GIT_ENV = {
  GIT_AUTHOR_NAME: 'test', GIT_AUTHOR_EMAIL: 'test@example.invalid',
  GIT_COMMITTER_NAME: 'test', GIT_COMMITTER_EMAIL: 'test@example.invalid',
  GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null',
}

function git(dir, ...args) {
  const r = spawnSync('git', ['-C', dir, ...args], { encoding: 'utf8', env: { ...process.env, ...GIT_ENV } })
  if (r.error) throw r.error
  if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`)
  return r.stdout
}

/** A git repository holding what check-bump.py reads, committed on `main` as the base. */
function baseRepo() {
  const dir = copyRepo()
  mkdirSync(join(dir, 'scripts'))
  for (const f of ['build-zip.py', 'addon_info.py']) cpSync(join(ROOT, 'scripts', f), join(dir, 'scripts', f))
  mkdirSync(join(dir, 'test'))
  writeFileSync(join(dir, 'test', 'some.test.mjs'), '// a test\n')
  writeFileSync(join(dir, 'AGENTS.md'), '# rules\n')
  git(dir, 'init', '--quiet', '--initial-branch=main')
  git(dir, 'add', '-A')
  git(dir, 'commit', '--quiet', '-m', 'base')
  return dir
}

const versionOf = dir => /^## Version: (\S+)$/m.exec(readFileSync(join(dir, 'toawowchar/toawowchar.toc'), 'utf8'))[1]

/** Sets the five places to `to` and adds a CHANGELOG entry with `text`. */
function bump(dir, to, { text = '### Fixed\n- a change for the test\n', skip = [] } = {}) {
  const from = versionOf(dir)
  const places = {
    toc: ['toawowchar/toawowchar.toc', s => s.replace(`## Version: ${from}`, `## Version: ${to}`)],
    lua: ['toawowchar/toawowchar.lua', s => s.replace(`local ADDON_VERSION = "${from}"`, `local ADDON_VERSION = "${to}"`)],
    header: ['toawowchar/toawowchar.lua', s => s.replace(`-- toawowchar ${from}\n`, `-- toawowchar ${to}\n`)],
    readme: ['toawowchar/README.md', s => s.replace(new RegExp(`^Version ${from.replaceAll('.', '\\.')}\\b`, 'm'), `Version ${to}`)],
    changelog: ['CHANGELOG.md', s => s.replace(`## [${from}] - `, `## [${to}] - 2026-10-23\n\n${text}\n## [${from}] - `)],
  }
  for (const [name, [file, change]] of Object.entries(places)) {
    if (skip.includes(name)) continue
    const before = readFileSync(join(dir, file), 'utf8')
    const after = change(before)
    if (after === before) throw new Error(`bump: nothing changed in ${file} for ${name}`)
    writeFileSync(join(dir, file), after)
  }
}

const gate = (dir, base = 'main') => py('check-bump.py', ['--root', dir, base])

describe('scripts/check-bump.py', () => {
  it('passes when nothing changed, and says so', () => {
    const r = gate(baseRepo())
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
    expect(r.stdout).toMatch(/^version bump: OK \(no zip input changed against main\)\n$/)
  })

  it('passes when only docs, tests and workflows changed: the zip is the same', () => {
    const dir = baseRepo()
    writeFileSync(join(dir, 'AGENTS.md'), '# other rules\n')
    writeFileSync(join(dir, 'test', 'some.test.mjs'), '// another test\n')
    mkdirSync(join(dir, '.github/workflows'), { recursive: true })
    writeFileSync(join(dir, '.github/workflows/ci.yml'), 'name: CI\n')
    edit(dir, 'CHANGELOG.md', s => `${s}\n`)
    const r = gate(dir)
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
  })

  it('passes when a zip file changed and the version is higher in all five places, with a CHANGELOG entry', () => {
    const dir = baseRepo()
    edit(dir, 'toawowchar/toawowchar.lua', s => `${s}-- a comment\n`)
    bump(dir, '0.4.2')
    const r = gate(dir)
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
    expect(r.stdout).toMatch(/zip inputs changed against main \(.*toawowchar\/toawowchar\.lua/)
  })

  it('sees a change that is already committed, not only one in the working tree', () => {
    const dir = baseRepo()
    git(dir, 'switch', '--quiet', '--create', 'change')
    edit(dir, 'toawowchar/toawowchar.lua', s => `${s}-- a comment\n`)
    git(dir, 'commit', '--quiet', '-am', 'change')
    const r = gate(dir)
    expect(r.status).toBe(1)
    expect(r.stderr).toMatch(/the TOC's ## Version is still \d+\.\d+\.\d+: raise it/)
  })

  it.each([
    ['toawowchar/toawowchar.lua'],
    ['toawowchar/toawowchar.toc'],
    ['toawowchar/README.md'],
    ['scripts/build-zip.py'],
    ['scripts/addon_info.py'],
  ])('fails when %s changed and the version was not raised: it names the file and every place', file => {
    const dir = baseRepo()
    edit(dir, file, s => `${s}${file.endsWith('.py') ? '# ' : file.endsWith('.lua') ? '-- ' : file.endsWith('.toc') ? '# ' : ''}a typo fix\n`)
    const r = gate(dir)
    expect(r.status).toBe(1)
    expect(r.stdout).toMatch(/^version bump: FAILED/)
    expect(r.stderr).toContain(file)
    for (const place of ["the TOC's ## Version", "the Lua's ADDON_VERSION", "the Lua's first line", "the README's version line", 'the newest CHANGELOG entry']) {
      expect(r.stderr, place).toContain(`${place} is still `)
    }
  })

  it.each([
    ['toc'], ['lua'], ['header'], ['readme'], ['changelog'],
  ])('fails when the version is raised everywhere but %s', place => {
    const dir = baseRepo()
    edit(dir, 'toawowchar/toawowchar.lua', s => `${s}-- a comment\n`)
    bump(dir, '0.4.2', { skip: [place] })
    const r = gate(dir)
    expect(r.status).toBe(1)
    expect(r.stderr).toMatch(/is still 0\.4\.1: raise it/)
  })

  it('fails when the version is lower than the base\'s, even though a zip file changed', () => {
    const dir = baseRepo()
    edit(dir, 'toawowchar/toawowchar.lua', s => `${s}-- a comment\n`)
    bump(dir, '0.4.0')
    const r = gate(dir)
    expect(r.status).toBe(1)
    expect(r.stderr).toContain("the TOC's ## Version is 0.4.0, lower than 0.4.1 at main")
    expect(r.stderr).toContain('the newest CHANGELOG entry is 0.4.0, lower than 0.4.1 at main')
  })

  it('fails when the version is lowered although no zip file changed otherwise', () => {
    const dir = baseRepo()
    edit(dir, 'toawowchar/toawowchar.toc', s => s.replace(/^## Version: .*$/m, '## Version: 0.3.0'))
    const r = gate(dir)
    expect(r.status).toBe(1)
    expect(r.stderr).toContain("lower than 0.4.1 at main")
  })

  it('compares numbers, not text: 0.4.10 is higher than 0.4.9', () => {
    const dir = baseRepo()
    bump(dir, '0.4.9')
    git(dir, 'commit', '--quiet', '-am', 'base 0.4.9')
    git(dir, 'switch', '--quiet', '--create', 'next')
    edit(dir, 'toawowchar/toawowchar.lua', s => `${s}-- a comment\n`)
    bump(dir, '0.4.10')
    const r = gate(dir)
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
  })

  it('fails when the new version has a CHANGELOG heading but no text', () => {
    const dir = baseRepo()
    edit(dir, 'toawowchar/toawowchar.lua', s => `${s}-- a comment\n`)
    bump(dir, '0.4.2', { text: '' })
    const r = gate(dir)
    expect(r.status).toBe(1)
    expect(r.stderr).toContain('CHANGELOG.md: the entry for 0.4.2 has no text')
  })

  it('fails on a base that is not a commit, or that looks like an option', () => {
    const dir = baseRepo()
    for (const base of ['no-such-branch', '']) {
      const r = gate(dir, base)
      expect(r.status, base).toBe(1)
      expect(r.stderr, base).toMatch(/error: the base .* is not a (git ref|commit here)/)
    }
    const option = py('check-bump.py', ['--root', dir, '--', '--output=x'])
    expect(option.status).toBe(1)
    expect(option.stderr).toContain('is not a git ref')
  })
})

// ── The zip ────────────────────────────────────────────────────────────────

/** The zip read by Python's standard library: one record for each entry, as it is stored. */
function pythonView(zipPath) {
  const code = `
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
print(json.dumps({
  "bad": z.testzip(),
  "comment": z.comment.decode("latin-1"),
  "entries": [{
    "name": i.filename, "date": list(i.date_time), "system": i.create_system, "attr": i.external_attr,
    "method": i.compress_type, "flags": i.flag_bits, "extra": i.extra.hex(), "comment": i.comment.hex(),
    "size": i.file_size, "packed": i.compress_size, "crc": i.CRC, "dir": i.is_dir(),
    "content": z.read(i.filename).hex(),
  } for i in z.infolist()],
}))`
  const r = spawnSync('python3', ['-I', '-c', code, zipPath], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  if (r.status !== 0) throw new Error(r.stderr)
  return JSON.parse(r.stdout)
}

/** The same zip read by a few lines of Node, independent of the Python side and of the script. */
function nodeView(bytes) {
  const eocd = bytes.length - 22
  expect(bytes.readUInt32LE(eocd)).toBe(0x06054B50)
  const count = bytes.readUInt16LE(eocd + 10)
  const dirSize = bytes.readUInt32LE(eocd + 12)
  const dirOffset = bytes.readUInt32LE(eocd + 16)
  expect(bytes.readUInt16LE(eocd + 20)).toBe(0) // no archive comment
  expect(dirOffset + dirSize).toBe(eocd) // the directory ends where the end record starts: no gaps, no trailing bytes
  const entries = []
  let p = dirOffset
  for (let i = 0; i < count; i++) {
    expect(bytes.readUInt32LE(p)).toBe(0x02014B50)
    const nameLength = bytes.readUInt16LE(p + 28)
    const local = bytes.readUInt32LE(p + 42)
    const name = bytes.subarray(p + 46, p + 46 + nameLength).toString('ascii')
    const size = bytes.readUInt32LE(p + 24)
    expect(bytes.readUInt32LE(local)).toBe(0x04034B50)
    const dataStart = local + 30 + bytes.readUInt16LE(local + 26) + bytes.readUInt16LE(local + 28)
    entries.push({
      name,
      made: bytes.readUInt16LE(p + 4),
      method: bytes.readUInt16LE(p + 10),
      time: bytes.readUInt16LE(p + 12),
      date: bytes.readUInt16LE(p + 14),
      attr: bytes.readUInt32LE(p + 38),
      localOffset: local,
      data: bytes.subarray(dataStart, dataStart + size),
      // the local header says the same as the directory
      localAgrees: bytes.readUInt16LE(local + 8) === bytes.readUInt16LE(p + 10) && bytes.readUInt16LE(local + 10) === bytes.readUInt16LE(p + 12)
        && bytes.readUInt16LE(local + 12) === bytes.readUInt16LE(p + 14) && bytes.readUInt32LE(local + 14) === bytes.readUInt32LE(p + 16)
        && bytes.readUInt32LE(local + 18) === size && bytes.readUInt32LE(local + 22) === size,
    })
    p += 46 + nameLength + bytes.readUInt16LE(p + 30) + bytes.readUInt16LE(p + 32)
  }
  return entries
}

const FILES = ['toawowchar/README.md', 'toawowchar/toawowchar.lua', 'toawowchar/toawowchar.toc']
const ADDON_FILES = ['README.md', 'toawowchar.lua', 'toawowchar.toc']

/** Builds the zip of `root` into a new directory and returns the zip's path, bytes and the script's result. */
function buildHere(root, opts) {
  const out = temp()
  const r = build(root, out, opts)
  expect(r.stderr).toBe('')
  expect(r.status).toBe(0)
  const file = readdirSync(out).find(f => f.endsWith('.zip'))
  return { out, file, path: join(out, file), bytes: readFileSync(join(out, file)), result: r }
}

describe('scripts/build-zip.py', () => {
  it('makes toawowchar-<version>.zip and SHA256SUMS, and prints the name, size and hash', () => {
    const root = copyRepo()
    const { out, file, bytes, result } = buildHere(root)
    const version = /^## Version: (\S+)$/m.exec(readFileSync(join(root, 'toawowchar/toawowchar.toc'), 'utf8'))[1]
    expect(file).toBe(`toawowchar-${version}.zip`)
    expect(readdirSync(out).sort()).toEqual(['SHA256SUMS', file])
    // the format of `sha256sum -c`: hash, two spaces, name, newline
    expect(readFileSync(join(out, 'SHA256SUMS'), 'utf8')).toBe(`${sha256(bytes)}  ${file}\n`)
    expect(result.stdout).toBe(`${file}  ${bytes.length} bytes  sha256 ${sha256(bytes)}\n`)
  })

  it('writes to dist/ of the repository when --out is not given', () => {
    const root = copyRepo()
    const r = py('build-zip.py', ['--root', root])
    expect(r.status).toBe(0)
    const version = /^## Version: (\S+)$/m.exec(readFileSync(join(root, 'toawowchar/toawowchar.toc'), 'utf8'))[1]
    expect(readdirSync(join(root, 'dist')).sort()).toEqual(['SHA256SUMS', `toawowchar-${version}.zip`])
  })

  it('holds exactly README.md, toawowchar.lua and toawowchar.toc under toawowchar/, in that order, with the sources\' bytes', () => {
    const root = copyRepo()
    const { path, bytes } = buildHere(root)
    const view = pythonView(path)
    expect(view.bad).toBeNull()
    expect(view.comment).toBe('')
    expect(view.entries.map(e => e.name)).toEqual(FILES)
    view.entries.forEach((e, i) => {
      expect(e.content, e.name).toBe(readFileSync(join(root, 'toawowchar', ADDON_FILES[i])).toString('hex'))
      expect(e.dir).toBe(false)
    })
    expect(nodeView(bytes).map(e => e.name)).toEqual(FILES)
  })

  it('stamps every entry 2026-01-01 00:00:00, as a regular file of mode 0644 made by Unix, stored, with no flags, extra fields or comments', () => {
    const { path, bytes } = buildHere(copyRepo())
    for (const e of pythonView(path).entries) {
      expect(e.date, e.name).toEqual([2026, 1, 1, 0, 0, 0])
      expect(e.system, e.name).toBe(3)
      expect(e.attr, e.name).toBe((0o100644 << 16) >>> 0)
      expect(e.method, e.name).toBe(0)
      expect(e.size, e.name).toBe(e.packed)
      expect(e.flags, e.name).toBe(0)
      expect(e.extra, e.name).toBe('')
      expect(e.comment, e.name).toBe('')
    }
    for (const e of nodeView(bytes)) {
      expect(e.date, e.name).toBe(((2026 - 1980) << 9) | (1 << 5) | 1)
      expect(e.time, e.name).toBe(0)
      expect(e.made, e.name).toBe((3 << 8) | 20)
      expect(e.method, e.name).toBe(0)
      expect(e.localAgrees, e.name).toBe(true)
      expect(sha256(e.data), e.name).toBe(sha256(readFileSync(join(ROOT, 'toawowchar', e.name.slice('toawowchar/'.length)))))
    }
  })

  it('is the same bytes in every time zone (checked: the zones really differ), on any day, from any directory, with any file times, modes and umask', () => {
    const zones = ['UTC', 'Pacific/Auckland', 'America/Los_Angeles', 'Asia/Kolkata']
    const offsets = zones.map(tz => spawnSync('date', ['+%z'], { encoding: 'utf8', env: { ...process.env, TZ: tz } }).stdout.trim())
    expect(new Set(offsets).size, `UTC offsets ${offsets}: tzdata is missing`).toBe(4)

    const hashes = []
    const root = copyRepo()
    for (const tz of zones) hashes.push(sha256(buildHere(root, { env: { TZ: tz } }).bytes))
    // another directory, other file times (one in 1999, one now), other modes, a strict umask, another locale and hash seed
    const other = copyRepo()
    for (const [i, f] of ADDON_FILES.entries()) {
      const path = join(other, 'toawowchar', f)
      utimesSync(path, new Date(i === 0 ? '1999-12-31T23:59:59Z' : Date.now()), new Date(i === 0 ? '1999-12-31T23:59:59Z' : Date.now()))
      chmodSync(path, i === 1 ? 0o600 : 0o755)
    }
    hashes.push(sha256(buildHere(other, { shell: 'umask 077; TZ=Pacific/Kiritimati LC_ALL=C PYTHONHASHSEED=12345', env: {} }).bytes))
    hashes.push(sha256(buildHere(other, { env: { TZ: 'America/St_Johns', LC_ALL: 'C.UTF-8', PYTHONHASHSEED: 'random' } }).bytes))
    expect(new Set(hashes).size, hashes.join(' ')).toBe(1)
  })

  it('has the sha256 it had when it was written: a fixed tree gives a fixed zip (this fails if the container changes)', () => {
    const { bytes } = buildHere(syntheticRepo())
    expect(bytes.length).toBe(SYNTHETIC_SIZE)
    expect(sha256(bytes)).toBe(SYNTHETIC_SHA256)
  })

  it('changes when a source byte changes (it is the sources that are in the zip)', () => {
    const root = syntheticRepo()
    edit(root, 'toawowchar/toawowchar.lua', s => s.replace('return 1', 'return 2'))
    expect(sha256(buildHere(root).bytes)).not.toBe(SYNTHETIC_SHA256)
  })

  it('does not build when the version check fails: no zip, no SHA256SUMS, status 1', () => {
    const root = copyRepo()
    edit(root, 'toawowchar/README.md', s => s.replace(/^Version \d+\.\d+\.\d+/m, 'Version 9.9.9'))
    const out = temp()
    const r = build(root, out)
    expect(r.status).toBe(1)
    expect(r.stderr).toContain('no zip is made: the version check failed')
    expect(existsSync(join(out, 'SHA256SUMS'))).toBe(false)
    expect(readdirSync(out)).toEqual([])
  })

  it('does not build from a source with a carriage return', () => {
    const root = copyRepo()
    edit(root, 'toawowchar/toawowchar.lua', s => s.replace('\n', '\r\n'))
    const out = temp()
    const r = build(root, out)
    expect(r.status).not.toBe(0)
    expect(r.stderr).toContain('has a carriage return')
    expect(readdirSync(out)).toEqual([])
  })

  it('the files of this repository are the ones a release is built from: LF only', () => {
    for (const f of ADDON_FILES) expect(readFileSync(join(ROOT, 'toawowchar', f)).includes(13), f).toBe(false)
  })
})
