// The export contract and a test-only decoder for it.
//
// wowchar (toaweb/toawowchar) owns the export format: app/shared/addon-sections.ts,
// app/shared/addon-export-format.ts and app/server/utils/addon-export.ts. Its numbers
// are copied to test/contract.json (the header there says where from). This file
// reads them and ports the STRICT SHAPE CHECK of wowchar's `decodeAddonExport` for
// format 3, so a test here can say "the server would take this text" without the
// wowchar app. It is a port for tests only: wowchar tests its real decoder against
// this repository's example exports (dist/examples/), and that is the check that
// counts. When wowchar's decoder changes, this file follows (two pull requests, see
// AGENTS.md).
import { readFileSync } from 'node:fs'

export const contract = JSON.parse(readFileSync(new URL('../contract.json', import.meta.url), 'utf8'))

export const SECTION_NAMES = contract.sectionNames
export const SECTION_SOURCES = contract.sectionSources
export const MISSING_REASONS = contract.missingReasons
export const ADDON_CACHED_SECTIONS = contract.cachedSections
export const ADDON_LIST_CAPS = contract.listCaps
export const ADDON_BOUNDS = contract.bounds
export const MAX_ENCODED_LENGTH = contract.exportFormat.maxEncodedLength
export const ADDON_BODY_MAX = contract.exportFormat.addonBodyMax
export const MAX_IDS_PER_ARRAY = contract.maxIdsPerArray
export const MAX_BONUS_IDS_PER_ITEM = contract.maxBonusIdsPerItem
export const PREFIX = contract.exportFormat.prefix

const B = ADDON_BOUNDS
const CAPS = ADDON_LIST_CAPS
const D = contract.decoder
const MAX_GEMS_PER_ITEM = D.maxGemsPerItem
const MAX_PASTE_SLACK = 64
const RACE_TOKEN_RE = new RegExp(D.raceTokenPattern)

export class AddonExportError extends Error {
  constructor(code, message) {
    super(message)
    this.name = 'AddonExportError'
    this.code = code
  }
}

const fail = (code, message) => { throw new AddonExportError(code, message) }
const refuse = (path, reason) => fail('bad_shape', `${path}: ${reason}`)

const isObject = v => typeof v === 'object' && v !== null && !Array.isArray(v)
const isInt = v => typeof v === 'number' && Number.isSafeInteger(v)

function boundedString(v, max, path) {
  if (typeof v !== 'string') refuse(path, 'must be text')
  if (v.length === 0) refuse(path, 'must not be empty')
  if (v.length > max) refuse(path, 'text too long')
  return v
}

function checkItemId(v, path) {
  if (!isInt(v)) refuse(path, 'must be a whole number')
  if (v <= 0 || v > B.id) refuse(path, 'value out of range')
  return v
}

function checkArray(v, path, max) {
  if (isObject(v) && Object.keys(v).length === 0) return []
  if (!Array.isArray(v)) refuse(path, 'must be a list')
  if (v.length > max) refuse(path, 'too many entries')
  return v
}

const idList = (v, path) => checkArray(v, path, MAX_IDS_PER_ARRAY).map(x => checkItemId(x, path))

function optionalCount(v, path) {
  if (v === undefined || v === null) return undefined
  if (!isInt(v)) refuse(path, 'must be a whole number')
  if (v < 0 || v > B.count) refuse(path, 'value out of range')
  return v
}

function optionalString(v, max, path) {
  if (v === undefined || v === null) return undefined
  if (typeof v !== 'string') refuse(path, 'must be text')
  if (v.length > max) refuse(path, 'text too long')
  const t = v.trim()
  return t === '' ? undefined : t
}

function validateIdentity(id) {
  const identity = { name: boundedString(id.name, B.characterName, 'identity.name') }
  if (id.region !== undefined && id.region !== null) {
    if (typeof id.region !== 'string') refuse('identity.region', 'must be text')
    const r = id.region.trim().toUpperCase()
    if (!D.knownRegions.includes(r)) refuse('identity.region', 'value out of range')
    identity.region = r
  }
  const regionId = optionalCount(id.regionId, 'identity.regionId')
  if (regionId !== undefined) identity.regionId = regionId
  const portal = optionalString(id.portal, B.portal, 'identity.portal')
  if (portal !== undefined) identity.portal = portal
  const realm = optionalString(id.realm, B.realm, 'identity.realm')
  if (realm !== undefined) identity.realm = realm
  const classFile = optionalString(id.classFile, B.classFile, 'identity.classFile')
  if (classFile !== undefined) identity.classFile = classFile
  const classID = optionalCount(id.classID, 'identity.classID')
  if (classID !== undefined) identity.classID = classID
  if (id.level !== undefined && id.level !== null) {
    if (!isInt(id.level)) refuse('identity.level', 'must be a whole number')
    if (id.level < 1 || id.level > B.level) refuse('identity.level', 'value out of range')
    identity.level = id.level
  }
  const specName = optionalString(id.specName, B.specName, 'identity.specName')
  if (specName !== undefined) identity.specName = specName
  // Race and faction never refuse an export: what does not fit is ignored.
  if (typeof id.race === 'string' && RACE_TOKEN_RE.test(id.race)) identity.race = id.race
  if (typeof id.faction === 'string' && D.factions.includes(id.faction)) identity.faction = id.faction
  return identity
}

function optionalId0(v, path) {
  if (v === undefined || v === null) return 0
  if (!isInt(v)) refuse(path, 'must be a whole number')
  if (v < 0 || v > B.id) refuse(path, 'value out of range')
  return v
}

function positiveIdList(v, path, max) {
  if (v === undefined || v === null) return []
  return checkArray(v, path, max).map(x => checkItemId(x, path))
}

const TOP_KEYS = [
  'format', 'addonVersion', 'client', 'capturedAt', 'identity', 'equipped', 'bags',
  'bank', 'bankSeen', 'bankSource', 'warbank', 'warbankSeen', 'truncated',
  'professions', 'sections',
]
const IDENTITY_KEYS = [
  'name', 'region', 'regionId', 'portal', 'realm', 'guid', 'classFile', 'classID',
  'race', 'faction', 'level', 'specID', 'specName', 'hardcore',
]
const EQUIPPED_KEYS = ['slot', 'itemId', 'enchantId', 'gemIds', 'suffixId', 'bonusIds']
const PROFESSION_KEYS = ['name', 'skillLineId', 'rank', 'maxRank']

function onlyKeys(o, allowed, path) {
  for (const key of Object.keys(o)) {
    if (!allowed.includes(key)) refuse(path, 'unknown field')
  }
}

function equipped(e) {
  if (!isObject(e)) refuse('equipped', 'must be an object')
  onlyKeys(e, EQUIPPED_KEYS, 'equipped')
  if (!isInt(e.slot)) refuse('equipped.slot', 'must be a whole number')
  if (e.slot < 0 || e.slot > D.maxSlot) refuse('equipped.slot', 'value out of range')
  return {
    slot: e.slot,
    itemId: checkItemId(e.itemId, 'equipped.itemId'),
    enchantId: optionalId0(e.enchantId, 'equipped.enchantId'),
    suffixId: optionalId0(e.suffixId, 'equipped.suffixId'),
    gemIds: positiveIdList(e.gemIds, 'equipped.gemIds', MAX_GEMS_PER_ITEM),
    bonusIds: positiveIdList(e.bonusIds, 'equipped.bonusIds', MAX_BONUS_IDS_PER_ITEM),
  }
}

function intIn(v, min, max, path) {
  if (!isInt(v)) refuse(path, 'must be a whole number')
  if (v < min || v > max) refuse(path, 'value out of range')
  return v
}

function hasControl(s) {
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c < 0x20 || c === 0x7F) return true
  }
  return false
}

function textIn(v, min, max, path) {
  if (typeof v !== 'string') refuse(path, 'must be text')
  if (v.length < min) refuse(path, 'must not be empty')
  if (v.length > max) refuse(path, 'text too long')
  if (hasControl(v)) refuse(path, 'has characters that are not allowed')
  return v
}

function strictObject(v, keys, path) {
  if (!isObject(v)) refuse(path, 'must be an object')
  onlyKeys(v, keys, path)
  return v
}

function tupleOf(v, length, path) {
  if (!Array.isArray(v) || v.length !== length) refuse(path, 'wrong number of values')
  return v
}

function uniqueBy(list, key) {
  const seen = new Set()
  return list.filter((item) => {
    const k = key(item)
    if (seen.has(k)) return false
    seen.add(k)
    return true
  })
}

function sortedIds(v, path, max) {
  const ids = checkArray(v, path, max).map(x => checkItemId(x, path))
  return [...new Set(ids)].sort((a, b) => a - b)
}

const SOURCE_KEYS = ['source', 'at', 'why']

function readSectionSource(o, what) {
  if (typeof o.source !== 'string' || !SECTION_SOURCES.includes(o.source)) refuse(`${what}.source`, 'value out of range')
  const out = { source: o.source }
  if (o.source === 'missing') {
    if (typeof o.why !== 'string' || !MISSING_REASONS.includes(o.why)) refuse(`${what}.why`, 'value out of range')
    if (o.at !== undefined) refuse(`${what}.at`, 'a missing section has no time')
    out.why = o.why
    return out
  }
  if (o.why !== undefined) refuse(`${what}.why`, 'only a missing section has a reason')
  if (o.at === undefined) {
    if (o.source === 'cache') refuse(`${what}.at`, 'a cached section needs a time')
  }
  else {
    out.at = intIn(o.at, B.timeMin, B.timeMax, `${what}.at`)
  }
  return out
}

function readSection(raw, what, dataKeys, required, read) {
  const o = strictObject(raw, [...SOURCE_KEYS, ...dataKeys], what)
  const source = readSectionSource(o, what)
  if (source.source === 'missing') {
    for (const k of dataKeys) if (o[k] !== undefined) refuse(`${what}.${k}`, 'a missing section has no data')
    return { source }
  }
  for (const k of required) if (o[k] === undefined) refuse(`${what}.${k}`, 'missing field')
  return { source, data: read(o) }
}

function readPlayer(o) {
  const out = {}
  if (o.money !== undefined) out.money = intIn(o.money, 0, B.money, 'player.money')
  if (o.level !== undefined) out.level = intIn(o.level, 1, B.level, 'player.level')
  if (o.xp !== undefined) out.xp = intIn(o.xp, 0, B.counter, 'player.xp')
  if (o.xpMax !== undefined) out.xpMax = intIn(o.xpMax, 0, B.counter, 'player.xpMax')
  if (o.rested !== undefined) out.rested = intIn(o.rested, 0, B.counter, 'player.rested')
  return out
}

function readQuestLog(o) {
  const quests = checkArray(o.quests, 'questLog.quests', CAPS.questLog).map((raw) => {
    const q = strictObject(raw, ['id', 'done', 'objectives'], 'questLog.quests')
    if (typeof q.done !== 'boolean') refuse('questLog.done', 'must be true or false')
    const objectives = checkArray(q.objectives, 'questLog.objectives', CAPS.objectivesPerQuest).map((rawObjective) => {
      const b = strictObject(rawObjective, ['text', 'have', 'need', 'done'], 'questLog.objectives')
      if (typeof b.done !== 'boolean') refuse('questLog.objectives.done', 'must be true or false')
      return {
        text: textIn(b.text, 0, CAPS.objectiveText, 'questLog.objectives.text'),
        have: intIn(b.have, 0, B.counter, 'questLog.objectives.have'),
        need: intIn(b.need, 0, B.counter, 'questLog.objectives.need'),
        done: b.done,
      }
    })
    return { id: checkItemId(q.id, 'questLog.id'), done: q.done, objectives }
  })
  return { quests: uniqueBy(quests, q => q.id), hidden: intIn(o.hidden, 0, B.hiddenQuests, 'questLog.hidden') }
}

function readFactions(o) {
  const list = checkArray(o.factions, 'reputation.factions', CAPS.factions).map((raw) => {
    const t = tupleOf(raw, 6, 'reputation.factions')
    return {
      id: checkItemId(t[0], 'reputation.id'),
      reaction: intIn(t[1], 0, B.reaction, 'reputation.reaction'),
      standing: intIn(t[2], -B.counter, B.counter, 'reputation.standing'),
      floor: intIn(t[3], -B.counter, B.counter, 'reputation.floor'),
      ceiling: intIn(t[4], -B.counter, B.counter, 'reputation.ceiling'),
      name: textIn(t[5], 1, CAPS.nameText, 'reputation.name'),
    }
  })
  return uniqueBy(list, f => f.id)
}

function readRecipeLines(o) {
  const lines = checkArray(o.lines, 'recipes.lines', CAPS.recipeLines).map((raw) => {
    const l = strictObject(raw, ['line', 'name', 'at', 'recipes'], 'recipes.lines')
    const recipes = checkArray(l.recipes, 'recipes.recipes', CAPS.recipesPerLine).map((rawRecipe) => {
      const t = tupleOf(rawRecipe, 2, 'recipes.recipes')
      const reagents = checkArray(t[1], 'recipes.reagents', CAPS.reagentsPerRecipe).map((rawReagent) => {
        const r = tupleOf(rawReagent, 2, 'recipes.reagents')
        return { itemId: checkItemId(r[0], 'recipes.reagents.itemId'), count: intIn(r[1], 1, B.reagentCount, 'recipes.reagents.count') }
      })
      return { id: checkItemId(t[0], 'recipes.id'), reagents }
    })
    const line = {
      line: checkItemId(l.line, 'recipes.line'),
      at: intIn(l.at, B.timeMin, B.timeMax, 'recipes.at'),
      recipes: uniqueBy(recipes, r => r.id),
    }
    if (l.name !== undefined) line.name = textIn(l.name, 1, CAPS.nameText, 'recipes.name')
    return line
  })
  return uniqueBy(lines, l => l.line)
}

function readTraitNodes(v, section) {
  const nodes = checkArray(v, `${section}.nodes`, CAPS.nodesPerTree).map((raw) => {
    const t = tupleOf(raw, 3, `${section}.nodes`)
    return {
      node: checkItemId(t[0], `${section}.node`),
      rank: intIn(t[1], 1, B.traitRank, `${section}.rank`),
      entry: intIn(t[2], 0, B.id, `${section}.entry`),
    }
  })
  return uniqueBy(nodes, n => n.node)
}

function readTraitTrees(v, section, max, withSpent) {
  const trees = checkArray(v, `${section}.trees`, max).map((raw) => {
    const t = strictObject(raw, withSpent ? ['tree', 'spent', 'nodes'] : ['tree', 'nodes'], `${section}.trees`)
    const tree = { tree: checkItemId(t.tree, `${section}.tree`), nodes: readTraitNodes(t.nodes, section) }
    if (withSpent) tree.spent = intIn(t.spent, 0, B.counter, `${section}.spent`)
    return tree
  })
  return uniqueBy(trees, t => t.tree)
}

function readLegacy(o) {
  const legacy = {
    trees: readTraitTrees(o.trees, 'legacy', CAPS.legacyTrees, true),
    challenges: { source: { source: 'missing', why: 'not_available' } },
  }
  if (o.points !== undefined) {
    const p = strictObject(o.points, ['available', 'cap', 'spent'], 'legacy.points')
    const points = {}
    if (p.available !== undefined) points.available = intIn(p.available, 0, B.counter, 'legacy.points.available')
    if (p.cap !== undefined) points.cap = intIn(p.cap, 0, B.counter, 'legacy.points.cap')
    if (p.spent !== undefined) points.spent = intIn(p.spent, 0, B.counter, 'legacy.points.spent')
    legacy.points = points
  }
  const c = readSection(o.challenges, 'legacy.challenges', ['ids'], ['ids'], x => sortedIds(x.ids, 'legacy.challenges.ids', CAPS.challenges))
  legacy.challenges = c.data === undefined ? { source: c.source } : { source: c.source, ids: c.data }
  return legacy
}

function readHonor(o) {
  const honor = { seasonRank: intIn(o.seasonRank, 0, B.honorRank, 'honor.seasonRank') }
  if (o.seasonMax !== undefined) honor.seasonMax = intIn(o.seasonMax, 0, B.honorRank, 'honor.seasonMax')
  return honor
}

const DATA_FREE_SECTIONS = ['equipped', 'bags', 'bank', 'warbank', 'professions']

function validateSections(raw) {
  const o = strictObject(raw, SECTION_NAMES, 'sections')
  for (const name of SECTION_NAMES) if (o[name] === undefined) refuse(`sections.${name}`, 'missing field')

  const sources = {}
  for (const name of DATA_FREE_SECTIONS) sources[name] = readSection(o[name], name, [], [], () => null).source

  const sections = { sources }
  const take = (name, dataKeys, required, read) => {
    const r = readSection(o[name], name, dataKeys, required, read)
    sources[name] = r.source
    if (r.data !== undefined) sections[name] = r.data
  }
  take('recipes', ['lines'], ['lines'], readRecipeLines)
  take('questsDone', ['ids'], ['ids'], x => sortedIds(x.ids, 'questsDone.ids', CAPS.questsDone))
  take('questLog', ['quests', 'hidden'], ['quests', 'hidden'], readQuestLog)
  take('reputation', ['factions'], ['factions'], readFactions)
  take('player', ['money', 'level', 'xp', 'xpMax', 'rested'], [], readPlayer)
  take('talents', ['trees'], ['trees'], x => readTraitTrees(x.trees, 'talents', CAPS.talentTrees, false))
  take('legacy', ['points', 'trees', 'challenges'], ['trees', 'challenges'], readLegacy)
  take('flightPaths', ['ids'], ['ids'], x => sortedIds(x.ids, 'flightPaths.ids', CAPS.flightPaths))
  take('honor', ['seasonRank', 'seasonMax'], ['seasonRank'], readHonor)
  take('classSpells', ['ids'], ['ids'], x => sortedIds(x.ids, 'classSpells.ids', CAPS.classSpells))
  return sections
}

function validatePayload(d) {
  if (!isObject(d)) refuse('export', 'must be an object')
  if (d.format !== contract.exportFormat.currentFormat) refuse('export.format', 'does not match the prefix')
  onlyKeys(d, TOP_KEYS, 'export')
  if (d.client !== undefined && !isObject(d.client)) refuse('client', 'must be an object')

  if (!isObject(d.identity)) refuse('identity', 'missing field')
  onlyKeys(d.identity, IDENTITY_KEYS, 'identity')
  const identity = validateIdentity(d.identity)

  const equippedList = checkArray(d.equipped, 'equipped', D.maxEquipped).map(equipped)
  const bags = idList(d.bags, 'bags')
  const bank = d.bank === undefined || d.bank === null ? [] : idList(d.bank, 'bank')
  if (typeof d.bankSeen !== 'boolean') refuse('bankSeen', 'must be true or false')
  const warbank = d.warbank === undefined || d.warbank === null ? [] : idList(d.warbank, 'warbank')
  if (d.warbankSeen !== undefined && typeof d.warbankSeen !== 'boolean') refuse('warbankSeen', 'must be true or false')
  if (d.bankSource !== undefined && d.bankSource !== 'tabs' && d.bankSource !== 'classic') refuse('bankSource', 'value out of range')
  if (d.truncated !== undefined && typeof d.truncated !== 'boolean') refuse('truncated', 'must be true or false')

  const professions = checkArray(d.professions, 'professions', D.maxProfessions).map((p) => {
    if (!isObject(p)) refuse('professions', 'must be an object')
    onlyKeys(p, PROFESSION_KEYS, 'professions')
    const entry = { name: boundedString(p.name, B.professionName, 'professions.name') }
    const skillLineId = optionalCount(p.skillLineId, 'professions.skillLineId')
    const rank = optionalCount(p.rank, 'professions.rank')
    const maxRank = optionalCount(p.maxRank, 'professions.maxRank')
    if (skillLineId !== undefined) entry.skillLineId = skillLineId
    if (rank !== undefined) entry.rank = rank
    if (maxRank !== undefined) entry.maxRank = maxRank
    return entry
  })

  const out = {
    format: 3,
    identity,
    equipped: equippedList,
    bags,
    bank,
    bankSeen: d.bankSeen,
    warbank,
    warbankSeen: d.warbankSeen === true,
    truncated: d.truncated === true,
    professions,
  }
  if (typeof d.addonVersion === 'string') out.addonVersion = d.addonVersion
  if (isObject(d.client)) out.client = d.client
  if (d.capturedAt !== undefined && d.capturedAt !== null) out.capturedAt = intIn(d.capturedAt, B.timeMin, B.timeMax, 'capturedAt')
  out.sections = validateSections(d.sections)
  const sources = out.sections.sources
  if ((d.bankSeen === true) !== (sources.bank.source !== 'missing')) refuse('bankSeen', 'does not match the bank section')
  if ((d.warbankSeen === true) !== (sources.warbank.source !== 'missing')) refuse('warbankSeen', 'does not match the warband bank section')
  return out
}

/** Decodes and validates a format 3 export text the way wowchar's server does. Throws AddonExportError. */
export function decodeAddonExport(input) {
  if (typeof input !== 'string') fail('not_a_string', 'Export must be a string')
  if (input.length > MAX_ENCODED_LENGTH + MAX_PASTE_SLACK) fail('too_long', 'Export is too long')
  const text = input.trim()
  if (text.length > MAX_ENCODED_LENGTH) fail('too_long', 'Export is too long')
  if (!text.startsWith(PREFIX)) fail('bad_prefix', `Export must start with ${PREFIX}`)
  let data
  try {
    data = JSON.parse(text.slice(PREFIX.length))
  }
  catch {
    fail('bad_json', 'Export does not contain valid JSON')
  }
  return validatePayload(data)
}

/** The item ids the character has: equipped, bags, and the banks only when they were seen. */
export function obtainedItemIds(payload) {
  const ids = new Set()
  for (const e of payload.equipped) ids.add(e.itemId)
  for (const i of payload.bags) ids.add(i)
  if (payload.bankSeen) for (const i of payload.bank) ids.add(i)
  if (payload.warbankSeen) for (const i of payload.warbank) ids.add(i)
  return ids
}
