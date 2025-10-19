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
need jq

# Helper: wait for a StackSet operation to finish and return its final status
wait_stackset_op () {
  local ss_name="$1"
  local op_id="$2"
  local status=""
  # Normalize op_id in case it has stray CR/LF
  op_id="$(printf "%s" "$op_id" | tr -d '\r\n')"
  for i in $(seq 1 60); do
    status="$(aws cloudformation describe-stack-set-operation \
      --stack-set-name "$ss_name" \
      --operation-id "$op_id" \
      --query 'StackSetOperation.Status' --output text 2>/dev/null || echo 'UNKNOWN')"
    case "$status" in
      SUCCEEDED|FAILED|STOPPED) echo "$status"; return 0 ;;
      *) sleep 5 ;;
    esac
  done
  echo "$status"
}

# Helper: robust StackSet cleanup for app-level "infrastructure" StackSet
cleanup_app_stackset () {
  local app="$1"
  local region="$2"
  local ss_name="${app}-infrastructure"

  # If StackSet doesn't exist, nothing to do.
  if ! aws cloudformation describe-stack-set --stack-set-name "$ss_name" >/dev/null 2>&1; then
    return 0
  fi

  # If there are stack instances, try to delete them (no-retain first, then retain as fallback).
  local instances
  instances="$(aws cloudformation list-stack-instances --stack-set-name "$ss_name" \
              --query 'Summaries[].{Acc:Account,Reg:Region}' --output text 2>/dev/null || true)"

  if [ -n "$instances" ]; then
    # de-duplicate account/region pairs
    local accs regs
    accs="$(echo "$instances" | awk '{print $1}' | sort -u | tr '\n' ' ')"
    regs="$(echo "$instances" | awk '{print $2}' | sort -u | tr '\n' ' ')"

    echo " -> Deleting StackSet instances for ${ss_name} (no-retain)"
    local opid
    opid="$(aws cloudformation delete-stack-instances \
      --stack-set-name "$ss_name" \
      --accounts $accs \
      --regions $regs \
      --no-retain-stacks \
      --operation-preferences RegionConcurrencyType=PARALLEL,MaxConcurrentCount=10 \
      --query 'OperationId' --output text 2>/dev/null || echo "")"

    if [ -n "$opid" ] && [ "$opid" != "None" ]; then
      local st; st="$(wait_stackset_op "$ss_name" "$opid")"
      if [ "$st" != "SUCCEEDED" ]; then
        echo "    WARN: no-retain DELETE failed (status=${st}). Retrying with retain-stacks..."
        opid="$(aws cloudformation delete-stack-instances \
          --stack-set-name "$ss_name" \
          --accounts $accs \
          --regions $regs \
          --retain-stacks \
          --operation-preferences RegionConcurrencyType=PARALLEL,MaxConcurrentCount=10 \
          --query 'OperationId' --output text 2>/dev/null || echo "")"
        [ -n "$opid" ] && [ "$opid" != "None" ] && wait_stackset_op "$ss_name" "$opid" >/dev/null 2>&1 || true
      fi
    else
      # Could not kick operation (INOPERABLE, etc). Try retain as a best-effort.
      opid="$(aws cloudformation delete-stack-instances \
        --stack-set-name "$ss_name" \
        --accounts $accs \
        --regions $regs \
        --retain-stacks \
        --operation-preferences RegionConcurrencyType=PARALLEL,MaxConcurrentCount=10 \
        --query 'OperationId' --output text 2>/dev/null || echo "")"
      [ -n "$opid" ] && [ "$opid" != "None" ] && wait_stackset_op "$ss_name" "$opid" >/dev/null 2>&1 || true
    fi
  fi

  # Now delete the StackSet itself if it still exists and has zero instances
  local left
  left="$(aws cloudformation list-stack-instances --stack-set-name "$ss_name" \
          --query 'length(Summaries)' --output text 2>/dev/null || echo "0")"
  if [ "$left" = "0" ]; then
    echo " -> Deleting StackSet: ${ss_name}"
    aws cloudformation delete-stack-set --stack-set-name "$ss_name" >/dev/null 2>&1 || true
  else
    echo "    WARN: ${ss_name} still has instances; manual check may be required."
  fi
}

# 0) CloudFront distribution cleanup (created by rebuild script)
say "Deleting CloudFront distributions for app=${APP_NAME}, env=${ENV_NAME}"
CF_IDS=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${APP_NAME}-${ENV_NAME}'].Id" \
  --output text 2>/dev/null || true)
if [ -n "${CF_IDS}" ] && [ "${CF_IDS}" != "None" ]; then
  for CFID in ${CF_IDS}; do
    echo " -> Disabling distribution: ${CFID}"
    # Fetch current config and ETag
    aws cloudfront get-distribution-config --id "${CFID}" --query 'DistributionConfig' --output json >/tmp/cfconfig.json
    ETAG=$(aws cloudfront get-distribution-config --id "${CFID}" --query 'ETag' --output text)
    # Set Enabled=false
    jq '.Enabled=false' /tmp/cfconfig.json >/tmp/cfconfig.disabled.json
    aws cloudfront update-distribution \
      --id "${CFID}" \
      --if-match "${ETAG}" \
      --distribution-config file:///tmp/cfconfig.disabled.json >/dev/null || true
    # Wait until the distribution is deployed (update applied)
    aws cloudfront wait distribution-deployed --id "${CFID}" || true
    # Get fresh ETag and delete
    ETAG2=$(aws cloudfront get-distribution-config --id "${CFID}" --query 'ETag' --output text)
    echo " -> Deleting distribution: ${CFID}"
    aws cloudfront delete-distribution --id "${CFID}" --if-match "${ETAG2}" >/dev/null || true
    rm -f /tmp/cfconfig.json /tmp/cfconfig.disabled.json
  done
else
  echo " -> No CloudFront distributions found for this app/env."
fi

# 0.5) CloudFormation app-level roles stack cleanup (leftover can block re-init)
say "Deleting leftover CloudFormation 'roles' stack if present"
CFN_ROLES_STACK="${APP_NAME}-infrastructure-roles"
if aws cloudformation describe-stacks --region "${AWS_REGION}" --stack-name "${CFN_ROLES_STACK}" >/dev/null 2>&1; then
  echo " -> Found stack: ${CFN_ROLES_STACK} in ${AWS_REGION}, deleting..."
  # Ensure termination protection is off (ignore failures)
  aws cloudformation update-termination-protection \
    --region "${AWS_REGION}" \
    --stack-name "${CFN_ROLES_STACK}" \
    --no-enable-termination-protection >/dev/null 2>&1 || true
  aws cloudformation delete-stack --region "${AWS_REGION}" --stack-name "${CFN_ROLES_STACK}" || true
  echo " -> Waiting for deletion to complete..."
  aws cloudformation wait stack-delete-complete --region "${AWS_REGION}" --stack-name "${CFN_ROLES_STACK}" || true
  echo " -> Deleted: ${CFN_ROLES_STACK}"
else
  echo " -> No '${CFN_ROLES_STACK}' stack found."
fi

# 1) サービス削除（存在する場合のみ）
say "Deleting Copilot service(s) in app=${APP_NAME}, env=${ENV_NAME}"
if copilot app ls 2>/dev/null | awk '{print $1}' | grep -qx "${APP_NAME}"; then
  # 既存サービス一覧を取得（JSONで厳密に）
  SVC_LIST=$(copilot svc ls --app "${APP_NAME}" --json 2>/dev/null | jq -r '.[].name' || true)
  if [ -n "${SVC_LIST}" ]; then
    for SVC in ${SVC_LIST}; do
      [ -n "${SVC}" ] || continue
      echo " -> Deleting service: ${SVC} (env: ${ENV_NAME})"
      copilot svc delete --name "${SVC}" --env "${ENV_NAME}" --app "${APP_NAME}" --yes || true
    done
  else
    echo " -> No services found in app ${APP_NAME}"
  fi
else
  echo " -> App ${APP_NAME} not found. Skipping svc deletion."
fi

# Pre-clean app-level StackSet to avoid INOPERABLE/NotFound issues during env/app delete
cleanup_app_stackset "${APP_NAME}" "${AWS_REGION}"

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
  copilot app delete --name "${APP_NAME}" --yes || true
else
  echo " -> No apps found or ${APP_NAME} already removed."
fi

# Final attempt: ensure app-level StackSet is gone
cleanup_app_stackset "${APP_NAME}" "${AWS_REGION}"

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

# Also remove app-level metadata parameters if any
APP_PREFIX="/copilot/applications/${APP_NAME}"
APP_PARAMS=$(aws ssm get-parameters-by-path \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --path "${APP_PREFIX}" \
  --recursive \
  --with-decryption \
  --query 'Parameters[].Name' \
  --output text 2>/dev/null || true)
if [ -n "${APP_PARAMS}" ]; then
  echo "${APP_PARAMS}" | tr '\t' '\n' | awk 'NF' | split -l 10 - /tmp/ssm_params2_chunk_ || true
  for f in /tmp/ssm_params2_chunk_*; do
    [ -f "$f" ] || continue
    NAMES=$(tr '\n' ' ' < "$f")
    aws ssm delete-parameters \
      --profile "${AWS_PROFILE}" \
      --region "${AWS_REGION}" \
      --names ${NAMES} >/dev/null || true
    rm -f "$f"
  done
  echo " -> Deleted SSM params under ${APP_PREFIX}"
else
  echo " -> No SSM params under ${APP_PREFIX}"
fi

say "Cleaning up unused self-signed ACM certificates (always on)"
CERT_ARNS=$(aws acm list-certificates --region "${AWS_REGION}" --query 'CertificateSummaryList[].CertificateArn' --output text 2>/dev/null || true)
if [ -n "${CERT_ARNS}" ]; then
  for ARN in ${CERT_ARNS}; do
    DESC=$(aws acm describe-certificate --region "${AWS_REGION}" --certificate-arn "${ARN}" --output json 2>/dev/null || true)
    INUSE=$(echo "${DESC}" | jq -r '.Certificate.InUseBy | length')
    ISSUER=$(echo "${DESC}" | jq -r '.Certificate.Issuer // ""')
    if [ "${INUSE:-0}" = "0" ] && echo "${ISSUER}" | grep -qi 'self'; then
      echo " -> Deleting unused self-signed certificate: ${ARN} (Issuer=${ISSUER})"
      aws acm delete-certificate --region "${AWS_REGION}" --certificate-arn "${ARN}" >/dev/null 2>&1 || true
    fi
  done
else
  echo " -> No ACM certificates found."
fi

say "Done: AWS resources for ${APP_NAME} have been removed."
