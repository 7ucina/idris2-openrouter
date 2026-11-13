#!/bin/sh
# Run the tests.
#
#   test/run.sh          the pure tests, then the client against test/mock.py
#   test/run.sh --live   also OpenRouter's public endpoints (and, when
#                        OPENROUTER_API_KEY is set, two small paid requests)
set -e
cd "$(dirname "$0")/.."
PORT="${OPENROUTER_MOCK_PORT:-8787}"

pack --no-prompt build test/test.ipkg

python3 test/mock.py "$PORT" >/dev/null 2>&1 &
MOCK=$!
trap 'kill $MOCK 2>/dev/null' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/_seen" && break
  sleep 0.2
done

[ "$1" = "--live" ] && export OPENROUTER_LIVE=1
OPENROUTER_MOCK_URL="http://127.0.0.1:$PORT/api/v1" test/build/exec/openrouter-test
