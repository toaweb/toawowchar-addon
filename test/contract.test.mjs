// test/contract.json is a copy of the numbers wowchar owns, and test/lib/contract.mjs is a
// port of the strict shape check of wowchar's decodeAddonExport. The Lua tests lean on both
// ("the server would take this text"), so they are tested here: the example export passes,
// and every kind of damage is refused for the reason it should be. wowchar's own tests run
// the real decoder against dist/examples/ (see AGENTS.md); this is the addon side's check.
import { readFileSync } from 'node:fs'
import { describe, it } from './lib/suite.mjs'
import { expect } from './lib/expect.mjs'
import {
  ADDON_BODY_MAX, ADDON_CACHED_SECTIONS, ADDON_LIST_CAPS, AddonExportError, MAX_ENCODED_LENGTH, MISSING_REASONS,
  PREFIX, SECTION_NAMES, SECTION_SOURCES, contract, decodeAddonExport,
} from './lib/contract.mjs'

const EXAMPLE = readFileSync(new URL('./fixtures/export-full.txt', import.meta.url), 'utf8').trim()
const wire = () => JSON.parse(EXAMPLE.slice(PREFIX.length))
const text = json => `${PREFIX}${JSON.stringify(json)}`

/** The code and message of the refusal, or null when the text is accepted. */
function refusal(input) {
  try {
    decodeAddonExport(input)
    return null
  }
  catch (e) {
    if (!(e instanceof AddonExportError)) throw e
    return `${e.code}: ${e.message}`
  }
}

describe('test/contract.json', () => {
  it('is the copy of wowchar\'s contract: where it came from is recorded, and the lists are well formed', () => {
    expect(contract.copiedFrom.repository).toBe('toaweb/toawowchar')
    expect(contract.copiedFrom.commit).toMatch(/^[0-9a-f]{40}$/)
    expect(contract._about.join(' ')).toContain('toaweb/toawowchar owns these values')
    expect(SECTION_NAMES).toHaveLength(15)
    expect(new Set(SECTION_NAMES).size).toBe(15)
    expect(new Set(MISSING_REASONS).size).toBe(MISSING_REASONS.length)
    expect([...SECTION_SOURCES]).toEqual(['live', 'cache', 'missing'])
    expect(PREFIX).toBe('WOWCHAR:3:')
  })

  it('cached sections are sections of the export, once each, in the export\'s order', () => {
    expect(new Set(ADDON_CACHED_SECTIONS).size).toBe(ADDON_CACHED_SECTIONS.length)
    const positions = ADDON_CACHED_SECTIONS.map(n => SECTION_NAMES.indexOf(n))
    expect(positions.every(p => p >= 0)).toBe(true)
    expect(positions).toEqual([...positions].sort((a, b) => a - b))
  })

  it('the body limit is the text limit plus 16 KiB for the JSON escapes', () => {
    expect(ADDON_BODY_MAX).toBe(MAX_ENCODED_LENGTH + 16 * 1024)
    expect(contract.exportFormat.addonBodySlack).toBe(16 * 1024)
  })

  it('has every cap and bound the decoder port reads (a number missing would make a check vacuous)', () => {
    for (const key of ['questsDone', 'questLog', 'objectivesPerQuest', 'objectiveText', 'factions', 'nameText', 'recipeLines',
      'recipesPerLine', 'reagentsPerRecipe', 'talentTrees', 'nodesPerTree', 'legacyTrees', 'challenges', 'flightPaths', 'classSpells']) {
      expect(Number.isInteger(ADDON_LIST_CAPS[key]), key).toBe(true)
    }
    for (const key of ['id', 'reagentCount', 'traitRank', 'counter', 'money', 'level', 'reaction', 'honorRank', 'hiddenQuests', 'count',
      'timeMin', 'timeMax', 'characterName', 'realm', 'classFile', 'specName', 'portal', 'professionName']) {
      expect(Number.isInteger(contract.bounds[key]), key).toBe(true)
    }
    for (const key of ['maxEquipped', 'maxGemsPerItem', 'maxProfessions', 'maxSlot']) {
      expect(Number.isInteger(contract.decoder[key]), key).toBe(true)
    }
  })
})

describe('the decoder port', () => {
  it('takes the example export, whitespace around it, and gives the typed sections', () => {
    expect(refusal(EXAMPLE)).toBeNull()
    expect(refusal(`  ${EXAMPLE}\n`)).toBeNull()
    const p = decodeAddonExport(EXAMPLE)
    expect(p.identity.name).toBe('Thorin')
    expect(Object.keys(p.sections.sources).sort()).toEqual([...SECTION_NAMES].sort())
    expect(p.sections.reputation[0]).toEqual({ id: 72, reaction: 5, standing: 3500, floor: 3000, ceiling: 9000, name: 'Stormwind' })
  })

  it.each([
    ['a number', 5, 'not_a_string'],
    ['undefined', undefined, 'not_a_string'],
    ['no prefix', '{}', 'bad_prefix'],
    ['format 2', 'WOWCHAR:2:{}', 'bad_prefix'],
    ['text that is not JSON', `${PREFIX}{nope`, 'bad_json'],
    ['a JSON array', `${PREFIX}[]`, 'bad_shape'],
    ['a JSON null', `${PREFIX}null`, 'bad_shape'],
    ['a text over the length limit', `${PREFIX}${' '.repeat(MAX_ENCODED_LENGTH)}x`, 'too_long'],
    ['a text far over the limit, before it is trimmed', `${PREFIX}${'x'.repeat(MAX_ENCODED_LENGTH + 1000)}`, 'too_long'],
  ])('refuses %s with %s', (_what, input, code) => {
    expect(refusal(input)).toMatch(new RegExp(`^${code}:`))
  })

  /** Each case changes a copy of the valid export and says which path the refusal names. */
  const damage = [
    ['an unknown top-level key', j => { j.extra = 1 }, 'export: unknown field'],
    ['the format number not matching the prefix', j => { j.format = 2 }, 'export.format'],
    ['the reserved completedQuestIds', j => { j.completedQuestIds = [1] }, 'export: unknown field'],
    ['no identity', j => { delete j.identity }, 'identity: missing field'],
    ['an unknown identity key', j => { j.identity.account = 'x' }, 'identity: unknown field'],
    ['an empty name', j => { j.identity.name = '' }, 'identity.name: must not be empty'],
    ['a name over the bound', j => { j.identity.name = 'x'.repeat(65) }, 'identity.name: text too long'],
    ['a level of 0', j => { j.identity.level = 0 }, 'identity.level: value out of range'],
    ['a level over 255', j => { j.identity.level = 256 }, 'identity.level: value out of range'],
    ['a region the server does not know', j => { j.identity.region = 'XX' }, 'identity.region: value out of range'],
    ['a realm over 100 characters', j => { j.identity.realm = 'r'.repeat(101) }, 'identity.realm: text too long'],
    ['a client that is not an object', j => { j.client = 5 }, 'client: must be an object'],
    ['an unknown equipped key', j => { j.equipped[0].link = '|Hitem|h' }, 'equipped: unknown field'],
    ['an equipped slot over 255', j => { j.equipped[0].slot = 256 }, 'equipped.slot: value out of range'],
    ['an item id of 0', j => { j.equipped[0].itemId = 0 }, 'equipped.itemId: value out of range'],
    ['an item id over 2^31-1', j => { j.bags[0] = 2 ** 31 }, 'bags: value out of range'],
    ['five gems', j => { j.equipped[0].gemIds = [1, 2, 3, 4, 5] }, 'equipped.gemIds: too many entries'],
    ['33 bonus ids', j => { j.equipped[0].bonusIds = Array.from({ length: 33 }, (_, i) => i + 1) }, 'equipped.bonusIds: too many entries'],
    ['more than 32 equipped entries', j => { j.equipped = Array.from({ length: 33 }, (_, i) => ({ slot: i, itemId: 1 })) }, 'equipped: too many entries'],
    ['501 bag ids', j => { j.bags = Array.from({ length: 501 }, (_, i) => i + 1) }, 'bags: too many entries'],
    ['bankSeen that is not a boolean', j => { j.bankSeen = 1 }, 'bankSeen: must be true or false'],
    ['a bankSource the server does not know', j => { j.bankSource = 'vault' }, 'bankSource: value out of range'],
    ['a bank flag that the bank section contradicts', j => { j.bankSeen = false }, 'bankSeen: does not match the bank section'],
    ['a warband flag that the section contradicts', j => { j.warbankSeen = false }, 'warbankSeen: does not match the warband bank section'],
    ['an unknown profession key', j => { j.professions[0].icon = 1 }, 'professions: unknown field'],
    ['a profession rank over 1e6', j => { j.professions[0].rank = 1_000_001 }, 'professions.rank: value out of range'],
    ['more than 32 professions', j => { j.professions = Array.from({ length: 33 }, () => ({ name: 'x' })) }, 'professions: too many entries'],
    ['a capturedAt before 2001', j => { j.capturedAt = 999_999_999 }, 'capturedAt: value out of range'],
    ['no sections', j => { delete j.sections }, 'sections: must be an object'],
    ['a section missing', j => { delete j.sections.honor }, 'sections.honor: missing field'],
    ['an unknown section', j => { j.sections.mounts = { source: 'live' } }, 'sections: unknown field'],
    ['a source the server does not know', j => { j.sections.bags.source = 'guess' }, 'bags.source: value out of range'],
    ['a missing section without a reason', j => { j.sections.honor = { source: 'missing' } }, 'honor.why: value out of range'],
    ['a reason the server does not know', j => { j.sections.honor = { source: 'missing', why: 'because' } }, 'honor.why: value out of range'],
    ['a missing section with a time', j => { j.sections.honor = { source: 'missing', why: 'in_combat', at: 1_792_000_000 } }, 'honor.at: a missing section has no time'],
    ['a missing section with data', j => { j.sections.honor = { source: 'missing', why: 'in_combat', seasonRank: 1 } }, 'honor.seasonRank: a missing section has no data'],
    ['a reason on a live section', j => { j.sections.bags.why = 'in_combat' }, 'bags.why: only a missing section has a reason'],
    ['a cached section without a time', j => { delete j.sections.flightPaths.at; j.sections.flightPaths.source = 'cache' }, 'flightPaths.at: a cached section needs a time'],
    ['a section time before 2001', j => { j.sections.flightPaths.at = 5 }, 'flightPaths.at: value out of range'],
    ['a section without its data', j => { delete j.sections.questsDone.ids }, 'questsDone.ids: missing field'],
    ['5,001 completed quests', j => { j.sections.questsDone.ids = Array.from({ length: 5001 }, (_, i) => i + 1) }, 'questsDone.ids: too many entries'],
    ['a quest id of 0', j => { j.sections.questsDone.ids = [0] }, 'questsDone.ids: value out of range'],
    ['a reputation row with five values', j => { j.sections.reputation.factions[0].pop() }, 'reputation.factions: wrong number of values'],
    ['a reaction over 20', j => { j.sections.reputation.factions[0][1] = 21 }, 'reputation.reaction: value out of range'],
    ['a standing over 1e9', j => { j.sections.reputation.factions[0][2] = 1_000_000_001 }, 'reputation.standing: value out of range'],
    ['a faction name with a control character', j => { j.sections.reputation.factions[0][5] = 'a\nb' }, 'reputation.name: has characters that are not allowed'],
    ['a quest log entry with an unknown key', j => { j.sections.questLog.quests[0].title = 'x' }, 'questLog.quests: unknown field'],
    ['a quest done that is not a boolean', j => { j.sections.questLog.quests[0].done = 'yes' }, 'questLog.done: must be true or false'],
    ['an objective count over 1e9', j => { j.sections.questLog.quests[0].objectives[0].have = 1_000_000_001 }, 'questLog.objectives.have: value out of range'],
    ['more than 1000 hidden quests', j => { j.sections.questLog.hidden = 1001 }, 'questLog.hidden: value out of range'],
    ['a player level of 0', j => { j.sections.player.level = 0 }, 'player.level: value out of range'],
    ['a player money value over the bound', j => { j.sections.player.money = 10_000_000_000_001 }, 'player.money: value out of range'],
    ['a recipe with one value', j => { j.sections.recipes.lines[0].recipes[0] = [1] }, 'recipes.recipes: wrong number of values'],
    ['a reagent count of 10000', j => { j.sections.recipes.lines[0].recipes[0][1][0][1] = 10_000 }, 'recipes.reagents.count: value out of range'],
    ['a recipe line without a time', j => { delete j.sections.recipes.lines[0].at }, 'recipes.at: must be a whole number'],
    ['a trait rank of 256', j => { j.sections.talents.trees[0].nodes[0][1] = 256 }, 'talents.rank: value out of range'],
    ['a talent tree with a spent count', j => { j.sections.talents.trees[0].spent = 1 }, 'talents.trees: unknown field'],
    ['a Legacy tree without a spent count', j => { delete j.sections.legacy.trees[0].spent }, 'legacy.spent: must be a whole number'],
    ['a Legacy points key the server does not know', j => { j.sections.legacy.points.level = 1 }, 'legacy.points: unknown field'],
    ['a season rank over 1000', j => { j.sections.honor.seasonRank = 1001 }, 'honor.seasonRank: value out of range'],
    ['401 class spells', j => { j.sections.classSpells.ids = Array.from({ length: 401 }, (_, i) => i + 1) }, 'classSpells.ids: too many entries'],
  ]
  it.each(damage)('refuses %s', (_what, change, path) => {
    const j = wire()
    change(j)
    const reason = refusal(text(j))
    expect(reason, 'the refusal').not.toBeNull()
    expect(reason).toContain(path)
  })

  it('what the server leaves alone is left alone: a race or faction that does not fit is dropped, not refused', () => {
    const j = wire()
    j.identity.race = 'Not A Race 9'
    j.identity.faction = 'Pirates'
    expect(refusal(text(j))).toBeNull()
    const p = decodeAddonExport(text(j))
    expect(p.identity).not.toHaveProperty('race')
    expect(p.identity).not.toHaveProperty('faction')
  })

  it('an empty object stands for an empty list (the game\'s serializer may write {})', () => {
    const j = wire()
    j.bags = {}
    expect(decodeAddonExport(text(j)).bags).toEqual([])
    j.bags = { a: 1 }
    expect(refusal(text(j))).toContain('bags: must be a list')
  })

  it('lists are sorted and de-duplicated the way the server does it', () => {
    const j = wire()
    j.sections.questsDone.ids = [9, 3, 3, 5]
    expect(decodeAddonExport(text(j)).sections.questsDone).toEqual([3, 5, 9])
  })

  it('the values at a bound are accepted, one past it is not (the addon sends exactly the bound)', () => {
    const j = wire()
    j.sections.player.xp = contract.bounds.counter
    j.sections.honor.seasonRank = contract.bounds.honorRank
    j.identity.level = contract.bounds.level
    j.bags = [contract.bounds.id]
    expect(refusal(text(j))).toBeNull()
    j.bags = [contract.bounds.id + 1]
    expect(refusal(text(j))).toContain('bags')
  })
})
