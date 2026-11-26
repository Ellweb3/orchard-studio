#!/bin/sh
# Downloads GeneralUser GS v2 (S. Christian Collins, free for use in software:
# https://github.com/mrbumpy409/GeneralUser-GS/blob/main/documentation/LICENSE.txt)
set -e
cd "$(dirname "$0")/.."
[ -f assets/GeneralUser-GS.sf2 ] && exit 0
curl -fL -o assets/GeneralUser-GS.sf2 https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/GeneralUser-GS.sf2
curl -fsL -o assets/GeneralUser-GS-LICENSE.txt https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/documentation/LICENSE.txt
