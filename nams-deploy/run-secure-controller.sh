#!/usr/bin/env bash
set -Eeuo pipefail

RAW_LOG="${RUNNER_TEMP:-/tmp}/nams-controller-raw.log"
RESULT="${NAMS_RESULT_FILE:-nams-deployment-result.json}"
SANITIZED="nams-deployment-result-public.json"
cleanup(){ rm -f "$RAW_LOG"; }
trap cleanup EXIT

set +e
bash nams-deploy/oracle-controller.sh >"$RAW_LOG" 2>&1
RC=$?
set -e

# Never expose generated dashboard credentials in public Actions logs.
sed -E \
  -e 's/(token=)[0-9a-fA-F]{32,}/\1[REDACTED]/g' \
  -e 's/^(Token:).*/\1 [REDACTED]/' \
  -e 's/^TOKEN=.*/TOKEN=[REDACTED]/' \
  "$RAW_LOG"

if [ -f "$RESULT" ]; then
  TOKEN="$(jq -r '.token // empty' "$RESULT")"
  INSTANCE_ID="$(jq -r '.instance_id // empty' "$RESULT")"
  STATUS="$(jq -r '.status // "unknown"' "$RESULT")"

  if [ "$RC" -eq 0 ] && [ "$STATUS" = success ] && [[ "$INSTANCE_ID" == ocid1.* ]] && [ -n "$TOKEN" ]; then
    # Keep the token inside the user's OCI tenancy, not in this public repository.
    oci compute instance update \
      --region "${OCI_REGION:-ap-mumbai-1}" \
      --instance-id "$INSTANCE_ID" \
      --freeform-tags "{\"NAMSBootstrapToken\":\"$TOKEN\",\"NAMSDeploymentRun\":\"${GITHUB_RUN_ID:-manual}\"}" \
      --force >/dev/null

    cat >nams-token-retrieval.txt <<EOF
NAMS is fully installed and verified.
Retrieve the token from Oracle Cloud Shell with:

oci compute instance get --region '${OCI_REGION:-ap-mumbai-1}' --instance-id '$INSTANCE_ID' --query 'data."freeform-tags".NAMSBootstrapToken' --raw-output

Then open:
https://${NAMS_DOMAIN:-seo.nitutravels.in}/?token=PASTE_THE_PRINTED_TOKEN
EOF
  fi

  jq 'del(.token)' "$RESULT" >"$SANITIZED"
  mv "$SANITIZED" "$RESULT"
fi

if command -v shred >/dev/null 2>&1; then shred -u "$RAW_LOG" 2>/dev/null || rm -f "$RAW_LOG"; else rm -f "$RAW_LOG"; fi
exit "$RC"
