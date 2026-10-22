// describe / it / it.each / beforeAll on top of node:test (the names of the vitest
// calls the tests were ported from), so the files read the same. A suite with a
// missing tool fails; nothing here skips.
import { before, describe, it as nodeIt } from 'node:test'
import { format } from 'node:util'

export { describe }
export const beforeAll = before

export function it(name, fn) {
  return nodeIt(name, fn)
}

/** `it.each(rows)(name, fn)`: one test for each row; `%s` and `%d` in the name are the row's values. */
it.each = rows => (name, fn) => {
  for (const row of rows) {
    const args = Array.isArray(row) ? row : [row]
    // Only as many values go into the name as it has placeholders (util.format would append the rest).
    const used = (name.match(/%[sdifjoO]/g) ?? []).length
    nodeIt(format(name, ...args.slice(0, used)), () => fn(...args))
  }
}
