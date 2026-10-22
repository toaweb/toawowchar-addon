// A small `expect` for the test suite: the handful of matchers the tests use, with
// the semantics of the vitest ones they replace (toEqual ignores keys whose value is
// undefined; toMatchObject is a recursive subset check). No dependencies: the
// suite runs on node:test alone. test/expect.test.mjs checks that every matcher
// fails when it should.
import { AssertionError } from 'node:assert'
import { inspect } from 'node:util'

const show = v => inspect(v, { depth: 6, breakLength: 100, maxArrayLength: 40, maxStringLength: 300 })

class ArrayContaining {
  constructor(items) { this.items = items }
  matches(actual) {
    return Array.isArray(actual) && this.items.every(item => actual.some(a => equals(a, item)))
  }
}

const isObject = v => typeof v === 'object' && v !== null

/** Recursive equality like vitest's toEqual: undefined-valued keys are ignored, arrays must match exactly. */
export function equals(a, b) {
  if (b instanceof ArrayContaining) return b.matches(a)
  if (Object.is(a, b)) return true
  if (!isObject(a) || !isObject(b)) return false
  if (Array.isArray(a) !== Array.isArray(b)) return false
  if (Array.isArray(a)) return a.length === b.length && a.every((x, i) => equals(x, b[i]))
  if (Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false
  const keys = o => Object.keys(o).filter(k => o[k] !== undefined)
  const ka = keys(a)
  const kb = keys(b)
  return ka.length === kb.length && ka.every(k => Object.hasOwn(b, k) && equals(a[k], b[k]))
}

/** Recursive subset check like toMatchObject: every key of `want` must match; arrays must have the same length. */
export function matchesObject(actual, want) {
  if (want instanceof ArrayContaining) return want.matches(actual)
  if (Object.is(actual, want)) return true
  if (!isObject(actual) || !isObject(want)) return false
  if (Array.isArray(want)) {
    return Array.isArray(actual) && actual.length === want.length && want.every((w, i) => matchesObject(actual[i], w))
  }
  return Object.keys(want).every(k => matchesObject(actual[k], want[k]))
}

function matchers(actual, label, negate) {
  const check = (pass, what, expected) => {
    if (pass === negate) {
      const msg = `${label ? `${label}: ` : ''}expected ${show(actual)} ${negate ? 'not ' : ''}${what}${expected === undefined ? '' : ` ${show(expected)}`}`
      throw new AssertionError({ message: msg })
    }
  }
  const number = (v, what) => {
    if (typeof actual !== 'number' || typeof v !== 'number') check(false, `${what} (both must be numbers)`, v)
  }
  return {
    toBe: v => check(Object.is(actual, v), 'to be', v),
    toEqual: v => check(equals(actual, v), 'to equal', v),
    toMatchObject: v => check(matchesObject(actual, v), 'to match the object', v),
    toContain: (v) => {
      const ok = typeof actual === 'string' ? actual.includes(v) : Array.isArray(actual) && actual.includes(v)
      check(ok, 'to contain', v)
    },
    toMatch: v => check(typeof actual === 'string' && v.test(actual), 'to match', v),
    toHaveLength: v => check(actual != null && actual.length === v, 'to have length', v),
    toHaveProperty: v => check(isObject(actual) && Object.hasOwn(actual, v), 'to have the property', v),
    toBeNull: () => check(actual === null, 'to be null'),
    toBeUndefined: () => check(actual === undefined, 'to be undefined'),
    toBeGreaterThan: v => { number(v, 'to be greater than'); check(actual > v, 'to be greater than', v) },
    toBeGreaterThanOrEqual: v => { number(v, 'to be greater than or equal to'); check(actual >= v, 'to be greater than or equal to', v) },
    toBeLessThan: v => { number(v, 'to be less than'); check(actual < v, 'to be less than', v) },
    toBeLessThanOrEqual: v => { number(v, 'to be less than or equal to'); check(actual <= v, 'to be less than or equal to', v) },
  }
}

/** `expect(value, label)`; `label` is shown in the failure message. */
export function expect(actual, label) {
  return { ...matchers(actual, label, false), not: matchers(actual, label, true) }
}
expect.arrayContaining = items => new ArrayContaining(items)
