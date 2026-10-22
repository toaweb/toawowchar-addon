#!/bin/sh
# Runs every test of this repository in Docker: the Lua tests (Lua 5.1), the checks of the
# export against the contract, the version check and the zip build. Nothing but Docker is
# needed on the machine.
#
#   scripts/test.sh                      everything
#   scripts/test.sh test/release.test.mjs   one file (arguments go to `node --test`)
#   UPDATE_FIXTURES=1 scripts/test.sh    write test/fixtures/*.txt again after a deliberate
#                                        change to what the addon exports (then read the diff)
#
# Writes dist/examples/export-format-3.txt (the example export of the release).
set -eu
cd "$(dirname "$0")/.."

image=toawowchar-addon-test
docker build --quiet --tag "$image" - < test/Dockerfile > /dev/null

if [ "$#" -eq 0 ]; then
  set -- test/*.test.mjs
fi

mkdir -p dist
exec docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --env UPDATE_FIXTURES="${UPDATE_FIXTURES:-}" \
  --volume "$PWD":/w \
  "$image" \
  node --test --test-reporter=spec "$@"
