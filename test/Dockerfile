# The image the tests run in: Node (the test runner, node:test, no packages), Lua 5.1 (the
# WoW client's Lua), Python 3 (the release scripts) and git (the tests of the pull-request version
# gate make small repositories). Built from this file alone, no
# context: `docker build - < test/Dockerfile` (scripts/test.sh does it).
#
# The base image is pinned by digest; `docker pull node:24-alpine` and take the new digest
# to move it. tzdata is there so the zip test can really run in other time zones.
FROM node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53

RUN apk add --no-cache git lua5.1 python3 tzdata \
 && ln -sf /usr/bin/lua5.1 /usr/local/bin/lua \
 && ln -sf /usr/bin/luac5.1 /usr/local/bin/luac

WORKDIR /w
