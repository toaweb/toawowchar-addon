// The matchers of test/lib/expect.mjs fail when they should. Without this, a matcher that
// always passed would make every other test in the suite pass for nothing.
import { describe, it } from './lib/suite.mjs'
import { expect } from './lib/expect.mjs'

const fails = (fn) => {
  let threw = false
  try { fn() }
  catch (e) { threw = e.name === 'AssertionError' }
  if (!threw) throw new Error('the matcher did not fail')
}

describe('expect (the suite\'s own matchers)', () => {
  it('toBe is Object.is: equal primitives pass, equal-looking objects and NaN-vs-number do not', () => {
    expect(1).toBe(1)
    expect('a').toBe('a')
    expect(Number.NaN).toBe(Number.NaN)
    fails(() => expect(1).toBe(2))
    fails(() => expect({}).toBe({}))
    fails(() => expect(0).toBe(-0))
    expect(1).not.toBe(2)
    fails(() => expect(1).not.toBe(1))
  })

  it('toEqual compares deeply; a key with undefined is the same as no key; arrays must match exactly', () => {
    expect({ a: [1, { b: 2 }], c: 'x' }).toEqual({ c: 'x', a: [1, { b: 2 }] })
    expect({ a: 1, b: undefined }).toEqual({ a: 1 })
    expect([]).toEqual([])
    fails(() => expect({ a: 1 }).toEqual({ a: 2 }))
    fails(() => expect({ a: 1 }).toEqual({ a: 1, b: 2 }))
    fails(() => expect({ a: 1, b: 2 }).toEqual({ a: 1 }))
    fails(() => expect([1, 2]).toEqual([1]))
    fails(() => expect([1]).toEqual([1, 2]))
    fails(() => expect([]).toEqual({}))
    fails(() => expect(null).toEqual({}))
    fails(() => expect('1').toEqual(1))
    expect(new Map()).not.toEqual({})
  })

  it('toEqual with arrayContaining: every wanted item must be there, extra ones are fine', () => {
    expect([1, 2, 3]).toEqual(expect.arrayContaining([3, 1]))
    fails(() => expect([1, 2]).toEqual(expect.arrayContaining([3])))
    fails(() => expect('abc').toEqual(expect.arrayContaining(['a'])))
  })

  it('toMatchObject is a subset check, but arrays keep their length', () => {
    expect({ a: 1, b: { c: 2, d: 3 } }).toMatchObject({ b: { c: 2 } })
    expect([{ a: 1, b: 2 }]).toMatchObject([{ a: 1 }])
    fails(() => expect({ a: 1 }).toMatchObject({ a: 2 }))
    fails(() => expect({ a: 1 }).toMatchObject({ b: undefined, a: 1, c: 1 }))
    fails(() => expect([1, 2]).toMatchObject([1]))
    fails(() => expect(null).toMatchObject({ a: 1 }))
  })

  it('toContain works on strings and arrays; toMatch on strings only', () => {
    expect('abc').toContain('b')
    expect([1, 2]).toContain(2)
    fails(() => expect('abc').toContain('d'))
    fails(() => expect([1, 2]).toContain(3))
    fails(() => expect([[1]]).toContain([1]))
    expect('abc').toMatch(/^a.c$/)
    fails(() => expect('abc').toMatch(/^b/))
    fails(() => expect(5).toMatch(/5/))
    expect('abc').not.toMatch(/z/)
    fails(() => expect('abc').not.toMatch(/b/))
  })

  it('toHaveLength, toHaveProperty, toBeNull, toBeUndefined', () => {
    expect([1, 2]).toHaveLength(2)
    expect('ab').toHaveLength(2)
    fails(() => expect([1]).toHaveLength(2))
    fails(() => expect(undefined).toHaveLength(0))
    expect({ a: undefined }).toHaveProperty('a')
    fails(() => expect({}).toHaveProperty('a'))
    fails(() => expect(null).toHaveProperty('a'))
    expect({}).not.toHaveProperty('a')
    expect(null).toBeNull()
    fails(() => expect(undefined).toBeNull())
    expect(undefined).toBeUndefined()
    fails(() => expect(null).toBeUndefined())
  })

  it('the number comparisons are strict about the number, and refuse anything that is not one', () => {
    expect(2).toBeGreaterThan(1)
    expect(1).toBeGreaterThanOrEqual(1)
    expect(1).toBeLessThan(2)
    expect(1).toBeLessThanOrEqual(1)
    fails(() => expect(1).toBeGreaterThan(1))
    fails(() => expect(0).toBeGreaterThanOrEqual(1))
    fails(() => expect(1).toBeLessThan(1))
    fails(() => expect(2).toBeLessThanOrEqual(1))
    fails(() => expect('2').toBeGreaterThan(1))
    fails(() => expect(undefined).toBeLessThanOrEqual(1))
  })

  it('a failure message carries the label', () => {
    let message = ''
    try { expect(1, 'the label').toBe(2) }
    catch (e) { message = e.message }
    expect(message).toContain('the label')
  })
})
