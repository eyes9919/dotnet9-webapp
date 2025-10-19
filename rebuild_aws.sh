#!/usr/bin/env bash
# rebuild_aws.sh : Copilotアプリ/環境/サービスを完全再構築（非対話・タグ付SSM対応）

set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x
# 失敗したコマンドと行番号を必ず表示（関数内でも有効）
set -o errtrace
# Allow suppressing the ERR trap in controlled sections by toggling ERR_SILENT=1
ERR_SILENT=0
on_err() {
  local ec="$?"
  # If we're in a "controlled failure" block, don't abort.
  if [ "${ERR_SILENT:-0}" = "1" ]; then
    return 0
  fi
  echo "FAIL: command '$BASH_COMMAND' exited with $ec (line $LINENO)"
  die "途中で失敗しました（直前のステップのログを確認）"
}
trap 'on_err' ERR

log() { printf "\n===> %s\n\n" "$*"; }
die() { echo -e "ERROR: $*" >&2; exit 1; }

# README (script overview)
# - Purpose: Rebuild AWS resources for a Copilot app/env/service.
# - Features:
#   * App/Env/Service ensure + deploy (Copilot)
#   * ADMIN_PASSWORD secret to SSM Parameter Store (with Copilot tags)
#   * ALB HTTPS options:
#       - Trusted: attach ACM cert (when a real domain is configured)
#   * DRY RUN mode: no changes are made; shows what would happen. Uses `copilot svc deploy --diff`.
# - Prerequisites:
#   * CLI: aws, copilot, jq, openssl
#   * AWS credentials and default profile/region configured
#
# - Usage:
#   * Normal: `./rebuild_aws.sh`
#   * Dry run: `./rebuild_aws.sh --dry-run` (alias: `-n`)
#   * Enable ALB HTTPS with an existing ACM cert: `ALB_CERT_ARN=arn:aws:acm:...:certificate/xxxx ./rebuild_aws.sh`
#   * Auto-resolve cert by domain: `ALB_CERT_DOMAIN=app.example.com ./rebuild_aws.sh`
#   * Auto-request (DNS validate) + bind: `ALB_CERT_DOMAIN=app.example.com HOSTED_ZONE_ID=Z123... CREATE_ACM_IF_MISSING=1 ./rebuild_aws.sh`
#   * No custom domain:
#       - ALB stays HTTP (cost-minimized)

########################################
# 設定（環境変数なしで自己完結。必要なら一時的に上書き可）
########################################
APP_NAME="${APP_NAME:-webapp}"
ENV_NAME="${ENV_NAME:-test}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

SVC_NAME="${SVC_NAME:-webapp}"
DOCKERFILE="${DOCKERFILE:-./src/WebApp/Dockerfile}"
SVC_PORT="${SVC_PORT:-8080}"

ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin123!}"   # 無指定なら既定
ADMIN_SECRET_SSM="/copilot/${APP_NAME}/${ENV_NAME}/secrets/ADMIN_PASSWORD"

MANIFEST_ENV="copilot/environments/${ENV_NAME}/manifest.yml"
MANIFEST_SVC="copilot/${SVC_NAME}/manifest.yml"

# 既定値（ここを書き換えれば常に反映）
DEFAULT_DOMAIN="app.example.com"                # ← 独自ドメインに変更
DEFAULT_HOSTED_ZONE_ID=""                       # ← 空でOK（自動解決）。分かっていればIDを設定
# NOTE: 上記2つがプレースホルダーのままの場合は自動解決を試みます（Hosted Zoneは最長一致で推定）。
DEFAULT_CREATE_ACM=1                            # 証明書が無ければ自動発行
DEFAULT_AUTO_SUFFIX_ON_REGION_CONFLICT=1        # 1=他リージョン競合時は自動で -apne1 などを付与して再試行

# 実際に使う値（環境変数で一時上書きも可）
ALB_CERT_ARN="${ALB_CERT_ARN:-}"                      # 明示指定あれば優先
ALB_CERT_DOMAIN="${ALB_CERT_DOMAIN:-$DEFAULT_DOMAIN}" # 既定ドメイン
CREATE_ACM_IF_MISSING="${CREATE_ACM_IF_MISSING:-$DEFAULT_CREATE_ACM}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-$DEFAULT_HOSTED_ZONE_ID}"
AUTO_SUFFIX_ON_REGION_CONFLICT="${AUTO_SUFFIX_ON_REGION_CONFLICT:-$DEFAULT_AUTO_SUFFIX_ON_REGION_CONFLICT}"

########################################
# オプション（--dry-run / -n）
########################################
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
  esac
done
if [ "$DRY_RUN" -eq 1 ]; then
  log "MODE: DRY RUN (no changes will be made)"
fi

# ドメイン未設定時の挙動：ALBはHTTPのまま
if [ -z "${ALB_CERT_DOMAIN}" ] || [ "${ALB_CERT_DOMAIN}" = "app.example.com" ]; then
  echo "    No real domain configured. ALB will remain HTTP (cost-minimized)."
fi

# Decide if we actually want to configure ALB HTTPS in this run
WANT_ALB_HTTPS=0
if [ -n "${ALB_CERT_ARN}" ] || { [ -n "${ALB_CERT_DOMAIN}" ] && [ "${ALB_CERT_DOMAIN}" != "app.example.com" ]; }; then
  WANT_ALB_HTTPS=1
fi

########################################
# 共通
########################################
# ※ 旧 trap は削除済み（上部の強化版 trap が有効）

# Ensure we're running under bash (not sh/dash)
if [ -z "${BASH_VERSION:-}" ]; then
  die "Please run with bash: chmod +x ./rebuild_aws.sh && ./rebuild_aws.sh"
fi

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v copilot >/dev/null 2>&1 || die "copilot not found"
command -v jq >/dev/null 2>&1 || die "jq not found (brew install jq)"
command -v openssl >/dev/null 2>&1 || die "openssl not found"

# Ensure all CLIs use the intended region
export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"
echo "    Using region: ${AWS_REGION}"
aws sts get-caller-identity --region "$AWS_REGION" >/dev/null || die "AWS資格情報/リージョン確認エラー"
if [ "${DEBUG:-0}" = "1" ]; then
  echo "== DEBUG: copilot version = $(copilot --version 2>&1 || copilot -v 2>&1)"
  echo "== DEBUG: aws identity = $(aws sts get-caller-identity --region "$AWS_REGION" --output json 2>/dev/null)"
  echo "== DEBUG: AWS_REGION=$AWS_REGION AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION"
fi

########################################
# Helper: resolve hosted zone by domain (longest suffix match)
########################################
resolve_hosted_zone_if_needed() {
  if [ -n "${HOSTED_ZONE_ID}" ] && [ "${HOSTED_ZONE_ID}" != "Z0000000000000" ]; then
    return 0
  fi
  if [ -z "${ALB_CERT_DOMAIN}" ] || [ "${ALB_CERT_DOMAIN}" = "app.example.com" ]; then
    echo "    Hosted zone auto-resolve skipped: domain is placeholder (${ALB_CERT_DOMAIN})."
    return 0
  fi
  log "Auto-resolving Route53 hosted zone for domain: ${ALB_CERT_DOMAIN}"
  local ZID
  ZID="$(aws route53 list-hosted-zones --output json \
    | jq -r --arg d "${ALB_CERT_DOMAIN}." '
        .HostedZones
        | map({Id, Name, L:(.Name|length)})
        | map(select(($d|endswith(.Name))))
        | sort_by(.L) | reverse | (.[0].Id // empty)
      ' 2>/dev/null || true)"
  if [ -n "${ZID}" ]; then
    HOSTED_ZONE_ID="${ZID##*/}"
    echo "    Found hosted zone: ${HOSTED_ZONE_ID}"
  else
    echo "    Could not auto-resolve hosted zone for ${ALB_CERT_DOMAIN}."
  fi
}


########################################
# Helper: resolve or request ACM cert
########################################
resolve_or_request_acm() {
  if [ -n "${ALB_CERT_ARN}" ]; then
    log "Using provided ALB_CERT_ARN: ${ALB_CERT_ARN}"
    return 0
  fi
  if [ -z "${ALB_CERT_DOMAIN}" ]; then
    echo "    ALB_CERT_ARN and ALB_CERT_DOMAIN not set; skipping ACM resolution."
    return 0
  fi

  log "Resolve ACM certificate for domain: ${ALB_CERT_DOMAIN}"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [DRY-RUN] would search ACM for domain or wildcard."
    echo "    [DRY-RUN] CREATE_ACM_IF_MISSING=${CREATE_ACM_IF_MISSING}, HOSTED_ZONE_ID=${HOSTED_ZONE_ID:-<none>}"
    return 0
  fi

  local CERT_ARN=""
  CERT_ARN="$(aws acm list-certificates --region "${AWS_REGION}" \
    --certificate-statuses ISSUED PENDING_VALIDATION INACTIVE EXPIRED VALIDATION_TIMED_OUT REVOKED FAILED \
    --query "reverse(sort_by(CertificateSummaryList,&CreatedAt))[?DomainName=='${ALB_CERT_DOMAIN}' || DomainName=='*.${ALB_CERT_DOMAIN}'][0].CertificateArn" \
    --output text 2>/dev/null || true)"

  if [ -n "${CERT_ARN}" ] && [ "${CERT_ARN}" != "None" ]; then
    echo "    Found existing ACM certificate: ${CERT_ARN}"
    ALB_CERT_ARN="${CERT_ARN}"
    return 0
  fi

  if [ "${CREATE_ACM_IF_MISSING}" = "1" ]; then
    log "Requesting new ACM certificate (DNS validation) for ${ALB_CERT_DOMAIN} (+ SAN *.${ALB_CERT_DOMAIN})"
    CERT_ARN="$(aws acm request-certificate \
      --region "${AWS_REGION}" \
      --domain-name "${ALB_CERT_DOMAIN}" \
      --validation-method DNS \
      --subject-alternative-names "*.${ALB_CERT_DOMAIN}" \
      --query CertificateArn \
      --output text)"
    echo "    Requested certificate: ${CERT_ARN}"

    resolve_hosted_zone_if_needed

    if [ -n "${HOSTED_ZONE_ID}" ] && [ "${HOSTED_ZONE_ID}" != "Z0000000000000" ]; then
      log "Creating Route53 DNS validation records in zone ${HOSTED_ZONE_ID}"

      ATTEMPTS=0
      until [ $ATTEMPTS -ge 30 ]; do
        aws acm describe-certificate --region "${AWS_REGION}" --certificate-arn "${CERT_ARN}" \
          --query 'Certificate.DomainValidationOptions[].ResourceRecord' --output json > /tmp/rr.json || true
        if jq -e 'length>0 and (.[0].Name != null)' /tmp/rr.json >/dev/null 2>&1; then
          break
        fi
        ATTEMPTS=$((ATTEMPTS+1))
        sleep 5
      done

      if ! jq -e 'length>0 and (.[0].Name != null)' /tmp/rr.json >/dev/null 2>&1; then
        echo "    Warning: ACM has not provided DNS validation records yet. Please retry later:"
        echo "      aws acm describe-certificate --certificate-arn ${CERT_ARN} --region ${AWS_REGION} | jq '.Certificate.DomainValidationOptions[].ResourceRecord'"
      else
        jq -r '
          {Changes: [ .[] | {Action:"UPSERT", ResourceRecordSet:{Name:.Name, Type:.Type, TTL:300, ResourceRecords:[{Value:.Value}]}} ] }
        ' /tmp/rr.json > /tmp/rr-change-batch.json

        aws route53 change-resource-record-sets \
          --hosted-zone-id "${HOSTED_ZONE_ID}" \
          --change-batch file:///tmp/rr-change-batch.json >/dev/null

        echo "    Validation records upserted. Waiting for ACM validation (this can take several minutes)..."
        aws acm wait certificate-validated --region "${AWS_REGION}" --certificate-arn "${CERT_ARN}" || {
          echo "    Warning: certificate validation wait timed out. You can check status later:"
          echo "      aws acm describe-certificate --certificate-arn ${CERT_ARN} --region ${AWS_REGION}"
        }
        rm -f /tmp/rr.json /tmp/rr-change-batch.json
      fi
    else
      echo "    HOSTED_ZONE_ID not set and could not auto-resolve; please create DNS validation records manually."
      echo "    Tip: aws acm describe-certificate --certificate-arn ${CERT_ARN} --region ${AWS_REGION} | jq '.Certificate.DomainValidationOptions[].ResourceRecord'"
    fi

    ALB_CERT_ARN="${CERT_ARN}"
    return 0
  else
    echo "    No existing ACM cert found and CREATE_ACM_IF_MISSING=0. Skipping."
  fi
}

########################################
# Helper: ensure Route53 ALIAS to ALB
########################################
ensure_route53_alias() {
  local domain="$1"         # e.g. app.example.com
  local zone_id="$2"        # Route53 hosted zone ID (for example.com)
  local target_dns="$3"     # ALB DNS name
  local target_hzid="$4"    # ALB hosted zone id (from elbv2)

  log "Ensure Route53 ALIAS: ${domain} -> ${target_dns}"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [DRY-RUN] would UPSERT A (ALIAS) in hosted zone ${zone_id}"
    echo "    [DRY-RUN] AliasTarget: {DNSName: ${target_dns}, HostedZoneId: ${target_hzid}}"
    return 0
  fi

  cat > /tmp/alias-change.json <<EOF
{
  "Comment": "UPSERT ALIAS for ${domain} -> ${target_dns}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${domain}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${target_hzid}",
          "DNSName": "${target_dns}",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF

  aws route53 change-resource-record-sets \
    --hosted-zone-id "${zone_id}" \
    --change-batch file:///tmp/alias-change.json >/dev/null

  echo "    Route53 ALIAS upserted: ${domain} -> ${target_dns}"
  rm -f /tmp/alias-change.json
}

########################################
# Helper: ensure env manifest has the ACM cert and deploy env
########################################
ensure_env_cert_in_manifest() {
  local arn="$1"
  [ -z "$arn" ] && return 0
  log "Ensure env manifest has certificate (and deploy env)"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [DRY-RUN] would ensure cert in ${MANIFEST_ENV}: ${arn} and redeploy env"
    return 0
  fi
  [ -f "${MANIFEST_ENV}" ] || die "Env manifest not found: ${MANIFEST_ENV}"
  # If no http: block, append a full block
  if ! grep -q '^http:' "${MANIFEST_ENV}"; then
    cat >> "${MANIFEST_ENV}" <<YAML

http:
  public:
    certificates:
      - ${arn}
YAML
    echo "    Added http.public.certificates to ${MANIFEST_ENV}"
  else
    # Ensure public: exists
    if ! awk '/^http:/{p=1} p && /^[^[:space:]]/ && $0!~/^http:/{p=0} p && /^[[:space:]]+public:/{f=1} END{exit !f}' "${MANIFEST_ENV}"; then
      awk '
        {print}
        /^http:/ && !p { print "  public:\n    certificates:\n      - PLACEHOLDER_CERT"; p=1 }
      ' "${MANIFEST_ENV}" > "${MANIFEST_ENV}.tmp" && mv "${MANIFEST_ENV}.tmp" "${MANIFEST_ENV}"
      sed -i '' "s#PLACEHOLDER_CERT#${arn//#/\\#}#" "${MANIFEST_ENV}" 2>/dev/null || sed -i "s#PLACEHOLDER_CERT#${arn//#/\\#}#" "${MANIFEST_ENV}"
      echo "    Added http.public block with certificates to ${MANIFEST_ENV}"
    fi
    # Ensure certificates: list exists under public
    if ! awk '/^http:/{p=1} p && /^[^[:space:]]/ && $0!~/^http:/{p=0} p && /^[[:space:]]+public:/{f=1} f && /^[[:space:]]+certificates:/{c=1} END{exit !(f&&c)}' "${MANIFEST_ENV}"; then
      awk '
        {print}
        /^[[:space:]]+public:/ && !p { print "    certificates:\n      - PLACEHOLDER_CERT"; p=1 }
      ' "${MANIFEST_ENV}" > "${MANIFEST_ENV}.tmp" && mv "${MANIFEST_ENV}.tmp" "${MANIFEST_ENV}"
      sed -i '' "s#PLACEHOLDER_CERT#${arn//#/\\#}#" "${MANIFEST_ENV}" 2>/dev/null || sed -i "s#PLACEHOLDER_CERT#${arn//#/\\#}#" "${MANIFEST_ENV}"
      echo "    Ensured certificates list under http.public in ${MANIFEST_ENV}"
    fi
    # Append ARN if not present
    if ! grep -q "${arn}" "${MANIFEST_ENV}"; then
      awk -v CERT="${arn}" '
        {print}
        /^[[:space:]]+certificates:/ && !p { print "      - " CERT; p=1 }
      ' "${MANIFEST_ENV}" > "${MANIFEST_ENV}.tmp" && mv "${MANIFEST_ENV}.tmp" "${MANIFEST_ENV}"
      echo "    Appended ACM cert ARN to env certificates in ${MANIFEST_ENV}"
    fi
  fi
  # Deploy env to register the cert with Copilot
  copilot env deploy --name "${ENV_NAME}" --force || true
}

########################################
# Helper: cleanup env manifest cert block (undo self-signed attempt)
########################################
cleanup_env_cert_manifest() {
  # Remove the http.public.certificates block we might have added previously.
  # This avoids Copilot requiring 'alias' when an env-level certificate is present.
  local f="${MANIFEST_ENV}"
  [ -f "$f" ] || return 0

  # Quick check: only proceed if manifest appears to have an env-level cert.
  if ! grep -q '^http:' "$f"; then
    return 0
  fi
  if ! grep -q '^[[:space:]]\+public:' "$f"; then
    return 0
  fi
  if ! grep -q '^[[:space:]]\+certificates:' "$f"; then
    return 0
  fi

  log "Cleanup env manifest: remove http.public.certificates block (to avoid alias requirement)"

  # BSD awk on macOS does not accept C-style comments; use a purely POSIX awk program.
  # Buffer the http: block; if it contains both "public:" and "certificates:", drop that block.
  awk '
    BEGIN {
      in_http = 0
      buf = ""
    }
    # Start of http: top-level block
    /^http:[[:space:]]*$/ {
      if (in_http) {
        # flush previous block (safety)
        if (buf !~ /[[:space:]]public:[[:space:]]*(\r|\n)/ || buf !~ /[[:space:]]certificates:[[:space:]]*(\r|\n)/) {
          printf "%s", buf
        }
      }
      in_http = 1
      buf = $0 ORS
      next
    }
    {
      if (in_http) {
        # New top-level key (no leading spaces): decide whether to print buffered http: or drop
        if ($0 ~ /^[^[:space:]]/) {
          if (buf !~ /[[:space:]]public:[[:space:]]*(\r|\n)/ || buf !~ /[[:space:]]certificates:[[:space:]]*(\r|\n)/) {
            printf "%s", buf
          }
          in_http = 0
          buf = ""
          print $0
        } else {
          buf = buf $0 ORS
        }
      } else {
        print $0
      }
    }
    END {
      if (in_http) {
        if (buf !~ /[[:space:]]public:[[:space:]]*(\r|\n)/ || buf !~ /[[:space:]]certificates:[[:space:]]*(\r|\n)/) {
          printf "%s", buf
        }
      }
    }
  ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"

  # After removing the env-level cert block, redeploy the env so Copilot forgets the association.
  copilot env deploy --name "${ENV_NAME}" --force || true
}

########################################
# Helper: cleanup service manifest http block (remove HTTPS-only keys)
########################################
cleanup_svc_http_manifest() {
  # Normalize the top-level http: block in the service manifest to a minimal, HTTP-only config.
  # Copilot requires `http` to be specified for Load Balanced Web Service, but we must ensure no
  # HTTPS-only keys (redirect_to_https, certificates, alias) linger.
  local f="${MANIFEST_SVC}"
  [ -f "$f" ] || return 0

  log "Cleanup service manifest: reset top-level http: to minimal (HTTP-only)"

  # If there is an existing top-level http: block, replace it with a minimal one.
  # Otherwise, append a minimal http: block at the end.
  # Minimal block: just expose the root path, no HTTPS fields.
  if grep -q '^http:' "$f"; then
    awk '
      BEGIN { in_http = 0; replaced = 0 }
      # Start of top-level http:
      /^http:[[:space:]]*$/ {
        if (!replaced) {
          print "http:"
          print "  path: /"
          replaced = 1
        }
        in_http = 1
        next
      }
      {
        if (in_http) {
          # Leave http block when a new top-level key (no leading spaces) appears
          if ($0 ~ /^[^[:space:]]/) {
            in_http = 0
            print $0
          }
          # else: still inside old http block -> skip
        } else {
          print $0
        }
      }
      END {
        # If file ended while still inside http, nothing to do: we already printed minimal block.
      }
    ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  else
    # Append minimal http block to satisfy schema
    cat >> "$f" <<'YAML'

http:
  path: /
YAML
  fi

  # As a safety, strip any lingering HTTPS-only keys that might exist due to indentation quirks
  # (e.g., if the manifest had multiple http blocks in unexpected places).
  # Remove lines that are clearly HTTPS-only under any http block.
  awk '
    BEGIN { in_http = 0 }
    /^http:[[:space:]]*$/ { in_http = 1; print; next }
    {
      if (in_http) {
        if ($0 ~ /^[^[:space:]]/) { in_http = 0 }  # left http block
        # Skip HTTPS-only settings
        if ($0 ~ /^[[:space:]]+redirect_to_https:/) next
        if ($0 ~ /^[[:space:]]+certificates:/) next
        if ($0 ~ /^[[:space:]]+-[[:space:]]arn:aws:acm:/) next
        if ($0 ~ /^[[:space:]]+alias:/) next
      }
      print
    }
  ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

########################################
# 1) アプリ
########################################
log "Ensure Copilot App: ${APP_NAME}"

app_exists() {
  # Return 0 if app exists in the current account/region, 1 otherwise.
  # Never exit the script from inside this function.
  set +e
  local out rc match_rc
  out="$(copilot app ls 2>&1)"
  rc=$?
  if [ "${DEBUG:-0}" = "1" ]; then
    echo "== DEBUG: copilot app ls rc=$rc"
    echo "== DEBUG: copilot app ls output:"
    echo "$out"
  fi
  if [ $rc -ne 0 ]; then
    # Could be "application exists in another region" or CLI/config error.
    # Treat as "not found" so the caller can attempt `copilot app init` and handle the error message.
    set -e
    return 1
  fi
  # Temporarily disable pipefail so a non-match won't abort the script.
  set +o pipefail
  echo "$out" | awk '{print $1}' | grep -qx "${APP_NAME}"
  match_rc=$?
  set -o pipefail
  set -e
  return $match_rc
}

if [ "$DRY_RUN" -eq 1 ]; then
  if ! app_exists; then
    echo "    [DRY-RUN] would create app: ${APP_NAME}"
  else
    echo "    [DRY-RUN] app exists: ${APP_NAME}"
  fi
else
  if ! app_exists; then
    set +e
    ERR_SILENT=1
    INIT_OUT=$(copilot app init "${APP_NAME}" 2>&1)
    INIT_RC=$?
    ERR_SILENT=0
    set -e
    if [ $INIT_RC -ne 0 ]; then
      if [ "${DEBUG:-0}" = "1" ]; then
        echo "== DEBUG: copilot app init output (rc=$INIT_RC):"
        echo "$INIT_OUT"
      fi
      echo "$INIT_OUT"
      if echo "$INIT_OUT" | grep -qi "already exists in another region"; then
        if [ "${AUTO_SUFFIX_ON_REGION_CONFLICT}" = "1" ]; then
          # Auto-suffix and retry, e.g., webapp-apne1
          SUFFIX="$(echo "${AWS_REGION}" | tr -cd '[:alnum:]' | tail -c 6)"
          NEW_APP_NAME="${APP_NAME}-${SUFFIX}"
          echo "    Detected different-region app name conflict. Auto-suffixing and retry with: ${NEW_APP_NAME}"
          APP_NAME="${NEW_APP_NAME}"
          ADMIN_SECRET_SSM="/copilot/${APP_NAME}/${ENV_NAME}/secrets/ADMIN_PASSWORD"
          # Rebind local Copilot workspace to the new app name before retrying init
          mkdir -p copilot
          printf "application: %s\n" "${APP_NAME}" > copilot/.workspace
          echo "    Rebound local workspace to application: ${APP_NAME}"
          set +e
          ERR_SILENT=1
          INIT_OUT2=$(copilot app init "${APP_NAME}" 2>&1)
          INIT_RC2=$?
          ERR_SILENT=0
          set -e
          if [ $INIT_RC2 -ne 0 ]; then
            echo "$INIT_OUT2"
            die "copilot app init retry with '${APP_NAME}' failed"
          fi
        else
          die "Copilot application \"${APP_NAME}\" already exists in a different region.\n\
対応案:\n\
  1) スクリプト先頭の AWS_REGION をその既存リージョンに合わせる\n\
  2) 既存アプリを削除: copilot app delete -n ${APP_NAME}\n\
  3) 本スクリプトの APP_NAME を変更（例: ${APP_NAME}-apne1）"
        fi
      else
        die "copilot app init failed"
      fi
    fi
  else
    echo "    App exists: ${APP_NAME}"
  fi
fi

########################################
# 2) 環境（完全非対話）
########################################
log "Ensure Environment: ${ENV_NAME}"

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

env_exists() {
  set +e
  local out rc
  out=$(copilot env ls 2>/dev/null)
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    return 1
  fi
  echo "$out" | awk '{print $1}' | grep -qx "${ENV_NAME}"
}

if ! env_exists; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [DRY-RUN] would create environment (non-interactive): ${ENV_NAME}"
  else
    echo "    Creating new environment (non-interactive flags)"
    copilot env init \
      --name "${ENV_NAME}" \
      --app "${APP_NAME}" \
      --default-config \
      --profile default
  fi
else
  echo "    Environment exists: ${ENV_NAME}"
fi

log "Deploy Environment: ${ENV_NAME}"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    [DRY-RUN] would run: copilot env deploy --name \"${ENV_NAME}\""
else
  set +e
  ERR_SILENT=1
  copilot env deploy --name "${ENV_NAME}"
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "    Note: env deploy had no immediate changes or failed softly. Trying --force..."
    copilot env deploy --name "${ENV_NAME}" --force || true
  fi
  ERR_SILENT=0
  set -e
fi

########################################
# 3) SSM: シークレット投入＋Copilotタグ付与
########################################
log "Put & tag ADMIN_PASSWORD in SSM Parameter Store"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    [DRY-RUN] would put SecureString at: ${ADMIN_SECRET_SSM}"
  echo "    [DRY-RUN] would tag Parameter with copilot-application=${APP_NAME}, copilot-environment=${ENV_NAME}"
else
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
fi

########################################
# 4) サービス
########################################
log "Ensure service: ${SVC_NAME}"
if ! copilot svc ls 2>/dev/null | awk '{print $1}' | grep -qx "${SVC_NAME}"; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    [DRY-RUN] would create service: ${SVC_NAME}"
  else
    copilot svc init \
      --name "${SVC_NAME}" \
      --svc-type "Load Balanced Web Service" \
      --dockerfile "${DOCKERFILE}" \
      --port "${SVC_PORT}"
  fi
else
  echo "    Service exists: ${SVC_NAME}"
fi

########################################
# 5) manifest の secrets 設定
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
# 5.5) manifest の ALB HTTPS 設定
########################################

if [ "${WANT_ALB_HTTPS}" = "1" ]; then
  # Resolve/request ACM only when we intend to enable HTTPS with a REAL domain.
  resolve_or_request_acm

  if [ -n "${ALB_CERT_ARN}" ]; then
    ensure_env_cert_in_manifest "${ALB_CERT_ARN}"
    # Ensure manifest has ALB HTTPS settings
    log "Ensure manifest ALB HTTPS (redirect_to_https + certificates)"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "    [DRY-RUN] would inject redirect_to_https and certificates into ${MANIFEST_SVC}"
      echo "    [DRY-RUN] cert: ${ALB_CERT_ARN}"
    else
      if ! grep -q '^http:' "${MANIFEST_SVC}"; then
        cat >> "${MANIFEST_SVC}" <<YAML

http:
  redirect_to_https: true
  certificates:
    - ${ALB_CERT_ARN}
YAML
        echo "    Added http block with certificates to ${MANIFEST_SVC}"
      else
        if ! grep -q '^[[:space:]]*redirect_to_https:' "${MANIFEST_SVC}"; then
          awk '
            {print}
            /^http:/ && !p { print "  redirect_to_https: true"; p=1 }
          ' "${MANIFEST_SVC}" > "${MANIFEST_SVC}.tmp" && mv "${MANIFEST_SVC}.tmp" "${MANIFEST_SVC}"
          echo "    Ensured redirect_to_https in ${MANIFEST_SVC}"
        fi
        if ! grep -q '^[[:space:]]*certificates:' "${MANIFEST_SVC}"; then
          awk -v CERT="${ALB_CERT_ARN}" '
            {print}
            /^http:/ && !p { print "  certificates:\n    - " CERT; p=1 }
          ' "${MANIFEST_SVC}" > "${MANIFEST_SVC}.tmp" && mv "${MANIFEST_SVC}.tmp" "${MANIFEST_SVC}"
          echo "    Added certificates block to ${MANIFEST_SVC}"
        elif ! grep -q "${ALB_CERT_ARN}" "${MANIFEST_SVC}"; then
          awk -v CERT="${ALB_CERT_ARN}" '
            {print}
            /^[[:space:]]*certificates:/ && !p { print "    - " CERT; p=1 }
          ' "${MANIFEST_SVC}" > "${MANIFEST_SVC}.tmp" && mv "${MANIFEST_SVC}.tmp" "${MANIFEST_SVC}"
          echo "    Appended ACM cert ARN to certificates in ${MANIFEST_SVC}"
        fi
      fi
    fi
  else
    echo "    ALB_CERT_ARN not set after resolution; skipping ALB HTTPS attachment."
  fi
else
  echo "    Skipping ALB HTTPS configuration (no domain/cert)."
fi

########################################
# 6) サービスデプロイ
########################################
if [ "$DRY_RUN" -eq 1 ]; then
  log "Service diff (no changes)"
  if copilot svc ls 2>/dev/null | awk '{print $1}' | grep -qx "${SVC_NAME}"; then
    copilot svc deploy --app "${APP_NAME}" --name "${SVC_NAME}" --env "${ENV_NAME}" --diff || true
  else
    echo "    [DRY-RUN] service does not exist; would run: copilot svc init & deploy"
  fi
else
  log "Deploy service (force)"
  # Safeguard: when HTTPS enabled, ensure env manifest has the cert;
  # otherwise, strip any stray HTTPS-only settings from env & service manifests.
  if [ "${WANT_ALB_HTTPS}" = "1" ] && [ -n "${ALB_CERT_ARN}" ]; then
    ensure_env_cert_in_manifest "${ALB_CERT_ARN}"
  else
    cleanup_env_cert_manifest
    cleanup_svc_http_manifest
  fi
  # Post-cleanup verification (debug aid)
  echo "===> Post-cleanup manifest check (service)"
  if grep -nE '^[[:space:]]+redirect_to_https:|^[[:space:]]+certificates:|^[[:space:]]+alias:' "${MANIFEST_SVC}"; then
      echo "    NOTE: Found redirect/cert/alias lines above; deployment may fail if HTTPS config remains."
  else
      echo "    OK: service manifest has no redirect/cert/alias lines (minimal http: is present or will be appended)"
  fi
  echo "===> Post-cleanup manifest check (env)"
  if [ -f "${MANIFEST_ENV}" ]; then
    if awk '/^http:/{p=1} p && /^[^[:space:]]/ && $0!~/^http:/{p=0} p{print NR ":" $0}' "${MANIFEST_ENV}" | grep -E 'public:|certificates:'; then
      echo "    NOTE: Env manifest still has http.public.certificates; this can force alias requirement."
    else
      echo "    OK: env manifest has no http.public.certificates"
    fi
  fi
  copilot svc deploy --app "${APP_NAME}" --name "${SVC_NAME}" --env "${ENV_NAME}" --force
fi

########################################
########################################
# 7) Route53 ALIAS（独自ドメインがある場合のみ）
########################################
if [ "${WANT_ALB_HTTPS}" = "1" ]; then
  resolve_hosted_zone_if_needed
  if [ -n "${ALB_CERT_DOMAIN}" ] && [ "${ALB_CERT_DOMAIN}" != "app.example.com" ] && [ -n "${HOSTED_ZONE_ID}" ]; then
    log "Resolve ALB DNS for Route53 alias"
    ALB_URL=$(copilot svc show -n "${SVC_NAME}" --json | jq -r '.routes[0].url')
    ALB_DNS="${ALB_URL#http://}"
    if [ -z "${ALB_DNS}" ] || [ "${ALB_DNS}" = "null" ]; then
      echo "    Warning: could not resolve ALB DNS from copilot output; skipping Route53 alias."
    else
      ALB_HZID=$(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?DNSName=='${ALB_DNS}'].HostedZoneId | [0]" \
        --output text 2>/dev/null || true)
      if [ -z "${ALB_HZID}" ] || [ "${ALB_HZID}" = "None" ]; then
        echo "    Warning: could not resolve ALB HostedZoneId; skipping Route53 alias."
      else
        ensure_route53_alias "${ALB_CERT_DOMAIN}" "${HOSTED_ZONE_ID}" "${ALB_DNS}" "${ALB_HZID}"
      fi
    fi
  else
    echo "    Route53 alias skipped: please set DEFAULT_DOMAIN/DEFAULT_HOSTED_ZONE_ID in the script (or override via env)."
  fi
fi

########################################
# 8) 仕上げ案内
########################################
log "Done."
echo "Check status : copilot svc status -n ${SVC_NAME} -e ${ENV_NAME}"
echo "Show URL     : copilot svc show   -n ${SVC_NAME}"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Mode         : DRY RUN (no changes were made)"
else
  echo "Mode         : APPLY (changes applied)"
fi