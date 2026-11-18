#!/bin/zsh
# README 透明玻璃截图：在屏幕上开真窗口（假数据 + 自画渐变底），按窗口区域截图，再用单窗截图的透明度裁圆角。
# 先编调试版（swift build），再：
#   python3 scripts/readme-shots/make_demo_home.py <假家目录>
#   scripts/readme-shots/shoot.sh <假家目录> <输出.png> <en|zh-Hans> <card|overview|ai> [usage.tab]
# 需要：终端有「录屏」权限；Pillow（PY 环境变量指定解释器，默认 python3）。拍摄时渐变底会盖住整个屏幕约 30 秒。
set -e
HERE=${0:A:h}; ROOT=${HERE:h:h}
HOMEDIR=$1; OUT=$2; LANG_=$3; WHAT=$4; TAB=${5:-overview}
PY=${PY:-python3}
TMP=$(mktemp -d)
swiftc -O $HERE/winid.swift -o $TMP/winid
args=(--live --home $HOMEDIR --backdrop -usage.hidden cursor,opencode,codex -ui.motion NO -ui.language $LANG_
      -usage.tab $TAB -usage.range last24h -usage.sub log -card.bottomTab ai)
if [[ $WHAT == card ]]; then args+=(--open-card-after 16); else args+=(--dash-section $WHAT --open-dashboard-after 16); fi
$ROOT/.build/debug/Lucent $args >/dev/null 2>&1 &
PID=$!
sleep 24
if [[ $WHAT == card ]]; then line=$($TMP/winid $PID | awk '$4>=0 && $2<600 && $3>600' | head -1); W=360
else line=$($TMP/winid $PID | awk '$4>=0 && $2>=1000 && $3<1500' | head -1); W=1200; fi
read id w h l x y a <<< "$line"
if [[ -n $id ]]; then
  screencapture -x -R$x,$y,$w,$h $TMP/region.png
  screencapture -x -o -l $id $TMP/win.png
fi
kill $PID 2>/dev/null; wait $PID 2>/dev/null || true
[[ -n $id ]] && $PY -I $HERE/merge.py $TMP/region.png $TMP/win.png $OUT $W
rm -rf $TMP
