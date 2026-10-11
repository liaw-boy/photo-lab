#!/bin/sh
# Builds the optimised (release) app and starts it. A debug build is ~50x slower at pixel work: the live preview
# takes seconds instead of a tenth of a second.
cd "$(dirname "$0")" || exit 1
swift build -c release || exit 1
exec .build/release/PhotoLab "$@"
