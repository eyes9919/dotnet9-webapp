#!/usr/bin/env bash
# destroy_aws.sh : Copilotアプリ/環境/サービスを完全削除（非対話・安全再実行）
set -euo pipefail

APP_NAME="webapp"
ENV_NAME="test"
AWS_REGION="ap-northeast-1"
AWS_PROFILE="default"     # 必要に応じて変更
export AWS_DEFAULT_REGION="${AWS_REGION}"

say(){ printf "===> %s\n" "$*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found"; exit 1; }; }

need aws
need copilot

# 1) サービス削除（存在する場合のみ）
say "Deleting Copilot service(s) in app=${APP_NAME}, env=${ENV_NAME}"
if copilot app ls 2>/dev/null | awk '{print $1}' | grep -qx "${APP_NAME}"; then
  # 既存サービス一覧を取得
  SVC_LIST=$(copilot svc ls --app "${APP_NAME}" 2>/dev/null | awk 'NR>1{print $1}' || true)
  if [ -n "${SVC_LIST}" ]; then
    for SVC in ${SVC_LIST}; do
      echo " -> Deleting service: ${SVC} (env: ${ENV_NAME})"
      # env 指定でサービス削除（非対話）
      copilot svc delete --name "${SVC}" --env "${ENV_NAME}" --app "${APP_NAME}" --yes || true
    done
  else
    echo " -> No services found in app ${APP_NAME}"
  fi
else
  echo " -> App ${APP_NAME} not found. Skipping svc deletion."
fi

# 2) 環境削除（存在する場合のみ）
say "Deleting environment: ${ENV_NAME}"
if copilot app ls 2>/dev/null | awk '{print $1}' | grep -qx "${APP_NAME}"; then
  if copilot env ls --app "${APP_NAME}" 2>/dev/null | awk '{print $1}' | grep -qx "${ENV_NAME}"; then
    copilot env delete --name "${ENV_NAME}" --app "${APP_NAME}" --yes || true
  else
    echo " -> Env ${ENV_NAME} not found in app ${APP_NAME}. Skipping."
  fi
else
  echo " -> App ${APP_NAME} not found. Skipping env deletion."
fi

# 3) アプリ削除（存在する場合のみ）
say "Deleting Copilot app: ${APP_NAME}"
if copilot app ls 2>/dev/null | awk '{print $1}' | grep -qx "${APP_NAME}"; then
  copilot app delete --yes || true
else
  echo " -> No apps found or ${APP_NAME} already removed."
fi

# 4) 残骸SSMパラメータ掃除（任意）
say "Cleaning up leftover SSM parameters (optional)"
# /copilot/<app>/<env>/ 以下を再帰削除
PREFIX="/copilot/${APP_NAME}/${ENV_NAME}/"
# ツリーが存在する場合のみ削除
PARAMS=$(aws ssm get-parameters-by-path \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --path "${PREFIX}" \
  --recursive \
  --with-decryption \
  --query 'Parameters[].Name' \
  --output text 2>/dev/null || true)

if [ -n "${PARAMS}" ]; then
  # 10件ずつ削除
  echo "${PARAMS}" | tr '\t' '\n' | awk 'NF' | split -l 10 - /tmp/ssm_params_chunk_ || true
  for f in /tmp/ssm_params_chunk_*; do
    [ -f "$f" ] || continue
    NAMES=$(tr '\n' ' ' < "$f")
    aws ssm delete-parameters \
      --profile "${AWS_PROFILE}" \
      --region "${AWS_REGION}" \
      --names ${NAMES} >/dev/null || true
    rm -f "$f"
  done
  echo " -> Deleted SSM params under ${PREFIX}"
else
  echo " -> No SSM params under ${PREFIX}"
fi

say "Done: AWS resources for ${APP_NAME} have been removed."
