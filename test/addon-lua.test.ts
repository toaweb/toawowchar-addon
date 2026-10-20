import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { beforeAll, describe, expect, it } from 'vitest'
import { ADDON_VERSION } from '../shared/addon-release'
import { MAX_BONUS_IDS_PER_ITEM, MAX_IDS_PER_ARRAY, decodeAddonExport, obtainedItemIds } from '../server/utils/addon-export'

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

const PREFIX = 'WOWCHAR:2:'
/** The JSON of an export line; the line must be a format 2 string with no pipe. */
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

  it('the version is the shared constant in the code and in the .toc, and it emits format 2', () => {
    const code = readFileSync(`${ROOT}/addon/WowcharExport/WowcharExport.lua`, 'utf8')
    const toc = readFileSync(`${ROOT}/addon/WowcharExport/WowcharExport.toc`, 'utf8')
    expect(code).toContain(`local ADDON_VERSION = "${ADDON_VERSION}"`)
    expect(code).toContain('local FORMAT_VERSION = 2')
    expect(toc).toMatch(new RegExp(`^## Version: ${ADDON_VERSION.replace(/\./g, '\\.')}$`, 'm'))
    const json = exportFor('eu')
    expect(json.format).toBe(2)
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

    it('the format stays 2, the other identity keys are as before, and the server decodes it', () => {
      const j = parseExport(script('race-stub', 'nightelf')[0]!)
      expect(j.format).toBe(2)
      expect(Object.keys(j.identity).sort()).toEqual(
        ['classFile', 'classID', 'faction', 'guid', 'hardcore', 'level', 'name', 'race', 'realm', 'region'].sort(),
      )
      const p = decodeAddonExport(`${PREFIX}${JSON.stringify(j)}`)
      expect(p.identity).toMatchObject({ race: 'NightElf', faction: 'Alliance' })
    })

    it.each(['nil-returns', 'missing', 'erroring', 'wrongtypes', 'empty', 'name-only'])(
      'scenario %s (nil, a missing or raising function, a non-string, an empty string) leaves both keys out', (scenario) => {
        const j = parseExport(script('race-stub', scenario)[0]!)
        expect(j.format).toBe(2)
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
      expect(line).toBe(readFileSync(`${ROOT}/app/test/fixtures/addon-export-v2.txt`, 'utf8').trim())
    })

    it('has no pipe, and the pipes of a profession name come back after parsing', () => {
      expect(line).not.toContain('|')
      expect(parseExport(line).professions[1].name).toBe('Zulöte |cffff0000"Bergbau"|r')
    })

    it('decodes on the server (the real serializer against the real decoder)', () => {
      const p = decodeAddonExport(line)
      expect(p.format).toBe(2)
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
})
