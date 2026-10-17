import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

// The addon's Lua, checked with Lua 5.1 in Docker (the WoW client's Lua). Opt-in
// by presence: skipped when Docker or the image nickblah/lua:5.1-alpine is not
// there, so `npm test` stays offline. `docker pull nickblah/lua:5.1-alpine` once
// to enable it. The stub script (test/lua/region-stub.lua) fakes the WoW API.
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

const identityOf = (scenario: string) => {
  const r = lua(['lua', 'app/test/lua/region-stub.lua', scenario])
  expect(r.stderr).toBe('')
  expect(r.status).toBe(0)
  return Object.fromEntries(r.stdout.trim().split('\n').map(l => l.split('=') as [string, string]))
}

describe.skipIf(!haveImage)('WowcharExport.lua (Lua 5.1)', () => {
  it('compiles (luac -p)', () => {
    const r = lua(['luac', '-p', 'addon/WowcharExport/WowcharExport.lua'])
    expect(r.stderr).toBe('')
    expect(r.status).toBe(0)
  })

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
    // Every scenario above defines GetCurrentRegionName as a function that errors.
    expect(identityOf('eu').region).toBe('EU')
  })
})
