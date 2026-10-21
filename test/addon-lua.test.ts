import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { beforeAll, describe, expect, it } from 'vitest'
import { ADDON_VERSION } from '../shared/addon-release'
import { MAX_ENCODED_LENGTH } from '../shared/addon-export-format'
import { MISSING_REASONS, SECTION_NAMES } from '../shared/addon-sections'
import { ADDON_BOUNDS, ADDON_LIST_CAPS, MAX_BONUS_IDS_PER_ITEM, MAX_IDS_PER_ARRAY, decodeAddonExport, obtainedItemIds } from '../server/utils/addon-export'
import { ADDON_BODY_MAX } from '../server/utils/request-body'
import type { AddonExport } from '../server/utils/addon-export'

// The addon's Lua, checked with Lua 5.1 in Docker (the WoW client's Lua). Opt-in
// by presence: skipped when Docker or the image nickblah/lua:5.1-alpine is not
// there, so `npm test` stays offline. `docker pull nickblah/lua:5.1-alpine` once
// to enable it. The scripts in test/lua/ fake the WoW API (wow-env.lua) and
// print what the addon makes; this file checks that output.
const IMAGE = 'nickblah/lua:5.1-alpine'
const ROOT = fileURLToPath(new URL('../..', import.meta.url))

const haveImage = (() => {
  try {
    return spawnSync('docker', ['image', 'inspect', IMAGE], { stdio: 'ignore' }).status === 0
  }
  catch { return false }
})()

const lua = (args: string[]) =>
  spawnSync('docker', ['run', '--rm', '-v', `${ROOT}:/w:ro`, '-w', '/w', IMAGE, ...args], { encoding: 'utf8' })

/** Runs a script in test/lua/ and returns its stdout lines. */
function script(name: string, ...args: string[]): string[] {
  const r = lua(['lua', `app/test/lua/${name}.lua`, ...args])
  expect(r.stderr).toBe('')
  expect(r.status).toBe(0)
  return r.stdout.replace(/\n$/, '').split('\n')
}

const PREFIX = 'WOWCHAR:3:'
/** The JSON of an export line; the line must be a format 3 string with no pipe. */
function parseExport(line: string): any {
  expect(line.startsWith(PREFIX)).toBe(true)
  expect(line).not.toContain('|')
  return JSON.parse(line.slice(PREFIX.length))
}

const exportFor = (scenario: string) => parseExport(script('region-stub', scenario)[0]!)

const identityOf = (scenario: string) => {
  const id = exportFor(scenario).identity
  return Object.fromEntries(['region', 'regionId', 'portal', 'realm', 'name'].map(k => [k, String(id[k] ?? 'nil')]))
}

/** `label\tjson` lines to a map of label to the raw json (or 'ERROR'). */
const labelled = (lines: string[]) => new Map(lines.map(l => l.split('\t') as [string, string]))

describe.skipIf(!haveImage)('WowcharExport.lua (Lua 5.1)', () => {
  it('compiles (luac -p)', () => {
    const r = lua(['luac', '-p', 'addon/WowcharExport/WowcharExport.lua'])
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
  })

  it('the version is the shared constant in the code and in the .toc, and it emits format 3', () => {
    const code = readFileSync(`${ROOT}/addon/WowcharExport/WowcharExport.lua`, 'utf8')
    const toc = readFileSync(`${ROOT}/addon/WowcharExport/WowcharExport.toc`, 'utf8')
    expect(code).toContain(`local ADDON_VERSION = "${ADDON_VERSION}"`)
    expect(code).toContain('local FORMAT_VERSION = 3')
    expect(toc).toMatch(new RegExp(`^## Version: ${ADDON_VERSION.replace(/\./g, '\\.')}$`, 'm'))
    const json = exportFor('eu')
    expect(json.format).toBe(3)
    expect(json.addonVersion).toBe(ADDON_VERSION)
  })

  it('does not use C_EncodingUtil any more (the stub raises if it is touched)', () => {
    const code = readFileSync(`${ROOT}/addon/WowcharExport/WowcharExport.lua`, 'utf8')
      .split('\n').filter(l => !l.trim().startsWith('--')).join('\n')
    expect(code).not.toMatch(/C_EncodingUtil|CompressString|EncodeBase64|SerializeJSON/)
    expect(exportFor('eu').identity.name).toBe('Thor')
  })

  describe('region', () => {
    it.each([['us', 'US'], ['kr', 'KR'], ['eu', 'EU'], ['tw', 'TW'], ['cn', 'CN']])(
      'GetCurrentRegion scenario %s sends identity.region %s and no regionId or portal', (scenario, region) => {
        expect(identityOf(scenario)).toMatchObject({ region, regionId: 'nil', portal: 'nil', name: 'Thor' })
      })

    it('the Forever test client (GetCurrentRegion = 110, portal "test"): no region, regionId 110, portal "test"', () => {
      expect(identityOf('forever')).toMatchObject({ region: 'nil', regionId: '110', portal: 'test', realm: 'nil' })
    })

    it('the realm is sent when the client has one', () => {
      expect(identityOf('eu').realm).toBe('Some Realm')
    })

    it.each(['missing', 'erroring', 'wrongtypes'])('scenario %s (functions missing, raising or returning the wrong type) is not an error and sends no region', (scenario) => {
      expect(identityOf(scenario)).toMatchObject({ region: 'nil', regionId: 'nil', portal: 'nil', name: 'Thor' })
    })

    it('never calls GetCurrentRegionName (the stub raises if it does)', () => {
      expect(identityOf('eu').region).toBe('EU')
    })
  })

  describe('race and faction', () => {
    const identity = (scenario: string) => parseExport(script('race-stub', scenario)[0]!).identity
    const both = (scenario: string) => {
      const id = identity(scenario)
      return { race: id.race, faction: id.faction }
    }

    it('sends the race file token (the second return of UnitRace) and the faction (the first of UnitFactionGroup)', () => {
      expect(both('nightelf')).toEqual({ race: 'NightElf', faction: 'Alliance' })
      expect(both('scourge')).toEqual({ race: 'Scourge', faction: 'Horde' })
      expect(both('neutral')).toEqual({ race: 'Pandaren', faction: 'Neutral' })
    })

    it('sends a token it does not know as it is; the server decides', () => {
      expect(both('unknown-token')).toEqual({ race: 'HighOrderSkyborne', faction: 'Alliance' })
    })

    it('the format is 3, the identity keys are as in format 2, and the server decodes it', () => {
      const j = parseExport(script('race-stub', 'nightelf')[0]!)
      expect(j.format).toBe(3)
      expect(Object.keys(j.identity).sort()).toEqual(
        ['classFile', 'classID', 'faction', 'guid', 'hardcore', 'level', 'name', 'race', 'realm', 'region'].sort(),
      )
      const p = decodeAddonExport(`${PREFIX}${JSON.stringify(j)}`)
      expect(p.identity).toMatchObject({ race: 'NightElf', faction: 'Alliance' })
    })

    it.each(['nil-returns', 'missing', 'erroring', 'wrongtypes', 'empty', 'name-only'])(
      'scenario %s (nil, a missing or raising function, a non-string, an empty string) leaves both keys out', (scenario) => {
        const j = parseExport(script('race-stub', scenario)[0]!)
        expect(j.format).toBe(3)
        expect(j.identity).not.toHaveProperty('race')
        expect(j.identity).not.toHaveProperty('faction')
        expect(j.identity.name).toBe('Thor')
        expect(decodeAddonExport(`${PREFIX}${JSON.stringify(j)}`).identity.race).toBeUndefined()
      })

    it('one that fails does not take the other with it', () => {
      expect(identity('partial')).toMatchObject({ race: 'NightElf' })
      expect(identity('partial')).not.toHaveProperty('faction')
    })
  })

  describe('serializer', () => {
    // Run lazily: nothing external may run at collection time (the suite is skipped offline).
    let cases: Map<string, string>
    beforeAll(() => { cases = labelled(script('serializer-test')) })
    const value = (label: string) => JSON.parse(cases.get(label)!)

    it('escapes quotes and backslashes and reads them back', () => {
      expect(value('quote')).toBe('say "hi"')
      expect(value('backslash')).toBe('back\\slash and \\u0041')
    })

    it('writes "|" as \\u007c so no pipe reaches the copy box, and reads it back as "|"', () => {
      const raw = cases.get('pipe')!
      expect(raw).not.toContain('|')
      expect(raw).toContain('\\u007c')
      expect(value('pipe')).toBe('a|cff00ff00|Hitem:1|h[x]|h|r||')
      expect(cases.get('pipe-in-key')).not.toContain('|')
      expect(value('pipe-in-key')).toEqual({ 'a|b': 1 })
    })

    it('keeps non-ASCII text as UTF-8', () => {
      expect(cases.get('nonascii')).toBe('"Zoë 日本語 ü"')
      expect(value('nonascii')).toBe('Zoë 日本語 ü')
    })

    it('escapes control characters (and DEL) as \\u00XX, with the short forms for \\n \\r \\t', () => {
      const raw = cases.get('control')!
      // no raw control character in the output
      // eslint-disable-next-line no-control-regex
      expect(raw).not.toMatch(/[\u0000-\u001F\u007F]/)
      expect(raw).toBe('"\\u0000\\u0001\\u0008\\t\\n\\r\\u001b\\u001f\\u007f end"')
      expect(value('control')).toBe('\0\u0001\b\t\n\r\u001B\u001F\u007F end')
    })

    it('round-trips nested arrays and objects; false and empty strings stay', () => {
      expect(value('empty-string')).toBe('')
      expect(value('nested')).toEqual({ a: [1, 2, { b: true, c: [3] }], d: [], e: [{ x: 1 }, { y: 2 }], f: false })
      expect(value('bool')).toBe(true)
      expect(value('number-top')).toBe(5)
    })

    it('writes an empty Lua table as [] (an empty list), always', () => {
      expect(cases.get('empty-list')).toBe('[]')
      expect(cases.get('nested')).toContain('"d":[]')
    })

    it('writes keys in sorted order and leaves out nil values; the same data gives the same text', () => {
      expect(cases.get('key-order')).toBe('{"B":4,"a":2,"ab":3,"b":1}')
      expect(cases.get('nil-value-key-left-out')).toBe('{"a":1}')
      expect(cases.get('deterministic')).toBe('yes')
    })

    it('writes whole numbers as integers and anything else as null', () => {
      expect(cases.get('numbers')).toBe('[0,42,-7,2147483647,null,null,null,null,9007199254740991,null]')
    })

    it.each(['err-function', 'err-cycle', 'err-mixed', 'err-hole', 'err-number-key', 'err-deep'])(
      '%s is refused (an error, no export)', (label) => {
        expect(cases.get(label)).toBe('ERROR')
      })
  })

  describe('item strings', () => {
    let cases: Map<string, string>
    beforeAll(() => { cases = labelled(script('item-test')) })
    const parsed = (label: string) => (cases.get(label) === 'null' ? null : JSON.parse(cases.get(label)!))

    it('reads the fields by position: enchant 2, gems 3-6, suffix 7, bonus count 13 then the ids', () => {
      expect(parsed('full')).toEqual({ itemId: 12640, enchantId: 2564, gemIds: [213, 218], suffixId: 9, bonusIds: [1472, 6652, 7881] })
    })

    it('a negative suffix becomes its absolute value; a positive one stays', () => {
      expect(parsed('negative-suffix').suffixId).toBe(65)
      expect(parsed('positive-suffix').suffixId).toBe(65)
    })

    it('zero gems are dropped; four gems are kept', () => {
      expect(parsed('all-gems-zero').gemIds).toEqual([])
      expect(parsed('four-gems').gemIds).toEqual([1, 2, 3, 4])
      expect(parsed('full').gemIds).toEqual([213, 218])
    })

    it('reads exactly as many bonus ids as the count says; modifiers after them are not read', () => {
      expect(parsed('bonus-then-modifiers').bonusIds).toEqual([10, 20, 30])
      expect(parsed('bonus-count-zero').bonusIds).toEqual([])
      expect(parsed('bonus-count-negative').bonusIds).toEqual([])
    })

    it('a count larger than the string takes what is there; zero and bad ids are dropped; at most 32', () => {
      expect(parsed('bonus-count-too-big').bonusIds).toEqual([11, 12])
      expect(parsed('bonus-with-zero-and-bad').bonusIds).toEqual([7, 8])
      expect(parsed('more-than-32-bonus').bonusIds).toHaveLength(MAX_BONUS_IDS_PER_ITEM)
    })

    it('a short item string gives the item id and zeros', () => {
      const none = { enchantId: 0, gemIds: [], suffixId: 0, bonusIds: [] }
      expect(parsed('id-only')).toEqual({ itemId: 19019, ...none })
      expect(parsed('trailing-colons')).toEqual({ itemId: 19019, ...none })
      expect(parsed('short-before-bonus')).toEqual({ itemId: 100, enchantId: 5, gemIds: [6, 7], suffixId: 0, bonusIds: [] })
    })

    it('only digits, "-" and ":" are taken; the item name is never read', () => {
      expect(parsed('name-with-digits-not-read')).toEqual({ itemId: 100, enchantId: 0, gemIds: [], suffixId: 0, bonusIds: [] })
    })

    it.each(['id-too-big', 'id-zero', 'id-minus', 'no-item', 'not-a-link', 'empty', 'nil', 'number'])(
      '%s gives no result', (label) => {
        expect(parsed(label)).toBeNull()
      })
  })

  describe('a full export', () => {
    let line: string
    beforeAll(() => { line = script('export-full')[0]! })

    it('is pinned: the text equals the fixture the server tests decode', () => {
      expect(line).toBe(readFileSync(`${ROOT}/app/test/fixtures/addon-export-v3.txt`, 'utf8').trim())
    })

    it('has no pipe, and the pipes of a profession name come back after parsing', () => {
      expect(line).not.toContain('|')
      expect(parseExport(line).professions[1].name).toBe('Zulöte |cffff0000"Bergbau"|r')
    })

    it('decodes on the server (the real serializer against the real decoder)', () => {
      const p = decodeAddonExport(line)
      expect(p.format).toBe(3)
      expect(p.identity).toEqual({ name: 'Thorin', region: 'EU', realm: 'Argent Dawn', classFile: 'WARRIOR', classID: 1, race: 'Dwarf', faction: 'Alliance', level: 60, specName: 'Arms' })
      expect(p.equipped).toEqual([
        { slot: 1, itemId: 12640, enchantId: 2564, suffixId: 9, gemIds: [213, 218], bonusIds: [1472, 6652, 7881] },
        { slot: 2, itemId: 18404, enchantId: 0, suffixId: 0, gemIds: [], bonusIds: [] },
        { slot: 15, itemId: 13340, enchantId: 0, suffixId: 0, gemIds: [], bonusIds: [] }, // no link yet: the API id
        { slot: 16, itemId: 19019, enchantId: 3368, suffixId: 0, gemIds: [], bonusIds: [] },
      ])
      expect(p.bags).toEqual([6948, 2589, 4540])
      expect(p.bank).toEqual([21, 22, 12640])
      expect(p.bankSeen).toBe(true)
      expect(p.warbank).toEqual([91, 12640])
      expect(p.warbankSeen).toBe(true)
      expect(p.professions).toEqual([
        { name: 'Blacksmithing', skillLineId: 164, rank: 225, maxRank: 300 },
        { name: 'Zulöte |cffff0000"Bergbau"|r', skillLineId: 186, rank: 10, maxRank: 75 },
      ])
      expect([...obtainedItemIds(p)].sort((a, b) => a - b)).toEqual([21, 22, 91, 2589, 4540, 6948, 12640, 13340, 18404, 19019])
      expect(p.capturedAt).toBe(1792000000)
    })

    it('the sections decode to typed fields, each with its source', () => {
      const s = decodeAddonExport(line).sections!
      expect(s.sources.bank).toEqual({ source: 'live', at: 1792000000 })
      expect(s.sources.recipes).toEqual({ source: 'cache', at: 1791913600 }) // the earlier session's Blacksmithing
      expect(s.recipes).toEqual([{ line: 164, name: 'Blacksmithing', at: 1791913600, recipes: [
        { id: 2662, reagents: [{ itemId: 2840, count: 2 }, { itemId: 2589, count: 1 }] },
        { id: 2663, reagents: [{ itemId: 2840, count: 1 }] },
      ] }])
      expect(s.questsDone).toEqual([4, 8, 15, 16, 23, 42, 1001, 1002])
      expect(s.player).toEqual({ money: 123456789, level: 60, xp: 1000, xpMax: 5000, rested: 250000 })
      expect(s.reputation![0]).toEqual({ id: 72, reaction: 5, standing: 3500, floor: 3000, ceiling: 9000, name: 'Stormwind' })
      expect(s.talents).toEqual([{ tree: 1100, nodes: [{ node: 10, rank: 2, entry: 100 }, { node: 11, rank: 1, entry: 0 }] }])
      expect(s.legacy!.points).toEqual({ available: 5, cap: 50, spent: 20 })
      expect(s.legacy!.trees.map(t => [t.tree, t.spent, t.nodes.length])).toEqual([[1187, 8, 1], [1188, 7, 0], [1189, 5, 1]])
      expect(s.legacy!.challenges).toEqual({ source: { source: 'missing', why: 'not_available' } })
      expect(s.flightPaths).toEqual([11, 12, 14])
      expect(s.honor).toEqual({ seasonRank: 4, seasonMax: 14 })
      expect(s.classSpells).toEqual([78, 772, 3908, 6603])
      expect(s.questLog!.hidden).toBe(2)
    })
  })

  describe('the bank guard and the warband bank', () => {
    const run = (scenario: string) => script('bank-test', scenario).map(parseExport)
    const lists = (j: any) => ({ bank: j.bank, bankSeen: j.bankSeen, warbank: j.warbank, warbankSeen: j.warbankSeen })
    const FIRST = { bank: [1, 2, 3, 4], bankSeen: true, warbank: [91, 92, 93], warbankSeen: true }
    const SECOND = { bank: [7], bankSeen: true, warbank: [97], warbankSeen: true }

    it('a bank that was never opened is not seen: empty lists, both flags false', () => {
      const [j] = run('never-opened')
      expect(lists(j)).toEqual({ bank: [], bankSeen: false, warbank: [], warbankSeen: false })
      expect(j).not.toHaveProperty('bankSource')
    })

    it('an open bank is read into bank and warbank, each with its flag; bankSource says tabs', () => {
      const [j] = run('open')
      expect(lists(j)).toEqual(FIRST)
      expect(j.bankSource).toBe('tabs')
    })

    it('still open at the end of a later scan: the list is replaced', () => {
      const [a, b] = run('still-open-replaces')
      expect(lists(a)).toEqual(FIRST)
      expect(lists(b)).toEqual(SECOND)
    })

    it('closed before the end of the scan: the previous lists are kept', () => {
      const [a, b] = run('closed-before-the-end')
      expect(lists(a)).toEqual(FIRST)
      expect(lists(b)).toEqual(FIRST)
    })

    it('the close event came during the scan although the slots still read: the flag alone keeps the previous lists', () => {
      const [, b] = run('closed-flag-only')
      expect(lists(b)).toEqual(FIRST)
    })

    it('closed while the warband tabs were read: neither list is replaced', () => {
      const [, b] = run('closed-during-warband-scan')
      expect(lists(b)).toEqual(FIRST)
    })

    it('the last item shows no link yet (data not loaded): the scan is not trusted', () => {
      const [, b] = run('not-loaded')
      expect(lists(b)).toEqual(FIRST)
    })

    it('each list has its own check: the warband list stays while the bank list is replaced', () => {
      const [, b] = run('warband-not-loaded')
      expect(lists(b)).toEqual({ bank: [7], bankSeen: true, warbank: [91, 92, 93], warbankSeen: true })
    })

    it('a scan after the bank closed does nothing', () => {
      const [, b] = run('scan-after-close-ignored')
      expect(lists(b)).toEqual(FIRST)
    })

    it('a scan that finds no item at all keeps the previous lists', () => {
      const [a, b] = run('empty-scan-keeps')
      expect(lists(a)).toEqual(FIRST)
      expect(lists(b)).toEqual(FIRST)
    })

    it('an empty bank the first time: nothing is claimed as seen', () => {
      const [j] = run('empty-first-scan')
      expect(lists(j)).toEqual({ bank: [], bankSeen: false, warbank: [], warbankSeen: false })
    })

    it('no AccountBankTab_1 in the client: warbank is empty and not seen, the bank still works', () => {
      const [j] = run('enum-missing')
      expect(lists(j)).toEqual({ bank: [1, 2, 3, 4], bankSeen: true, warbank: [], warbankSeen: false })
    })

    it('warband tabs are read until the first missing one (AccountBankTab_4 missing, _5 present: _5 is not read)', () => {
      const [j] = run('stops-at-first-missing')
      expect(j.warbank).toEqual([91, 92, 93])
    })

    it('warband tabs with no slots give nothing: not seen', () => {
      const [j] = run('tabs-without-slots')
      expect(lists(j)).toEqual({ bank: [1, 2, 3, 4], bankSeen: true, warbank: [], warbankSeen: false })
    })

    it('each list is cut at 500 ids and the export says so (truncated)', () => {
      const [j] = run('cap')
      expect(j.bank).toHaveLength(MAX_IDS_PER_ARRAY)
      expect(j.warbank).toHaveLength(MAX_IDS_PER_ARRAY)
      expect(j.truncated).toBe(true)
      // and the server takes it
      expect(decodeAddonExport(`${PREFIX}${JSON.stringify(j)}`).warbank).toHaveLength(MAX_IDS_PER_ARRAY)
    })
  })
  // ── Format 3: the sections, the cache, the captures, the window ──────────
  // test/lua/sections-test.lua <scenario> [variant] prints `label<TAB>value` lines.

  // Each scenario runs once (the scripts are deterministic).
  const memo = new Map<string, Map<string, string>>()
  const scn = (scenario: string, variant?: string) => {
    const key = `${scenario} ${variant ?? ''}`
    if (!memo.has(key)) memo.set(key, labelled(script('sections-test', scenario, ...(variant ? [variant] : []))))
    return memo.get(key)!
  }
  const json = (m: Map<string, string>, label: string): any => JSON.parse(m.get(label)!)
  const exportOf = (m: Map<string, string>, label = 'export') => parseExport(m.get(label)!)
  /** The chat lines without their colour codes. */
  const plain = (m: Map<string, string>, label: string): string[] =>
    (json(m, label) as string[]).map(l => l.replace(/\|c[0-9a-fA-F]{8}|\|r/g, ''))
  const decoded = (m: Map<string, string>, label = 'export'): AddonExport => decodeAddonExport(m.get(label)!)
  const marker = (j: any, name: string) => {
    const { source, at, why } = j.sections[name]
    return [source, at, why].filter(v => v !== undefined).join(':')
  }

  describe('every section has a source', () => {
    it('a client with none of the new functions: all 15 sections are there, the base ones live, the others say why', () => {
      const m = scn('bare')
      const j = exportOf(m)
      expect(Object.keys(j.sections).sort()).toEqual([...SECTION_NAMES].sort())
      expect(Object.keys(j)).not.toContain('completedQuestIds')
      expect(marker(j, 'equipped')).toBe('live')
      expect(marker(j, 'bags')).toBe('live')
      expect(marker(j, 'player')).toBe('live') // UnitLevel is there
      expect(j.sections.player).toEqual({ source: 'live', level: 60 })
      for (const name of ['bank', 'warbank', 'professions', 'recipes', 'questsDone', 'questLog', 'reputation', 'talents', 'legacy', 'flightPaths', 'honor', 'classSpells']) {
        expect(marker(j, name), name).toBe('missing:not_available')
      }
      expect(j.bankSeen).toBe(false)
      expect(j.warbankSeen).toBe(false)
      expect(decoded(m).sections!.sources.bank).toEqual({ source: 'missing', why: 'not_available' })
      expect(plain(m, 'chat')).toEqual([])
    })

    it('with the containers but nothing opened yet, the bank, recipes and flight paths ask for their window', () => {
      const j = exportOf(scn('nothing-opened'))
      expect(marker(j, 'bank')).toBe('missing:open_bank')
      expect(marker(j, 'warbank')).toBe('missing:open_bank')
      expect(marker(j, 'recipes')).toBe('missing:open_profession_window')
      expect(marker(j, 'flightPaths')).toBe('missing:open_flight_map')
    })

    it('the reason codes are the shared list, in the same order', () => {
      const m = scn('constants')
      expect(json(m, 'reasons')).toEqual([...MISSING_REASONS])
    })

    it('the caps are the server\'s (ADDON_LIST_CAPS), name by name, and MAX_EXPORT_LENGTH is MAX_ENCODED_LENGTH', () => {
      const m = scn('constants')
      const caps = json(m, 'caps')
      const { ids, professions, ...rest } = caps
      expect(rest).toEqual({ ...ADDON_LIST_CAPS })
      expect(ids).toBe(MAX_IDS_PER_ARRAY)
      expect(professions).toBe(32)
      expect(json(m, 'max')).toEqual([MAX_ENCODED_LENGTH])
    })

    it('the route body limit is the server\'s: ADDON_BODY_MAX (= MAX_ENCODED_LENGTH + the 16 KiB for the JSON escapes)', () => {
      expect(json(scn('constants'), 'bodymax')).toEqual([ADDON_BODY_MAX])
      expect(ADDON_BODY_MAX).toBe(MAX_ENCODED_LENGTH + 16 * 1024)
    })
  })

  describe('the bounds on numbers and texts', () => {
    it('are the server\'s (ADDON_BOUNDS), name by name: a number added or changed on one side fails here', () => {
      const bounds = json(scn('constants'), 'bounds')
      expect(bounds).toEqual({ ...ADDON_BOUNDS })
    })

    it('a value outside a bound leaves its row (or optional field) out, everything else is exported, and the strict server takes the text', () => {
      const m = scn('bounds')
      const j = exportOf(m)
      const p = decoded(m) // decodeAddonExport refuses the whole text on one bad value
      const s = j.sections

      // reputation: reaction -1 and 21, standing, floor and ceiling beyond +-1e9, an id above the bound: the rows are gone; the edge row stays
      expect(s.reputation.factions.map((f: any[]) => f[0])).toEqual([72, 69, 169, 505])
      expect(s.reputation.factions[3]).toEqual([505, 20, 1000000000, -1000000000, 1000000000, 'Edge'])
      // quest log: the objectives with a count outside 0..1e9 are gone, the quest and its edge objective stay, the quest with a too big id is not listed
      const q = s.questLog.quests.find((x: any) => x.id === 7010)
      expect(q.objectives).toEqual([{ text: 'Edge', have: 1000000000, need: 1000000000, done: false }])
      expect(s.questLog.quests.map((x: any) => x.id)).toEqual([7001, 7002, 7010])
      // player: money, xp and rested outside their bounds are left out; level and xpMax stay
      expect(s.player).toEqual({ source: 'live', level: 60, xpMax: 5000 })
      // ids above the bound are not listed; the id at the bound is
      expect(s.questsDone.ids).toEqual([3, 5, 2147483647])
      expect(s.flightPaths.ids).toEqual([11, 12, 14, 2147483647])
      expect(s.classSpells.ids).toEqual([78, 772, 6603, 2147483647])
      // talents: rank 256 and an entry above the id bound are gone, rank 255 and the entry at the bound stay
      expect(s.talents.trees[0].nodes).toEqual([[10, 2, 100], [11, 1, 0], [22, 255, 2147483647]])
      // Legacy: the tree whose spent count is beyond 1e9 is left out, and `available` from the same read
      expect(s.legacy.trees.map((t: any) => t.tree)).toEqual([1188, 1189])
      expect(s.legacy.points).toEqual({ cap: 50, spent: 20 })
      // honor: the season maximum above 1000 is left out, the rank stays
      expect(s.honor).toEqual({ source: 'live', seasonRank: 4 })
      // recipes: the reagent with a count of 10000 is gone, the one with 9999 stays; the recipe with a too big id is not listed
      expect(s.recipes.lines[0].recipes).toEqual([[1, [[2589, 9999]]], [2, []]])
      // professions: a name over 64 bytes drops the profession, a rank above 1e6 only the rank
      expect(j.professions).toEqual([
        { name: 'Tailoring', skillLineId: 197, maxRank: 300 },
        { name: 'First Aid', skillLineId: 129, rank: 100, maxRank: 150 },
      ])
      // equipped: an item id above the bound leaves the slot out
      expect(j.equipped.map((e: any) => [e.slot, e.itemId])).toEqual([[2, 100]])
      // identity: a realm over 100 bytes, a spec name over 50 and a class id above 1e6 are left out (all optional)
      for (const key of ['realm', 'specName', 'classID']) expect(j.identity, key).not.toHaveProperty(key)
      expect(j.identity).toMatchObject({ name: 'Thor', classFile: 'WARRIOR', level: 60, region: 'EU' })
      expect(p.identity.realm).toBeUndefined()
      expect(p.sections!.sources.reputation.source).toBe('live')
    })

    it('a season rank above 1000 makes the honor section missing (there is no row to leave out), and the rest decodes', () => {
      const m = scn('bounds-honor')
      expect(exportOf(m).sections.honor).toEqual({ source: 'missing', why: 'not_available' })
      expect(decoded(m).sections!.sources.honor).toEqual({ source: 'missing', why: 'not_available' })
    })

    it('a level above 255, a region id above 1e6 and a portal over 32 bytes are left out of the identity; the player section keeps its other numbers', () => {
      const m = scn('bounds-identity')
      const j = exportOf(m)
      for (const key of ['level', 'region', 'regionId', 'portal']) expect(j.identity, key).not.toHaveProperty(key)
      expect(j.sections.player).toEqual({ source: 'live', money: 123456789, rested: 0, xp: 1000, xpMax: 5000 })
      expect(decoded(m).identity.level).toBeUndefined()
    })

    it('a character name over 64 bytes makes no export: the window says so and the text box stays empty', () => {
      const m = scn('bounds-identity', 'name')
      expect(plain(m, 'window').join(' ')).toContain('Could not read the character\'s name.')
      expect(json(m, 'text')).toEqual([''])
    })

    it('a clock the server would refuse (before 2001): no capturedAt, no times on live sections, a recipe line and a cached section with no valid time are missing; the server takes it', () => {
      const m = scn('bounds-time')
      const j = exportOf(m)
      expect(j).not.toHaveProperty('capturedAt')
      for (const name of ['questsDone', 'legacy', 'flightPaths']) expect(j.sections[name], name).not.toHaveProperty('at')
      expect(j.sections.recipes).toEqual({ source: 'missing', why: 'open_profession_window' })
      expect(decoded(m).capturedAt).toBeUndefined()
    })
  })

  describe('every section, live', () => {
    let m: Map<string, string>
    let j: any
    beforeAll(() => {
      m = scn('full')
      j = exportOf(m)
    })

    it('has a live source for each one the game could read, and the server decodes it', () => {
      for (const name of SECTION_NAMES) {
        if (name === 'bank' || name === 'warbank') expect(marker(j, name), name).toBe('missing:open_bank')
        else expect(marker(j, name), name).toMatch(/^live/)
      }
      const p = decoded(m)
      expect(p.sections!.sources.talents).toEqual({ source: 'live' })
      expect(p.bankSeen).toBe(false)
    })

    it('player: money in copper, level, XP, XP max; rested is 0 when the game says nil', () => {
      expect(j.sections.player).toEqual({ source: 'live', money: 123456789, level: 60, xp: 1000, xpMax: 5000, rested: 0 })
    })

    it('completed quests: sorted, no duplicates', () => {
      expect(j.sections.questsDone.ids).toEqual([3, 5, 9])
    })

    it('quest log: id, done, objectives (text, have, need, done); header, hidden and task rows are not listed; the rest is counted as hidden', () => {
      expect(j.sections.questLog.quests).toEqual([
        { id: 7001, done: false, objectives: [
          { text: 'Kobold Miner slain', have: 3, need: 10, done: false },
          { text: 'Candle of  Light', have: 1, need: 1, done: true }, // control characters become spaces
        ] },
        { id: 7002, done: true, objectives: [] },
      ])
      // the log says 6 quests, 4 rows were seen: 2 are under collapsed zones
      expect(j.sections.questLog.hidden).toBe(2)
    })

    it('reputation: [faction id, reaction, standing, floor, ceiling, name]; plain headers are left out, a header with reputation stays; collapsed headers are opened and closed again', () => {
      expect(j.sections.reputation.factions).toEqual([
        [72, 5, 3500, 3000, 9000, 'Stormwind'],
        [69, 8, 42000, 21000, 42000, 'Darnassus'],
        [169, 4, 0, 0, 3000, 'Steamwheedle Cartel'],
      ])
      expect(json(m, 'log')).toEqual(['expand-all', 'collapse:1'])
    })

    it('talents: [node, rank, entry] for nodes with a rank, from the active config', () => {
      expect(j.sections.talents.trees).toEqual([{ tree: 1100, nodes: [[10, 2, 100], [11, 1, 0]] }])
    })

    it('legacy: points from the first tree\'s currency, the three trees by id (1187, 1188, 1189), challenges missing', () => {
      expect(j.sections.legacy.points).toEqual({ available: 5, cap: 50, spent: 20 })
      expect(j.sections.legacy.trees).toEqual([
        { tree: 1187, spent: 8, nodes: [[201, 1, 5]] },
        { tree: 1188, spent: 7, nodes: [] },
        { tree: 1189, spent: 5, nodes: [[401, 3, 0]] },
      ])
      expect(j.sections.legacy.challenges).toEqual({ source: 'missing', why: 'not_available' })
    })

    it('flight paths: Current and Reachable nodes of the flight map and the discovered ones of its map; unreachable and undiscovered ones are not known', () => {
      expect(j.sections.flightPaths.ids).toEqual([11, 12, 14])
    })

    it('honor: the season rank (major faction 2800 renown level) and its maximum, under names that say «season»', () => {
      expect(j.sections.honor).toEqual({ source: 'live', seasonRank: 4, seasonMax: 14 })
    })

    it('class spells: spell ids from the spell book; off-spec, future, flyout, id-less, guild and profession lines are skipped', () => {
      expect(j.sections.classSpells.ids).toEqual([78, 772, 6603])
    })

    it('recipes: the profession window\'s learned recipes with [item id, count]; currency, optional and finishing slots and unlearned recipes are skipped', () => {
      expect(j.sections.recipes.lines).toEqual([{ line: 197, name: 'Tailoring', at: 1792000000, recipes: [[1, [[2589, 2], [2320, 1]]], [2, [[2589, 3]]], [4, []]] }])
    })

    it('says one short line for each thing it cached, and nothing else', () => {
      expect(plain(m, 'chat')).toEqual(['wowchar: saved 3 Tailoring recipes.', 'wowchar: saved 3 flight paths.'])
    })
  })

  describe('completed quests only ever grow', () => {
    it('an empty list just after login with no cache is missing/not_loaded, never «nothing done»; it fills in later', () => {
      const m = scn('quests-login')
      const first = exportOf(m, 'empty-no-cache')
      expect(first.sections.questsDone).toEqual({ source: 'missing', why: 'not_loaded' })
      expect(exportOf(m, 'filled').sections.questsDone).toMatchObject({ source: 'live', ids: [10, 40] })
      const p = decoded(m, 'empty-no-cache')
      expect(p.sections!.questsDone).toBeUndefined()
      expect(p.sections!.sources.questsDone).toEqual({ source: 'missing', why: 'not_loaded' })
    })

    it('an empty list at logout, or a shorter one, takes nothing away', () => {
      const m = scn('quests-login')
      expect(exportOf(m, 'empty-again').sections.questsDone.ids).toEqual([10, 40])
      expect(exportOf(m, 'shorter').sections.questsDone.ids).toEqual([10, 40])
    })

    it('an empty list at login with a cache: the cached ids, as cache with their time; then the union with what the game says', () => {
      const m = scn('quests-cache')
      expect(exportOf(m, 'session1').sections.questsDone).toEqual({ source: 'live', at: 1792000000, ids: [10, 20, 30] })
      expect(exportOf(m, 'session2-empty').sections.questsDone).toEqual({ source: 'cache', at: 1792000000, ids: [10, 20, 30] })
      expect(exportOf(m, 'session2-filled').sections.questsDone).toEqual({ source: 'live', at: 1792000000 + 7200, ids: [10, 20, 30, 40] })
      expect(json(m, 'db').Forever.Thor.quests.ids).toEqual([10, 20, 30, 40])
      expect(decoded(m, 'session2-empty').sections!.sources.questsDone).toEqual({ source: 'cache', at: 1792000000 })
    })

    it('a client without the function is missing/not_available', () => {
      expect(exportOf(scn('quests-missing-function')).sections.questsDone).toEqual({ source: 'missing', why: 'not_available' })
    })

    it('over the cap: the lowest 5,000 ids stay, the export says it cut, and the server takes it', () => {
      const m = scn('quests-cap')
      const j = exportOf(m)
      expect(j.sections.questsDone.ids).toHaveLength(ADDON_LIST_CAPS.questsDone)
      expect(j.sections.questsDone.ids[0]).toBe(1001)
      expect(j.truncated).toBe(true)
      expect(decoded(m).sections!.questsDone).toHaveLength(ADDON_LIST_CAPS.questsDone)
    })
  })

  describe('the SavedVariables cache', () => {
    it.each(['string', 'number', 'true', 'realm-not-table'])('a saved variable that is %s is replaced by an empty table and the export is as good as live-only', (variant) => {
      const m = scn('savedvars', variant)
      expect(m.get('db-type')).toBe('table')
      const j = exportOf(m)
      expect(marker(j, 'questsDone')).toMatch(/^live/)
      expect(j.sections.questsDone.ids).toEqual([3, 5, 9])
      expect(decoded(m).format).toBe(3)
    })

    it('a nil saved variable (nothing saved, or not kept) is the same', () => {
      const j = exportOf(scn('savedvars'))
      expect(j.sections.player.level).toBe(60)
      expect(j.sections.questsDone.ids).toEqual([3, 5, 9])
    })

    it('a damaged record is rebuilt field by field: bad times, ids, counts and names are dropped, lists and strings cut', () => {
      const m = scn('savedvars', 'damaged')
      const j = exportOf(m)
      expect(j.bank).toEqual([]) // the bank's time was not a number
      expect(marker(j, 'bank')).toBe('missing:open_bank')
      expect(j.warbank).toEqual([5, 7]) // "x", -1, 1.5 and 2^40 are not item ids
      expect(marker(j, 'warbank')).toBe('cache:1790000000')
      expect(j.sections.recipes).toEqual({ source: 'cache', at: 1790000000, lines: [
        { line: 197, name: 'Tailoring', at: 1790000000, recipes: [[5, [[2589, 2], [7, 7]]], [6, []]] },
      ] })
      expect(j.sections.flightPaths).toEqual({ source: 'cache', at: 1790000000, ids: [2, 3] })
      expect(j.sections.questsDone.ids).toEqual([3, 5, 8, 9]) // the cached 8 and 9 and what the game said
      expect(decoded(m).sections!.recipes).toHaveLength(1)
    })
  })

  describe('bank and warband bank in the cache', () => {
    let m: Map<string, string>
    beforeAll(() => { m = scn('bank-cache') })

    it('are read while the bank is open and say so once, when it closes', () => {
      expect(plain(m, 'chat-open')).toEqual([])
      expect(plain(m, 'chat-closed')).toEqual(['wowchar: saved the bank and the warband bank.'])
      const j = exportOf(m, 'session1')
      expect(j.bank).toEqual([1, 2, 3])
      expect(marker(j, 'bank')).toBe('live:1792000000')
      expect(j.bankSeen).toBe(true)
    })

    it('are in the next session as cache with the time they were read, seen as before', () => {
      const j = exportOf(m, 'session2-cache')
      expect(j.bank).toEqual([1, 2, 3])
      expect(j.warbank).toEqual([91, 92])
      expect(j.bankSeen).toBe(true)
      expect(j.warbankSeen).toBe(true)
      expect(j.bankSource).toBe('tabs')
      expect(marker(j, 'bank')).toBe('cache:1792000000')
      expect(marker(j, 'warbank')).toBe('cache:1792000000')
      const p = decodeAddonExport(m.get('session2-cache')!)
      expect([...obtainedItemIds(p)]).toEqual(expect.arrayContaining([1, 2, 3, 91, 92]))
    })

    it('a new full read replaces the list and is live again; saying so only when something changed', () => {
      const j = exportOf(m, 'session2-live')
      expect(j.bank).toEqual([7, 8])
      expect(marker(j, 'bank')).toBe(`live:${1792000000 + 3 * 86400 + 60}`)
      expect(plain(m, 'chat-session2')).toEqual(['wowchar: saved the bank.'])
      expect(plain(m, 'chat-same-again')).toEqual([])
    })

    it('/wowchar reset clears this character: the cache is gone, the bank is not seen, one line is said', () => {
      expect(plain(m, 'chat-reset')).toEqual(['wowchar: cleared the saved data of this character.'])
      expect(json(m, 'db-after-reset')).toEqual({ Forever: [] })
      const j = exportOf(m, 'after-reset')
      expect(j.bank).toEqual([])
      expect(j.bankSeen).toBe(false)
      expect(marker(j, 'bank')).toBe('missing:open_bank')
    })
  })

  describe('recipes', () => {
    it('a filtered view first, other recipes later: earlier ones are kept, new ones added, never replaced', () => {
      const m = scn('recipes')
      const first = exportOf(m, 'first').sections.recipes
      expect(first).toEqual({ source: 'live', at: 1792000000, lines: [{ line: 197, name: 'Tailoring', at: 1792000000, recipes: [[1, [[2589, 2], [2320, 1]]], [2, [[2589, 3]]]] }] })
      const second = exportOf(m, 'second').sections.recipes.lines[0].recipes
      expect(second.map((r: any) => r[0])).toEqual([1, 2, 3])
      expect(second[2]).toEqual([3, [[4306, 1]]])
      expect(exportOf(m, 'before').sections.recipes).toEqual({ source: 'missing', why: 'open_profession_window' })
    })

    it('reads the reagents of the first quality tier only; skips currency, optional and finishing slots, and recipes not learned', () => {
      const lines = exportOf(scn('recipes'), 'first').sections.recipes.lines[0].recipes
      expect(lines[1]).toEqual([2, [[2589, 3]]]) // currency, required=false and a finishing slot are not there
    })

    it('several list updates are one capture (debounced), and it says one line, only when recipes were new', () => {
      const m = scn('recipes')
      expect(json(m, 'timers')).toEqual([1])
      expect(plain(m, 'chat-before-flush')).toEqual([])
      expect(plain(m, 'chat-first')).toEqual(['wowchar: saved 2 Tailoring recipes.'])
      expect(plain(m, 'chat-second')).toEqual(['wowchar: saved 3 Tailoring recipes.'])
      expect(plain(m, 'chat-third')).toEqual([])
    })

    it('each profession is its own line with its own time', () => {
      const lines = exportOf(scn('recipes'), 'two-professions').sections.recipes.lines
      expect(lines.map((l: any) => [l.line, l.name])).toEqual([[129, 'First Aid'], [197, 'Tailoring']])
    })

    it.each(['all', 'all-empty'])('with GetAllRecipeIDs (%s): the full list when it has one, the filtered view when it is empty', (variant) => {
      const m = scn('recipes', variant)
      const ids = exportOf(m, 'first').sections.recipes.lines[0].recipes.map((r: any) => r[0])
      expect(ids).toEqual(variant === 'all' ? [1, 2, 3] : [1, 2])
    })

    it('a linked, guild or NPC window, combat, and a window with no base profession save nothing', () => {
      const m = scn('recipes-skipped')
      expect(plain(m, 'chat')).toEqual([])
      expect(exportOf(m, 'nothing-saved').sections.recipes).toEqual({ source: 'missing', why: 'open_profession_window' })
      expect(exportOf(m, 'own-window').sections.recipes.lines[0].recipes).toEqual([[1, [[2589, 2]]]])
    })

    it('a client without C_Timer captures at once', () => {
      const m = scn('recipes-no-timer')
      expect(plain(m, 'chat')).toEqual(['wowchar: saved 1 Tailoring recipe.'])
      expect(exportOf(m).sections.recipes.lines[0].recipes).toHaveLength(1)
    })

    it('a profession keeps at most 600 recipes and the export says it cut', () => {
      const m = scn('recipes-cap')
      const j = exportOf(m)
      expect(j.sections.recipes.lines[0].recipes).toHaveLength(ADDON_LIST_CAPS.recipesPerLine)
      expect(j.truncated).toBe(true)
      expect(decoded(m).sections!.recipes![0]!.recipes).toHaveLength(ADDON_LIST_CAPS.recipesPerLine)
    })
  })

  describe('reputation and the quest log', () => {
    it('collapsed headers are closed again after the read, from the bottom up', () => {
      const m = scn('reputation')
      expect(json(m, 'log')).toEqual(['expand-all', 'collapse:1'])
      expect(json(m, 'collapsed-after')).toEqual([true])
      expect(exportOf(m).sections.reputation.factions).toHaveLength(3)
    })

    it('without Expand/Collapse functions nothing is touched and the visible rows are read', () => {
      const m = scn('reputation', 'no-collapse')
      expect(json(m, 'log')).toEqual([])
      expect(exportOf(m).sections.reputation.factions).toEqual([[169, 4, 0, 0, 3000, 'Steamwheedle Cartel']])
    })

    it('a hidden (secret) value makes the section missing/in_combat', () => {
      const j = exportOf(scn('secret'))
      expect(j.sections.player).toEqual({ source: 'missing', why: 'in_combat' })
      expect(j.sections.reputation).toEqual({ source: 'missing', why: 'in_combat' })
      expect(marker(j, 'questLog')).toBe('live')
    })
  })

  describe('flight paths', () => {
    it('are read when a flight map opens and merged into the cache; a node discovered while it is open is added', () => {
      const m = scn('taxi')
      expect(exportOf(m, 'before').sections.flightPaths).toEqual({ source: 'missing', why: 'open_flight_map' })
      expect(plain(m, 'chat')).toEqual(['wowchar: saved 3 flight paths.'])
      expect(exportOf(m, 'opened').sections.flightPaths).toEqual({ source: 'live', at: 1792000000, ids: [11, 12, 14] })
      expect(plain(m, 'chat-status')).toEqual(['wowchar: saved 4 flight paths.'])
      expect(exportOf(m, 'closed').sections.flightPaths.ids).toEqual([11, 12, 14, 99])
    })

    it('after the map closes, a status change does nothing', () => {
      expect(plain(scn('taxi'), 'chat-closed')).toEqual([])
    })

    it('without GetTaxiMapID the player\'s map and its parents are asked', () => {
      expect(exportOf(scn('taxi', 'no-map-function'), 'opened').sections.flightPaths.ids).toEqual([11, 12, 14])
    })

    it('only unreachable and undiscovered nodes: nothing is saved', () => {
      expect(exportOf(scn('taxi', 'unreachable-only'), 'opened').sections.flightPaths).toEqual({ source: 'missing', why: 'open_flight_map' })
    })

    it('a client without C_TaxiMap: missing/not_available', () => {
      expect(exportOf(scn('taxi', 'none'), 'opened').sections.flightPaths).toEqual({ source: 'missing', why: 'not_available' })
    })
  })

  describe('legacy', () => {
    it('is cached when read and answers from the cache when the trees are not ready', () => {
      const m = scn('legacy')
      expect(marker(exportOf(m, 'first'), 'legacy')).toBe('live:1792000000')
      const again = exportOf(m, 'not-ready')
      expect(marker(again, 'legacy')).toBe('cache:1792000000')
      expect(again.sections.legacy.trees).toHaveLength(3)
      expect(again.sections.legacy.points).toEqual({ available: 5, cap: 50, spent: 20 })
    })

    it('not ready and nothing cached: missing/not_loaded', () => {
      expect(exportOf(scn('legacy', 'login'), 'first').sections.legacy).toEqual({ source: 'missing', why: 'not_loaded' })
    })

    it('the cache survives into the next session', () => {
      const m = scn('legacy-cache')
      expect(marker(exportOf(m, 'session2'), 'legacy')).toBe('cache:1792000000')
      expect(decoded(m, 'session2').sections!.legacy!.trees[0]).toEqual({ tree: 1187, spent: 8, nodes: [{ node: 201, rank: 1, entry: 5 }] })
    })

    it('uses Constants.LegacyConsts when the game has it', () => {
      expect(exportOf(scn('legacy', 'constants'), 'first').sections.legacy.trees.map((t: any) => t.tree)).toEqual([1187, 1188, 1189])
    })
  })

  describe('combat', () => {
    it('/wowchar in combat says one line, opens nothing, and the window opens when combat ends (once)', () => {
      const m = scn('combat')
      expect(plain(m, 'chat-combat')).toEqual(['wowchar: in combat. The export window opens when combat ends.'])
      expect(json(m, 'window-made')).toEqual([false])
      expect(m.get('after-combat')!.startsWith(PREFIX)).toBe(true)
      expect(json(m, 'not-opened-twice')).toEqual([true])
    })
  })

  describe('/wowchar', () => {
    it('anything but «reset» opens the window; reset (any case) opens nothing', () => {
      const m = scn('unknown-command')
      expect(m.get('export')!.startsWith(PREFIX)).toBe(true)
      expect(json(m, 'after-reset')).toEqual([true]) // the window still shows the first text
    })
  })

  describe('the window', () => {
    it('is a BasicFrameTemplateWithInset frame: 620 x 470, DIALOG strata, movable, clamped, drag with the left button, closed by Escape', () => {
      const m = scn('window')
      expect(json(m, 'frame')).toEqual({
        template: 'BasicFrameTemplateWithInset', width: 620, height: 470, strata: 'DIALOG', movable: true, clamped: true,
        shown: true, special: 'WowcharExportFrame', drag: 'LeftButton', title: 'wowchar export',
      })
    })

    it('shows the character line, a row for each section, the export header, the size and the paste line', () => {
      const lines = json(scn('window'), 'window') as string[]
      const text = lines.map(l => l.replace(/\|T[^|]*\|t/g, '').replace(/\|c[0-9a-fA-F]{8}|\|r/g, ''))
      expect(text[0]).toBe('wowchar export')
      expect(text[1]).toBe('Thor  level 60 Night Elf Warrior  - Forever')
      expect(text.slice(2, 17)).toEqual([
        ' Equipped items  read now',
        ' Bags  read now',
        ' Bank  open your bank',
        ' Warband bank  open your bank',
        ' Professions  read now',
        ' Recipes (3)  read now',
        ' Completed quests (3)  read now',
        ' Quest log (2)  read now',
        ' Reputation (3)  read now',
        ' Gold, level, XP  read now',
        ' Talents  read now',
        ' Legacy  read now',
        ' Flight paths (3)  read now',
        ' Honor rank (season)  read now',
        ' Class spells (3)  read now',
      ])
      expect(text[17]).toBe('Export text (selected: press Ctrl+C to copy)')
      expect(text[18]).toMatch(/^[\d,]+ characters \(\d+\.\d KB\), format 3\.$/)
      expect(text[19]).toBe('Paste it on wowchar.toaweb.com > My characters')
    })

    it('draws the state with the ready-check textures: Ready for live, Waiting for cache, NotReady for missing', () => {
      const lines = json(scn('window'), 'window') as string[]
      expect(lines[2]).toContain('|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t')
      expect(lines[4]).toContain('|TInterface\\RaidFrame\\ReadyCheck-NotReady:14|t')
      // the pipes are in the window's texts only: the export itself has none (checked in every other test)
    })

    it('has the text selected and focused, unlimited, equal to the export; typing puts the export back', () => {
      const m = scn('window')
      expect(json(m, 'box')).toEqual({ highlighted: true, focused: true, maxLetters: 0, maxBytes: 0, same: true, kind: 'EditBox' })
      expect(json(m, 'after-typing')).toEqual([true])
    })

    it('Escape in the box closes the window and gives the keyboard back; it can be opened again; Hide gives the keyboard back', () => {
      const m = scn('window')
      expect(json(m, 'after-escape')).toEqual([false, false])
      expect(json(m, 'reopened')).toEqual([true])
      expect(json(m, 'after-hide')).toEqual([false])
    })

    it('«Select all» selects the text and focuses the box; «Close» hides the window', () => {
      const m = scn('window-buttons')
      expect(json(m, 'select-all')).toEqual([true, true])
      expect(json(m, 'close')).toEqual([false, false])
    })

    it('falls back when a template is missing: a plain frame with a backdrop, then no backdrop; the text box falls back to a scroll frame with an edit box', () => {
      const frame = (variant: string) => json(scn('window', variant), 'frame')
      expect(frame('no-templates')).toMatchObject({ template: 'BackdropTemplate', width: 620, shown: true })
      expect(frame('no-backdrop')).toMatchObject({ template: 'none', shown: true })
      expect(frame('no-input-template')).toMatchObject({ template: 'BasicFrameTemplateWithInset', shown: true })
      for (const variant of ['no-templates', 'no-backdrop', 'no-input-template']) {
        const m = scn('window', variant)
        expect(json(m, 'box')).toEqual({ highlighted: true, focused: true, maxLetters: 0, maxBytes: 0, same: true, kind: 'EditBox' })
        expect(json(m, 'after-escape')).toEqual([false, false])
      }
    })

    it('a client without UISpecialFrames still gets a working window', () => {
      const m = scn('window', 'no-special-frames')
      expect(json(m, 'frame')).toMatchObject({ special: 'none', shown: true })
    })
  })

  describe('the size of a maxed character', () => {
    // test/lua/maxed-stub.lua: level 60, 1,500 completed quests, a full quest log, two full
    // professions (260 recipes each) plus First Aid, Cooking and Fishing, full bags, bank and
    // warband bank, 80 reputations, talents, three Legacy trees, 60 flight paths, 150 spells.
    let line: string
    let p: AddonExport
    beforeAll(() => {
      line = script('maxed-stub', 'maxed')[0]!
      p = decodeAddonExport(line)
    })

    it('decodes, every section live, and its size is the number the length limit and the caps were chosen from', () => {
      const bytes = Buffer.byteLength(line)
      // eslint-disable-next-line no-console
      console.info(`maxed character export: ${line.length} characters, ${bytes} bytes (${(bytes / 1024).toFixed(1)} KiB); MAX_ENCODED_LENGTH ${MAX_ENCODED_LENGTH} is ${(MAX_ENCODED_LENGTH / line.length).toFixed(2)} times that`)
      expect(line).not.toContain('|')
      expect(p.format).toBe(3)
      for (const name of SECTION_NAMES) expect(p.sections!.sources[name].source, name).toBe('live')
      // pinned with room (the exact number moves with every change to the format; docs/addon-export-format-3.md says what it was)
      expect(line.length).toBeGreaterThan(55_000)
      expect(line.length).toBeLessThan(70_000)
      // headroom: the limit is about twice the measurement
      expect(MAX_ENCODED_LENGTH / line.length).toBeGreaterThan(1.8)
    })

    it('every list is at most half its cap (the caps are about twice the measured numbers), except the two fixed-size ones', () => {
      const s = p.sections!
      const measured = {
        questsDone: s.questsDone!.length,
        questLog: s.questLog!.quests.length,
        objectivesPerQuest: Math.max(...s.questLog!.quests.map(q => q.objectives.length)),
        factions: s.reputation!.length,
        recipeLines: s.recipes!.length,
        recipesPerLine: Math.max(...s.recipes!.map(l => l.recipes.length)),
        reagentsPerRecipe: Math.max(...s.recipes!.flatMap(l => l.recipes.map(r => r.reagents.length))),
        nodesPerTree: Math.max(...s.talents!.map(t => t.nodes.length), ...s.legacy!.trees.map(t => t.nodes.length)),
        flightPaths: s.flightPaths!.length,
        classSpells: s.classSpells!.length,
      }
      expect(measured).toEqual({
        questsDone: 1500, questLog: 25, objectivesPerQuest: 3, factions: 80, recipeLines: 5, recipesPerLine: 260,
        reagentsPerRecipe: 6, nodesPerTree: 70, flightPaths: 60, classSpells: 150,
      })
      for (const [name, count] of Object.entries(measured)) {
        expect(ADDON_LIST_CAPS[name as keyof typeof ADDON_LIST_CAPS], name).toBeGreaterThanOrEqual(count * 1.9)
      }
      expect(s.legacy!.trees).toHaveLength(3) // the game has three; the cap of four leaves room for one
      expect(p.bags.length + p.bank.length + p.warbank.length).toBeGreaterThan(700)
    })

    it('saturated (every list at its cap, more than any character has) is cut to fit: the lowest-priority sections are left out, in order, as missing/too_large', () => {
      const text = script('maxed-stub', 'saturated')[0]!
      expect(text.length).toBeLessThanOrEqual(MAX_ENCODED_LENGTH)
      const j = parseExport(text)
      const order = ['classSpells', 'flightPaths', 'legacy', 'talents', 'honor', 'reputation', 'questLog', 'recipes']
      const dropped = order.map(n => j.sections[n].source === 'missing' && j.sections[n].why === 'too_large')
      expect(dropped.some(Boolean)).toBe(true)
      // a prefix of the order: once a section was kept, no later one was left out
      expect(dropped.join()).toBe([...dropped].sort((a, b) => Number(b) - Number(a)).join())
      expect(j.truncated).toBe(true)
      expect(decodeAddonExport(text).sections!.sources.recipes.why).toBe('too_large')
    })

    it('the saturated export, wrapped as the route body { export: text }, is within ADDON_BODY_MAX in UTF-8 bytes (true, but weak: this stub has almost no quotes; the next test is the one that reaches the limit)', () => {
      const text = script('maxed-stub', 'saturated')[0]!
      const body = Buffer.byteLength(JSON.stringify({ export: text }), 'utf8')
      const escapes = body - Buffer.byteLength(text, 'utf8')
      // eslint-disable-next-line no-console
      console.info(`saturated export body: ${body} bytes, ${escapes} of them escapes; ADDON_BODY_MAX ${ADDON_BODY_MAX}`)
      expect(body).toBeLessThanOrEqual(ADDON_BODY_MAX)
      // and the same for the maxed character
      expect(Buffer.byteLength(JSON.stringify({ export: line }), 'utf8')).toBeLessThanOrEqual(ADDON_BODY_MAX)
    })

    it('a text of quotes and backslashes: under the 128 KiB limit but over the body limit, so the addon leaves sections out until the BODY fits, and the server takes it', () => {
      // test/lua/maxed-stub.lua quotes: objective texts (255) and faction names (100) of only " and \,
      // two characters each in the export and four in the body
      const [text, trace] = script('maxed-stub', 'quotes') as [string, string]
      const steps = trace.split(';').map((x) => {
        const [name, length, body] = x.split(':') as [string, string, string]
        return { name, length: Number(length), body: Number(body) }
      })
      const first = steps[0]!
      const last = steps[steps.length - 1]!
      // eslint-disable-next-line no-console
      console.info(`quotes stub, body bytes by step: ${steps.map(s => `${s.name} ${s.length}/${s.body}`).join(', ')}; ADDON_BODY_MAX ${ADDON_BODY_MAX}`)

      // before any drop: the text is inside the length limit, the body is not (the old check, on the text alone, would have let it through to a 413)
      expect(first.name).toBe('-')
      expect(first.length).toBeLessThanOrEqual(MAX_ENCODED_LENGTH)
      expect(first.body).toBeGreaterThan(ADDON_BODY_MAX)
      // every step but the last was still over the body limit while the text was not over its own
      for (const s of steps.slice(0, -1)) {
        expect(s.length).toBeLessThanOrEqual(MAX_ENCODED_LENGTH)
        expect(s.body).toBeGreaterThan(ADDON_BODY_MAX)
      }
      expect(last.body).toBeLessThanOrEqual(ADDON_BODY_MAX)
      expect(steps.length).toBeGreaterThan(1)

      // what the browser sends, measured with the real JSON.stringify in UTF-8 bytes
      const body = Buffer.byteLength(JSON.stringify({ export: text }), 'utf8')
      expect(text.length).toBe(last.length)
      expect(body).toBeLessThanOrEqual(ADDON_BODY_MAX)
      expect(body).toBeLessThanOrEqual(last.body) // the addon's number is never below the real one
      expect(last.body - body).toBeLessThanOrEqual(16) // and not far above it (the wrapper's few bytes)
      expect(text.length).toBeLessThanOrEqual(MAX_ENCODED_LENGTH)

      // the left-out sections are a prefix of the drop order, marked too_large, and the strict server decodes the text
      const dropped = steps.slice(1).map(s => s.name)
      const j = parseExport(text)
      for (const name of dropped) expect(j.sections[name]).toMatchObject({ source: 'missing', why: 'too_large' })
      expect(j.sections.questLog.source).toBe('live') // the drop stopped as soon as the body fitted
      expect(decodeAddonExport(text).sections!.sources.reputation.why).toBe('too_large')
    })
  })
})
