#!/usr/bin/env bash
set -euo pipefail

# ── Job Board → Discord ────────────────────────────────────────────────────────
# Polls the Closing Saif job board (Supabase/PostgREST) and posts new listings
# to a Discord webhook. State is a single ISO timestamp watermark in state/.
#
# Required env: BOARD_EMAIL, BOARD_PASSWORD, DISCORD_WEBHOOK
# Optional env: DEBUG_DUMP=1   -> print one raw row and exit without posting
#               BACKFILL=N     -> on first run, post the N newest jobs
# ──────────────────────────────────────────────────────────────────────────────

SUPABASE_URL="https://kapuqxetvpudjybnpnta.supabase.co"
COMMUNITY_ID="7869e08f-e364-45f3-b11d-e0fad22c3671"
BOARD_URL="https://noreplyjobs.com/jobs"

# Supabase anon key — public by design, ships in every page load of the site.
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImthcHVxeGV0dnB1ZGp5Ym5wbnRhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAwMzA4MDMsImV4cCI6MjA4NTYwNjgwM30.EH68db6CKJuaZMjkr5TtlCyHc7TYaR4-NZ5ZIbK3Ck4"

STATE_FILE="state/last_seen.json"
MAX_POST_PER_RUN=10   # safety valve: never flood the channel

die() { echo "::error::$*" >&2; exit 1; }

for v in BOARD_EMAIL BOARD_PASSWORD DISCORD_WEBHOOK; do
  [[ -n "${!v:-}" ]] || die "Missing required secret: $v"
done

# Strip stray whitespace/CR that copy-paste into the secrets UI commonly adds.
trim() { printf '%s' "$1" | tr -d '\r\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
RAW_EMAIL_LEN=${#BOARD_EMAIL}
RAW_PASS_LEN=${#BOARD_PASSWORD}
BOARD_EMAIL=$(trim "$BOARD_EMAIL")
BOARD_PASSWORD=$(trim "$BOARD_PASSWORD")

if [[ "${DEBUG_DUMP:-0}" == "1" ]]; then
  echo "── CREDENTIAL SHAPE (no values shown) ──"
  echo "email: raw_len=$RAW_EMAIL_LEN trimmed_len=${#BOARD_EMAIL} domain=@${BOARD_EMAIL##*@}"
  echo "pass:  raw_len=$RAW_PASS_LEN trimmed_len=${#BOARD_PASSWORD}"
  [[ "$RAW_EMAIL_LEN" != "${#BOARD_EMAIL}" ]] && echo "  !! email had surrounding whitespace — trimmed"
  [[ "$RAW_PASS_LEN"  != "${#BOARD_PASSWORD}" ]] && echo "  !! password had surrounding whitespace — trimmed"
  [[ "$BOARD_EMAIL" == *" "* ]] && echo "  !! email contains an interior space"
  echo "───────────────────────────────────────"
fi

# ── 1. Authenticate ───────────────────────────────────────────────────────────
# The board's RLS blocks anonymous reads of job_listings, so we mint a fresh
# 1-hour JWT on every run. Stateless — nothing to expire or rotate.
echo "Authenticating…"
AUTH_BODY=$(jq -n --arg e "$BOARD_EMAIL" --arg p "$BOARD_PASSWORD" \
              '{email:$e, password:$p}')

AUTH_RESP=$(curl -sS -X POST \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d "$AUTH_BODY" \
  "$SUPABASE_URL/auth/v1/token?grant_type=password")

TOKEN=$(jq -r '.access_token // empty' <<<"$AUTH_RESP")

# Some providers normalise the address; retry once lowercased before giving up.
if [[ -z "$TOKEN" && "$BOARD_EMAIL" != "$(tr '[:upper:]' '[:lower:]' <<<"$BOARD_EMAIL")" ]]; then
  echo "Retrying with lowercased email…"
  AUTH_RESP=$(curl -sS -X POST -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "$(jq -n --arg e "$(tr '[:upper:]' '[:lower:]' <<<"$BOARD_EMAIL")" --arg p "$BOARD_PASSWORD" '{email:$e,password:$p}')" \
    "$SUPABASE_URL/auth/v1/token?grant_type=password")
  TOKEN=$(jq -r '.access_token // empty' <<<"$AUTH_RESP")
fi

if [[ -z "$TOKEN" ]]; then
  # Only error fields — never the raw response, which can carry token material.
  echo "::error::Login failed"
  echo "  error_code: $(jq -r '.error_code // "—"' <<<"$AUTH_RESP")"
  echo "  msg:        $(jq -r '.msg // .error_description // .error // "—"' <<<"$AUTH_RESP")"
  echo "  http_keys:  $(jq -r 'keys_unsorted | join(",")' <<<"$AUTH_RESP" 2>/dev/null || echo 'unparseable')"
  exit 1
fi
echo "Authenticated."

# ── 2. Fetch newest listings ──────────────────────────────────────────────────
QUERY="select=*&is_active=eq.true&superseded_by=is.null"
QUERY+="&or=%28network_wide.eq.true%2Ccommunity_id.eq.${COMMUNITY_ID}%29"
QUERY+="&order=created_at.desc&limit=50"

ROWS=$(curl -sS \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $TOKEN" \
  "$SUPABASE_URL/rest/v1/job_listings?$QUERY")

COUNT=$(jq 'length' <<<"$ROWS")
echo "Fetched $COUNT listings."
[[ "$COUNT" -gt 0 ]] || { echo "Nothing returned; exiting."; exit 0; }

# Verification mode: dump one row so field mapping can be checked against reality.
if [[ "${DEBUG_DUMP:-0}" == "1" ]]; then
  echo "── FIELD ENCODINGS ACROSS ALL $COUNT ROWS ──"
  echo "experience_level values: $(jq -c '[.[].experience_level] | unique' <<<"$ROWS")"
  echo "step2_type values:       $(jq -c '[.[].step2_type] | unique' <<<"$ROWS")"
  echo "positions shapes:        $(jq -c '[.[].positions | type] | unique' <<<"$ROWS")"
  echo "work_hours values:       $(jq -c '[.[].work_hours[]?] | unique' <<<"$ROWS")"
  echo "time_commitment values:  $(jq -c '[.[].time_commitment[]?] | unique' <<<"$ROWS")"
  echo "rows lacking application_url: $(jq '[.[] | select((.application_url // "") == "")] | length' <<<"$ROWS")"
  echo ""
  echo "── SAMPLE ROW ──"
  jq '.[0]' <<<"$ROWS"
  echo ""
  DRY_RUN=1
fi

# ── 3. Work out what's new ────────────────────────────────────────────────────
NEWEST=$(jq -r '.[0].created_at' <<<"$ROWS")

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  # Debug: render the 2 newest regardless of watermark, post nothing.
  NEW=$(jq -c '[limit(2; .[])] | reverse' <<<"$ROWS")
  LAST=""
elif [[ -f "$STATE_FILE" ]]; then
  LAST=$(jq -r '.last_seen // ""' "$STATE_FILE")
else
  LAST=""
fi

N="${BACKFILL:-0}"
[[ "$N" =~ ^[0-9]+$ ]] || N=0

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  : # NEW already set above
elif [[ "$N" -gt 0 ]]; then
  # Explicit backfill wins over the watermark, so the feed can be demoed or
  # replayed on demand without hand-editing state.
  echo "Backfill requested: posting the $N newest regardless of watermark."
  NEW=$(jq -c --argjson n "$N" '[limit($n; .[])] | reverse' <<<"$ROWS")
elif [[ -z "$LAST" ]]; then
  echo "First run: setting watermark to $NEWEST, posting nothing."
  mkdir -p state
  jq -n --arg t "$NEWEST" '{last_seen:$t}' > "$STATE_FILE"
  exit 0
else
  # Strictly greater than the watermark — equal timestamps are already posted.
  NEW=$(jq -c --arg last "$LAST" '[.[] | select(.created_at > $last)] | reverse' <<<"$ROWS")
fi

NEW_COUNT=$(jq 'length' <<<"$NEW")
echo "$NEW_COUNT new job(s) since ${LAST:-<none>}."
if [[ "$NEW_COUNT" -eq 0 ]]; then exit 0; fi

if [[ "$NEW_COUNT" -gt "$MAX_POST_PER_RUN" ]]; then
  echo "::warning::$NEW_COUNT new jobs exceeds cap of $MAX_POST_PER_RUN; posting the $MAX_POST_PER_RUN oldest and advancing the watermark only that far."
  NEW=$(jq -c --argjson n "$MAX_POST_PER_RUN" '[limit($n; .[])]' <<<"$NEW")
  NEW_COUNT="$MAX_POST_PER_RUN"
fi

# ── 4. Build + send one embed per job ─────────────────────────────────────────
POSTED=0
FAILED=0
HIGHWATER="$LAST"

for i in $(seq 0 $((NEW_COUNT - 1))); do
  JOB=$(jq -c ".[$i]" <<<"$NEW")

  PAYLOAD=$(jq -n --argjson j "$JOB" --arg board "$BOARD_URL" '
    # Board'"'"'s own role colours, lifted from its CSS variables
    def colors: {
      "closer":      3901951,   # #3b82f6
      "setter":     16005726,   # #f43f5e
      "dm_setter":   1096065,   # #10b981
      "full_cycle":   440516,   # #06b6d4
      "manager":     9156598,   # #8b5cf6
      "csm":        16095243    # #f59e0b
    };
    def rolename: {
      "closer":"Closer", "setter":"Setter", "dm_setter":"DM Setter",
      "full_cycle":"Full-Cycle", "manager":"Manager", "csm":"CSM"
    };
    def money: if . == null or . == 0 then null
               else "**$" + (. | floor | tostring
                    | [scan("\\d{1,3}(?=(?:\\d{3})*$)")] | join(",")) + "**/mo" end;
    def clip($n): if (. | length) > $n then (.[0:$n] + "…") else . end;
    # Compact currency for revenue / ticket size: 250000 -> $250k, 1500000 -> $1.5M
    def kfmt: if . == null or . == 0 then null
              elif . >= 1000000 then "$" + (((. / 100000) | floor) / 10 | tostring) + "M"
              elif . >= 1000     then "$" + ((. / 1000) | floor | tostring) + "k"
              else "$" + (. | floor | tostring) end;
    # experience_level arrives as an integer index, not a label
    # Levels observed in live data are 1..4 with no 0, so treat as 1-indexed.
    def explevel: {"1":"0-3mo","2":"3-6mo","3":"6-12mo","4":"12-24mo","5":"24mo+"};

    # positions may arrive as an array or a single string
    ($j.positions
      | if type == "array" then . elif type == "string" then [.] else [] end) as $pos

    | ($pos | map(ascii_downcase)) as $pk
    | ($pk | map(rolename[.] // .) | join(" & ")) as $roleLabel
    | (colors[$pk[0] // ""] // 5793266) as $color

    # Highest advertised OTE across whichever roles this listing covers
    | ([ $pk[] as $p
         | ({"closer":$j.closer_ote_max, "setter":$j.setter_ote_max,
             "dm_setter":$j.dm_setter_ote_max, "full_cycle":$j.full_cycle_ote_max,
             "manager":$j.manager_ote_max, "csm":$j.csm_ote_max}[$p]) ]
       | map(select(. != null)) | max) as $ote

    # Apply target: explicit URL, else derive from the board'"'"'s step2 button,
    # else the point-of-contact, else fall back to the listing itself.
    | ($j.step2_type // "" | ascii_downcase) as $s2t
    | ($j.step2_content // "") as $s2c
    | (
        if ($j.application_url // "") != "" then
          { text: ($j.step2_label // "Open application"), url: $j.application_url }
        elif $s2c != "" then
          if ($s2t | test("insta")) then
            { text: ("DM @" + ($s2c | ltrimstr("@")) + " on Instagram"),
              url: ("https://instagram.com/" + ($s2c | ltrimstr("@") | sub("^https?://(www\\.)?instagram\\.com/";""))) }
          elif ($s2t | test("mail")) or ($s2c | test("^[^@\\s]+@[^@\\s]+$")) then
            { text: ("Email " + $s2c), url: ("mailto:" + $s2c) }
          elif ($s2c | test("^https?://")) then
            { text: ($j.step2_label // "Apply"), url: $s2c }
          else null end
        elif ($j.poc_social // "") != "" then
          { text: "Contact recruiter",
            url: (if ($j.poc_social | test("^https?://")) then $j.poc_social
                  else "https://instagram.com/" + ($j.poc_social | ltrimstr("@")) end) }
        elif ($j.poc_email // "") != "" then
          { text: ("Email " + $j.poc_email), url: ("mailto:" + $j.poc_email) }
        else null end
      ) as $apply

    | ($j.application_details_url // "") as $details

    # The board spreads its apply flow across step1..step6.
    | ([ range(1;7)
         | { n: .,
             lbl: ($j["step\(.)_label"]   // ""),
             cnt: ($j["step\(.)_content"] // "") }
         | select(.lbl != "" or .cnt != "") ]) as $steps

    | (($j.work_hours // []) + ($j.time_commitment // []) | join(" • ")) as $schedule
    | (if ($j.business_website // "") != "" then $j.business_website
       elif ($j.business_social // "") != "" then $j.business_social
       else "" end) as $companyUrl

    | {
        username: "Job Board",
        embeds: [ {
          title: ($j.title // "New job posting" | clip(250)),
          url: $board,
          color: $color,
          description: (if ($j.offer_description // "") != ""
                        then "*" + ($j.offer_description | clip(300)) + "*" else null end),
          fields: (
            [ { name: "Role",  value: (if $roleLabel == "" then "—" else $roleLabel end), inline: true } ]
            + (if ($ote | money) then [ { name: "OTE", value: ($ote | money), inline: true } ] else [] end)
            + (if ($j.monthly_revenue | kfmt) then
                 [ { name: "Revenue", value: (($j.monthly_revenue | kfmt) + "/mo"), inline: true } ] else [] end)
            + (if ($j.niche // "") != "" then [ { name: "Niche", value: ($j.niche | clip(200)), inline: true } ] else [] end)
            + (if $j.experience_level != null then
                 [ { name: "Experience",
                     value: (explevel[$j.experience_level | tostring] // ($j.experience_level | tostring)),
                     inline: true } ] else [] end)
            + (if ($j.ticket_size_max | kfmt) then
                 [ { name: "Ticket",
                     value: ((if ($j.ticket_size_min | kfmt) then ($j.ticket_size_min | kfmt) + "–" else "" end)
                             + ($j.ticket_size_max | kfmt)),
                     inline: true } ] else [] end)
            + (if ($j.poc_name // "") != "" then [ { name: "Recruiter", value: ($j.poc_name | clip(200)), inline: true } ] else [] end)
            + (if $companyUrl != "" then [ { name: "Company", value: ("[Link](" + $companyUrl + ")"), inline: true } ] else [] end)
            + (if $schedule != "" then [ { name: "Schedule", value: ($schedule | clip(200)), inline: true } ] else [] end)

            + (if ($j.notes // "") != "" then
                 [ { name: ":pushpin: Requirements", value: ($j.notes | clip(900)), inline: false } ]
               else [] end)

            + (if ($j.application_instructions // "") != "" or ($steps | length) > 0 then
                 [ { name: ":clipboard: How to Apply",
                     value: (
                       (if ($j.application_instructions // "") != ""
                        then ">>> " + ($j.application_instructions | clip(600)) + "\n" else "" end)
                       + ($steps | map(
                           "**" + (.n | tostring) + ".** "
                           + (if .lbl != "" then (.lbl | clip(120)) else "Step" end)
                           + (if (.cnt | test("^https?://")) then " — [open](" + .cnt + ")" else "" end)
                         ) | join("\n"))
                     ) | clip(1020),
                     inline: false } ]
               else [] end)

            + [ { name: ":arrow_forward: Apply",
                  value: (
                    (if $apply then "**[" + ($apply.text | clip(80)) + "](" + $apply.url + ")**\n" else "" end)
                    + (if $details != "" then "[Full details](" + $details + ")\n" else "" end)
                    + "[View listing on board](" + $board + ")"
                  ),
                  inline: false } ]
          ),
          timestamp: $j.created_at
        } ]
      }

    # Enforce Discord limits: no empty names/values, 1024 per value, 25 fields,
    # 256-char title. A single violation makes the whole webhook call 400.
    | .embeds[0].fields |= ( map(
          .name  = ((.name  // "") | tostring)
        | .value = ((.value // "") | tostring)
        | select((.name | length) > 0 and (.value | length) > 0)
        | .name  = (if (.name  | length) > 256  then (.name[0:253]  + "…") else .name  end)
        | .value = (if (.value | length) > 1024 then (.value[0:1021] + "…") else .value end)
      ) | .[0:25] )
    | .embeds[0].title = ((.embeds[0].title // "New job posting")[0:256])
    | (if ((.embeds[0].description // "") | length) == 0
       then .embeds[0] |= del(.description) else . end)
  ')

  # Debug: show the finished embed instead of sending it.
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "──────── EMBED $((i + 1)) of $NEW_COUNT ────────"
    echo "job: $(jq -r '.title' <<<"$JOB")"
    jq '.embeds[0]' <<<"$PAYLOAD"
    echo ""
    continue
  fi

  # Post, honouring Discord rate limits (429 -> wait and retry once).
  for attempt in 1 2 3; do
    HTTP=$(curl -sS -o /tmp/dresp -w "%{http_code}" \
             -H "Content-Type: application/json" \
             -X POST -d "$PAYLOAD" "$DISCORD_WEBHOOK")
    if [[ "$HTTP" == "204" || "$HTTP" == "200" ]]; then
      break
    elif [[ "$HTTP" == "429" ]]; then
      WAIT=$(jq -r '.retry_after // 2' /tmp/dresp 2>/dev/null || echo 2)
      echo "Rate limited; sleeping ${WAIT}s"
      sleep "$WAIT"
    else
      echo "::warning::Discord returned $HTTP for \"$(jq -r '.title' <<<"$JOB")\""
      echo "  response: $(head -c 600 /tmp/dresp)"
      break
    fi
  done

  if [[ "$HTTP" == "204" || "$HTTP" == "200" ]]; then
    POSTED=$((POSTED + 1))
  else
    # Skip rather than stop: one permanently-malformed listing must not block
    # every job behind it forever. Loud in the log so it can be investigated.
    FAILED=$((FAILED + 1))
    echo "::error::Skipping \"$(jq -r '.title' <<<"$JOB")\" after $HTTP — see response above."
  fi
  # Advance past this job either way, so a bad row cannot wedge the queue.
  HIGHWATER=$(jq -r '.created_at' <<<"$JOB")

  sleep 1
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY RUN — nothing was posted and the watermark was not touched."
  exit 0
fi

echo "Posted $POSTED job(s); $FAILED skipped."

# ── 5. Persist watermark ──────────────────────────────────────────────────────
if [[ -n "$HIGHWATER" && "$HIGHWATER" != "$LAST" ]]; then
  mkdir -p state
  jq -n --arg t "$HIGHWATER" '{last_seen:$t}' > "$STATE_FILE"
  echo "Watermark -> $HIGHWATER"
fi
