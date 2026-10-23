# The image the tests run in: Node (the test runner, node:test, no packages), Lua 5.1 (the
# WoW client's Lua), Python 3 (the release scripts) and git (the tests of the pull-request version
# gate make small repositories). Built from this file alone, no
# context: `docker build - < test/Dockerfile` (scripts/test.sh does it).
#
# The base image is pinned by digest; `docker pull node:24-alpine` and take the new digest
# to move it. tzdata is there so the zip test can really run in other time zones.
FROM node:25-alpine@sha256:bdf2cca6fe3dabd014ea60163eca3f0f7015fbd5c7ee1b0e9ccb4ced6eb02ef4

RUN apk add --no-cache git lua5.1 python3 tzdata \
 && ln -sf /usr/bin/lua5.1 /usr/local/bin/lua \
 && ln -sf /usr/bin/luac5.1 /usr/local/bin/luac

WORKDIR /w
