#!/usr/bin/env bash
# rebuild_aws.sh : Copilotアプリ/環境/サービスを完全再構築（非対話・タグ付SSM対応）
set -euo pipefail

########################################
# 設定
########################################
APP_NAME="webapp"
ENV_NAME="test"
AWS_REGION="ap-northeast-1"

SVC_NAME="webapp"
DOCKERFILE="./src/WebApp/Dockerfile"
SVC_PORT="8080"

ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin123!}"   # 環境変数があれば優先。無ければ既定。
ADMIN_SECRET_SSM="/copilot/${APP_NAME}/${ENV_NAME}/secrets/ADMIN_PASSWORD"

MANIFEST_ENV="copilot/environments/${ENV_NAME}/manifest.yml"
MANIFEST_SVC="copilot/${SVC_NAME}/manifest.yml"

########################################
# 共通
########################################
log() { printf "\n===> %s\n\n" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

trap 'die "途中で失敗しました（直前のステップのログを確認）"' ERR

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v copilot >/dev/null 2>&1 || die "copilot not found"

aws sts get-caller-identity --region "$AWS_REGION" >/dev/null || die "AWS資格情報/リージョン確認エラー"

########################################
# 1) アプリ
########################################
log "Ensure Copilot App: ${APP_NAME}"
if ! copilot app ls 2>/dev/null | awk '{print $1}' | grep -qx "${APP_NAME}"; then
  copilot app init "${APP_NAME}"
else
  echo "    App exists: ${APP_NAME}"
fi

########################################
# 2) 環境（完全非対話）
########################################
log "Ensure Environment: ${ENV_NAME}"

# 事前にenv manifestを作っておく（存在すればスキップ）
if [ ! -f "$MANIFEST_ENV" ]; then
  mkdir -p "copilot/environments/${ENV_NAME}"
  cat > "$MANIFEST_ENV" <<'YAML'
# Generated default env manifest (safe defaults)
name: PLACEHOLDER
type: Environment
network:
  vpc:
    cidr: 10.0.0.0/16
    subnets:
      public:
        - 10.0.1.0/24
        - 10.0.2.0/24
      private:
        - 10.0.3.0/24
        - 10.0.4.0/24
observability:
  container_insights: true
YAML
fi

env_exists() { copilot env ls 2>/dev/null | awk '{print $1}' | grep -qx "${ENV_NAME}"; }

if ! env_exists; then
  echo "    Creating new environment (non-interactive flags)"
  # NOTE: --profile は default を想定。別名プロファイルを使う場合は書き換えてください。
  copilot env init \
    --name "${ENV_NAME}" \
    --app "${APP_NAME}" \
    --default-config \
    --profile default
else
  echo "    Environment exists: ${ENV_NAME}"
fi

# env deploy（--region は付けない／変更無しは許容）
log "Deploy Environment: ${ENV_NAME}"
set +e
copilot env deploy --name "${ENV_NAME}"
rc=$?
if [ $rc -ne 0 ]; then
  echo "    Note: env deploy had no immediate changes or failed softly. Trying --force..."
  copilot env deploy --name "${ENV_NAME}" --force || true
fi
set -e

########################################
# 3) SSM: シークレット投入＋Copilotタグ付与（これが無いとGetParameters拒否）
########################################
log "Put & tag ADMIN_PASSWORD in SSM Parameter Store"
aws ssm put-parameter \
  --region "${AWS_REGION}" \
  --name "${ADMIN_SECRET_SSM}" \
  --value "${ADMIN_PASSWORD}" \
  --type SecureString \
  --overwrite >/dev/null

aws ssm add-tags-to-resource \
  --region "${AWS_REGION}" \
  --resource-type Parameter \
  --resource-id "${ADMIN_SECRET_SSM}" \
  --tags Key=copilot-application,Value="${APP_NAME}" Key=copilot-environment,Value="${ENV_NAME}" >/dev/null

echo "    SSM ready: ${ADMIN_SECRET_SSM}"

########################################
# 4) サービス
########################################
log "Ensure service: ${SVC_NAME}"
if ! copilot svc ls 2>/dev/null | awk '{print $1}' | grep -qx "${SVC_NAME}"; then
  copilot svc init \
    --name "${SVC_NAME}" \
    --svc-type "Load Balanced Web Service" \
    --dockerfile "${DOCKERFILE}" \
    --port "${SVC_PORT}"
else
  echo "    Service exists: ${SVC_NAME}"
fi

########################################
# 5) manifest の secrets 設定（動的パス推奨）
########################################
log "Ensure manifest secrets mapping"
[ -f "${MANIFEST_SVC}" ] || die "Service manifest not found: ${MANIFEST_SVC}"

if ! grep -q '^secrets:' "${MANIFEST_SVC}"; then
  cat >> "${MANIFEST_SVC}" <<'YAML'

secrets:
  ADMIN_PASSWORD: /copilot/${COPILOT_APPLICATION_NAME}/${COPILOT_ENVIRONMENT_NAME}/secrets/ADMIN_PASSWORD
YAML
  echo "    Added secrets block to ${MANIFEST_SVC}"
else
  if ! grep -q 'ADMIN_PASSWORD:' "${MANIFEST_SVC}"; then
    awk '
      {print}
      /^secrets:/ && !p { print "  ADMIN_PASSWORD: /copilot/${COPILOT_APPLICATION_NAME}/${COPILOT_ENVIRONMENT_NAME}/secrets/ADMIN_PASSWORD"; p=1 }
    ' "${MANIFEST_SVC}" > "${MANIFEST_SVC}.tmp" && mv "${MANIFEST_SVC}.tmp" "${MANIFEST_SVC}"
    echo "    Ensured ADMIN_PASSWORD mapping in ${MANIFEST_SVC}"
  else
    echo "    Secrets already configured"
  fi
fi

########################################
# 6) サービスデプロイ（強制）
########################################
log "Deploy service (force)"
copilot svc deploy --app "${APP_NAME}" --name "${SVC_NAME}" --env "${ENV_NAME}" --force

########################################
# 7) 仕上げ案内
########################################
log "Done."
echo "Check status : copilot svc status -n ${SVC_NAME} -e ${ENV_NAME}"
echo "Show URL     : copilot svc show   -n ${SVC_NAME}"
