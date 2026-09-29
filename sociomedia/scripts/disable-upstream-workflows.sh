#!/usr/bin/env bash
#
# フォークで有効になっている本家由来の GitHub Actions ワークフローを無効化する。
# 本家のワークフローは本家専用のランナー・Secrets を前提としており、フォークでは
# 失敗するか、ランナー待ちのまま残るため。
#
# ワークフローは初めてイベントで起動したときに登録されるため、PR などで新しく
# 本家由来のワークフローが走ったら、このスクリプトを再実行する。
#
#   ./sociomedia/scripts/disable-upstream-workflows.sh

set -euo pipefail

REPO="${REPO:-kazuki-tsuchiya-sociomedia/penpot}"

gh workflow list -R "$REPO" --all --limit 200 --json id,path,state \
    --jq '.[] | select(.state == "active") | select(.path | test("/sociomedia-") | not) | "\(.id) \(.path)"' \
| while read -r id path; do
    echo "disable: $path"
    gh workflow disable -R "$REPO" "$id"
done
