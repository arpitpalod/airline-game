#!/bin/sh
# Applies the sign-in email settings in supabase/auth to the live project through the Supabase Management API
# (spec 14.21). Run by .github/workflows/auth.yml. Needs two repository secrets, never printed or committed:
#   SUPABASE_ACCESS_TOKEN  a Supabase personal access token (supabase.com/dashboard/account/tokens)
#   SMTP_PASSWORD          the Gmail app password of the sender in supabase/auth/config.json
# First it sends a test email from the sender to itself, so a wrong password stops here and Supabase is left as it was.
set -eu
REF=ptdqbzwxvhkrwoneqptr
DIR=supabase/auth
[ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || { echo "Missing repository secret SUPABASE_ACCESS_TOKEN"; exit 1; }
[ -n "${SMTP_PASSWORD:-}" ] || { echo "Missing repository secret SMTP_PASSWORD"; exit 1; }
PASS=$(printf %s "$SMTP_PASSWORD" | tr -d ' ')        # Google shows app passwords in groups of four
USER=$(jq -r .smtp_user "$DIR/config.json")
HOST=$(jq -r .smtp_host "$DIR/config.json")
PORT=$(jq -r .smtp_port "$DIR/config.json")
NAME=$(jq -r .smtp_sender_name "$DIR/config.json")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Sending a test email from $USER to itself"
printf 'From: %s <%s>\r\nTo: %s\r\nSubject: Email check from GitHub\r\n\r\nThe game can send email from this account (workflow run %s).\r\n' \
  "$NAME" "$USER" "$USER" "${GITHUB_RUN_ID:-local}" > "$TMP/mail.txt"
curl -sS --ssl-reqd --url "smtps://$HOST:$PORT" --mail-from "$USER" --mail-rcpt "$USER" \
  --user "$USER:$PASS" --upload-file "$TMP/mail.txt"
echo "Test email sent"

jq --rawfile confirm "$DIR/confirm.html" --rawfile recovery "$DIR/recovery.html" --arg pass "$PASS" \
  '. + {mailer_templates_confirmation_content: $confirm, mailer_templates_recovery_content: $recovery, smtp_pass: $pass}' \
  "$DIR/config.json" > "$TMP/body.json"
code=$(curl -sS -o "$TMP/out.json" -w '%{http_code}' -X PATCH "https://api.supabase.com/v1/projects/$REF/config/auth" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H 'Content-Type: application/json' --data-binary "@$TMP/body.json")
if [ "$code" != 200 ]; then
  echo "Supabase refused the settings (HTTP $code): $(jq -r '.message // .error // "no message"' "$TMP/out.json" 2>/dev/null || echo 'no message')"
  exit 1
fi
echo "Applied. Live settings now:"
curl -sS "https://api.supabase.com/v1/projects/$REF/config/auth" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  | jq '{site_url, disable_signup, external_email_enabled, mailer_autoconfirm, mailer_otp_length, mailer_otp_exp,
         password_min_length, rate_limit_email_sent, smtp_host, smtp_port, smtp_user, smtp_admin_email, smtp_sender_name,
         mailer_subjects_confirmation, mailer_subjects_recovery,
         confirmation_has_code: (.mailer_templates_confirmation_content | tostring | contains(".Token")),
         recovery_has_code: (.mailer_templates_recovery_content | tostring | contains(".Token"))}'
