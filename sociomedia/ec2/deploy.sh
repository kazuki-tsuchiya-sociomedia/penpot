#!/usr/bin/env bash
#
# /home/ubuntu/penpot/deploy.sh として配置する (chmod +x)。
# GitHub Actions から SSM ドキュメント penpot-deploy 経由で `sudo -iu ubuntu deploy.sh <tag>` として実行される。
# 手動でのデプロイ・ロールバックも同じコマンドで行える。
#
#   ./deploy.sh 2.18.0-3-gabc1234
#
# 処理: イメージ pull → DB バックアップ → .env のタグ更新 → up -d → ヘルスチェック。
# ヘルスチェックに失敗した場合は直前のタグ (初回は公式イメージ) に戻す。

set -euo pipefail

TAG="${1:?usage: deploy.sh <image-tag>}"
if [[ ! "$TAG" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "invalid tag: $TAG" >&2
    exit 1
fi

cd "$(dirname "$(readlink -f "$0")")"

REGISTRY="045084157533.dkr.ecr.ap-northeast-1.amazonaws.com/penpot"
SERVICES=(penpot-frontend penpot-backend penpot-exporter penpot-mcp)
PENPOT_HOST="${PENPOT_HOST:-penpot.sociomedia.com}"
BACKUP_DIR=./backups
KEEP_BACKUPS=10
OVERRIDE=docker-compose.override.yml
OVERRIDE_TEMPLATE=ecr-override.yml

exec > >(tee -a deploy.log) 2>&1
echo "=== $(date -Is) deploy $TAG"

if [[ ! -f "$OVERRIDE_TEMPLATE" ]]; then
    echo "$OVERRIDE_TEMPLATE not found" >&2
    exit 1
fi

PREV="$(sed -n 's/^PENPOT_CUSTOM_VERSION=//p' .env | tail -n1)"
echo ">> current: ${PREV:-<official images>} -> new: $TAG"

set-version() {
    if grep -q '^PENPOT_CUSTOM_VERSION=' .env; then
        sed -i "s/^PENPOT_CUSTOM_VERSION=.*/PENPOT_CUSTOM_VERSION=$1/" .env
    else
        printf '\nPENPOT_CUSTOM_VERSION=%s\n' "$1" >> .env
    fi
}

running-tag-ok() {
    local svc cid image running
    for svc in "${SERVICES[@]}"; do
        cid="$(docker compose ps -q "$svc")"
        [[ -n "$cid" ]] || return 1
        image="$(docker inspect -f '{{.Config.Image}}' "$cid")"
        running="$(docker inspect -f '{{.State.Running}}' "$cid")"
        [[ "$image" == "$REGISTRY/${svc#penpot-}:$TAG" && "$running" == "true" ]] || return 1
    done
}

healthy() {
    running-tag-ok &&
        curl -fsS --max-time 5 --resolve "$PENPOT_HOST:443:127.0.0.1" \
             "https://$PENPOT_HOST/readyz" > /dev/null
}

rollback() {
    echo "!! health check failed, rolling back to ${PREV:-<official images>}"
    if [[ -n "$PREV" ]]; then
        export PENPOT_CUSTOM_VERSION="$PREV"
        set-version "$PREV"
    else
        unset PENPOT_CUSTOM_VERSION
        sed -i '/^PENPOT_CUSTOM_VERSION=/d' .env
        rm -f "$OVERRIDE"
        echo "!! $OVERRIDE removed (back to official images)"
    fi
    docker compose up -d
    exit 1
}

# 以降の compose 呼び出しは新しいタグで設定を解決する。
# 初回は切替前に失敗したら override を消し、公式イメージの構成に戻しておく。
export PENPOT_CUSTOM_VERSION="$TAG"
cp "$OVERRIDE_TEMPLATE" "$OVERRIDE"
trap '[[ -n "$PREV" ]] || rm -f "$OVERRIDE"' ERR

echo ">> pulling images"
docker compose pull "${SERVICES[@]}"

echo ">> backing up database"
mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/penpot-$(date +%Y%m%d-%H%M%S)-${PREV:-official}.dump"
docker compose exec -T penpot-postgres pg_dump -U penpot -Fc penpot > "$BACKUP"
echo "   $BACKUP ($(du -h "$BACKUP" | cut -f1))"
ls -1t "$BACKUP_DIR"/penpot-*.dump | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f

trap - ERR

echo ">> starting $TAG"
set-version "$TAG"
docker compose up -d

echo ">> waiting for health check"
for _ in $(seq 1 60); do
    if healthy; then
        echo ">> $TAG is up"
        break
    fi
    sleep 5
done
healthy || rollback

echo ">> removing old images"
docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep "^$REGISTRY/" \
    | grep -vE ":($TAG${PREV:+|$PREV})\$" \
    | xargs -r docker rmi || true
docker image prune -f > /dev/null

echo "=== $(date -Is) deploy $TAG done"
