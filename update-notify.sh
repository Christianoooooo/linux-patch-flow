#!/usr/bin/env bash
# update-notify.sh – meldet verfügbare APT-Updates per SMTP an Zammad
# Meldet nur, wenn sich die Liste der verfügbaren Updates seit der letzten Meldung geändert hat,
# und noch einmal, sobald die gemeldeten Updates installiert sind.
#
# Aufruf:  update-notify.sh            normaler Lauf (Timer)
#          update-notify.sh --force    meldet auch bei unveränderter Liste
#          update-notify.sh --dry-run  zeigt die Mail nur an, sendet nichts, speichert keinen Zustand
#          update-notify.sh --version  zeigt den installierten Stand und vergleicht ihn mit GitHub (main)
#          update-notify.sh --update   aktualisiert update-notify über den Installer von GitHub (main)

set -euo pipefail

CONF="/etc/update-notify.conf"
STATE_DIR="/var/lib/update-notify"
HASH_FILE="$STATE_DIR/last.hash"
LIST_FILE="$STATE_DIR/last.list"
MSGID_FILE="$STATE_DIR/last.msgid"
COMMIT_FILE="$STATE_DIR/installed.commit"
REPO="Christianoooooo/linux-patch-flow"
RAW_BASE="https://raw.githubusercontent.com/$REPO"
SELF=$(readlink -f "${BASH_SOURCE[0]}")

remote_ref() {  # Commit-SHA von main; Rückfall auf "main", wenn die GitHub-API nicht antwortet
  # Per SHA geladen ist der Stand sofort aktuell – der Branchname wird bis zu 5 Minuten veraltet ausgeliefert
  local sha
  sha=$(curl -fsSL --max-time 10 -H "Accept: application/vnd.github.sha" "https://api.github.com/repos/$REPO/commits/main" 2>/dev/null || true)
  if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then echo "$sha"; else echo main; fi
}

self_state() {  # gibt aktuell | veraltet | unbekannt aus (Vergleich mit GitHub main)
  local remote state
  remote=$(mktemp)
  if ! curl -fsSL --max-time 10 "$RAW_BASE/$(remote_ref)/update-notify.sh" -o "$remote" 2>/dev/null; then
    state=unbekannt
  elif cmp -s "$SELF" "$remote"; then
    state=aktuell
  else
    state=veraltet
  fi
  rm -f "$remote"
  echo "$state"
}

show_version() {
  echo "update-notify $(sha256sum "$SELF" | cut -c1-12), installiert am $(date -r "$SELF" '+%d.%m.%Y %H:%M')"
  case "$(self_state)" in
    aktuell)  echo "Aktuell – entspricht dem Stand auf GitHub (main)." ;;
    veraltet) echo "Veraltet – auf GitHub (main) liegt ein anderer Stand. Aktualisieren mit: update-notify.sh --update" ;;
    *)        echo "Vergleich mit GitHub nicht möglich (keine Verbindung)." ;;
  esac
}

self_update() {
  [[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen" >&2; exit 1; }
  local dir ref rc=0
  ref=$(remote_ref)
  if [[ "$ref" != main && "$ref" == "$(cat "$COMMIT_FILE" 2>/dev/null || true)" ]]; then
    echo "Bereits aktuell (Commit ${ref:0:7})."
    exit 0
  fi
  # Eigenes leeres Verzeichnis, damit der Installer kein lokales Repo neben sich vermutet
  dir=$(mktemp -d)
  if curl -fsSL --max-time 30 "$RAW_BASE/$ref/install.sh" -o "$dir/install.sh"; then
    bash "$dir/install.sh" || rc=$?
  else
    echo "Download des Installers fehlgeschlagen" >&2
    rc=1
  fi
  rm -rf "$dir"
  exit "$rc"
}

FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --version) show_version; exit 0 ;;
    --update)  self_update ;;
    *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
  esac
done

[[ -r "$CONF" ]] || { echo "Konfiguration $CONF fehlt" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

: "${SMTP_HOST:?SMTP_HOST fehlt in $CONF}"
: "${SMTP_PORT:=25}"
: "${SMTP_TLS:=starttls}"          # none | starttls | smtps
: "${SMTP_USER:=}"
: "${SMTP_PASS:=}"
: "${MAIL_FROM:?MAIL_FROM fehlt in $CONF}"
: "${MAIL_TO:?MAIL_TO fehlt in $CONF}"
: "${SUBJECT_PREFIX:=[Linux-Updates]}"
: "${HOST_LABEL:=$(hostname -s)}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# --- Laufenden APT-Vorgang abwarten ---------------------------------------------
# Mitten im Lauf ist der Paketstand unvollständig; update-notify.path löst schon beim Start von APT aus
WAITED=0
while pgrep -x 'apt|apt-get|aptitude|dpkg' >/dev/null; do
  if (( WAITED >= 1800 )); then
    echo "APT läuft seit über 30 Minuten – Abbruch, der nächste Lauf prüft erneut" >&2
    exit 1
  fi
  (( WAITED == 0 )) && echo "Warte auf laufenden APT-Vorgang ..."
  sleep 5
  WAITED=$(( WAITED + 5 ))
done

# --- Paketquellen aktualisieren -----------------------------------------------
if ! apt_err=$(apt-get update -qq 2>&1); then
  echo "apt-get update fehlgeschlagen:" >&2
  echo "$apt_err" >&2
  exit 1
fi

# --- Verfügbare Updates ermitteln (Simulation, ändert nichts) -----------------
# Format der Zeilen: Inst paket [altversion] (neuversion quelle [arch])
# Ein Fehler darf nicht als "keine Updates" gelten, sonst ginge fälschlich die Installationsmeldung raus
if ! SIM=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>&1); then
  echo "Simulation der Updates fehlgeschlagen:" >&2
  echo "$SIM" >&2
  exit 1
fi
mapfile -t UPDATES < <(
  awk '/^Inst / {
         pkg=$2
         old="-"
         if ($3 ~ /^\[/) { old=$3; gsub(/[\[\]]/, "", old); rest=4 } else { rest=3 }
         new=$rest; sub(/^\(/, "", new)
         src=$(rest+1)
         sec = (src ~ /security/) ? "S" : ""
         printf "%s|%s|%s|%s|%s\n", pkg, old, new, src, sec
       }' <<< "$SIM" | sort
)

REBOOT_REQUIRED=0
[[ -f /var/run/reboot-required ]] && REBOOT_REQUIRED=1

# --- Gemeinsame Bausteine für beide Meldungen -----------------------------------
FQDN=$(hostname -f 2>/dev/null || hostname)
OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-unbekannt}")
KERNEL=$(uname -r)
# Nur die IP der Schnittstelle mit Default-Route (keine Docker-/Bridge-Adressen)
IPS=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i=1; i<NF; i++) if ($i=="src") { print $(i+1); exit } }' || true)
[[ -z "$IPS" ]] && IPS=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
NOW=$(date '+%d.%m.%Y %H:%M')

plural() { if (( $1 == 1 )); then echo "$1 $2"; else echo "$1 $3"; fi; }  # plural <anzahl> <einzahl> <mehrzahl>

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

FONT="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#222222"
MONO="font-family:Consolas,Menlo,monospace;font-size:13px"
CELL="padding:5px 16px 5px 0;border-bottom:1px solid #dddddd;text-align:left;vertical-align:top"
HEAD="padding:5px 16px 5px 0;border-bottom:2px solid #999999;text-align:left"

info_text() {  # INFO-Zeilen "Bezeichner|Wert" als ausgerichteter Text
  # printf füllt nach Bytes auf; ${#label} zählt unter C.UTF-8 Zeichen, sonst verschieben Umlaute die Spalte
  local LC_ALL=C.UTF-8 row label
  for row in "${INFO[@]}"; do
    label="${row%%|*}:"
    printf '%s%*s%s\n' "$label" $(( 15 - ${#label} )) "" "${row#*|}"
  done
}

info_html() {
  local row
  echo "<table cellspacing=\"0\" cellpadding=\"0\" style=\"$FONT;border-collapse:collapse\">"
  for row in "${INFO[@]}"; do
    printf '<tr><td style="padding:2px 16px 2px 0;color:#666666">%s</td><td style="padding:2px 0">%s</td></tr>\n' \
      "$(html_escape <<< "${row%%|*}")" "$(html_escape <<< "${row#*|}")"
  done
  echo "</table>"
}

text_table() {  # stdin: Zeilen mit |-getrennten Spalten, erste Zeile = Kopf
  awk -F'|' 'NR==1 { print; u=$0; gsub(/[^|]/, "-", u); print u; next } { print }' |
  awk -F'|' '
    { for (i=1; i<=NF; i++) { cell[NR,i]=$i; if (length($i) > w[i]) w[i]=length($i) } n=NR; nf=(NF>nf?NF:nf) }
    END { for (r=1; r<=n; r++) { line=""; for (i=1; i<=nf; i++) line = line sprintf("%-" w[i]+2 "s", cell[r,i]); sub(/ +$/, "", line); print line } }'
}

html_table() {  # stdin wie text_table, bereits HTML-escaped; Spalten 2 und 3 in Festbreitenschrift
  echo "<table cellspacing=\"0\" cellpadding=\"0\" style=\"$FONT;border-collapse:collapse\">"
  awk -F'|' -v cell="$CELL" -v head="$HEAD" -v mono="$MONO" '
    NR==1 { printf "<tr>"; for (i=1; i<=NF; i++) printf "<th style=\"%s\">%s</th>", head, $i; print "</tr>"; next }
    { printf "<tr>"
      for (i=1; i<=NF; i++) printf "<td style=\"%s%s\">%s</td>", cell, (i==2 || i==3 ? ";" mono : ""), $i
      print "</tr>" }'
  echo "</table>"
}

encode_subject() {
  printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 -w0)"
}

MAIL_FILE=$(mktemp)
trap 'rm -f "$MAIL_FILE"' EXIT

send_mail() {  # nutzt SUBJECT, BODY, BODY_HTML, TOTAL, SEC_COUNT, optional REPLY_TO; setzt MSG_ID
  local boundary
  boundary="=_update-notify_$(date +%s)_$RANDOM"
  MSG_ID="<update-notify.$(date +%s).$RANDOM@$FQDN>"
  {
    echo "From: update-notify $HOST_LABEL <$MAIL_FROM>"
    echo "To: $MAIL_TO"
    echo "Subject: $(encode_subject "$SUBJECT")"
    echo "Date: $(LC_ALL=C date -R)"
    echo "Message-ID: $MSG_ID"
    if [[ -n "${REPLY_TO:-}" ]]; then
      echo "In-Reply-To: $REPLY_TO"
      echo "References: $REPLY_TO"
    fi
    echo "X-Update-Notify-Host: $HOST_LABEL"
    echo "X-Update-Notify-Count: $TOTAL"
    echo "X-Update-Notify-Security: $SEC_COUNT"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/alternative; boundary=\"$boundary\""
    echo
    echo "--$boundary"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    echo "$BODY"
    echo
    echo "--$boundary"
    echo "Content-Type: text/html; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    echo "$BODY_HTML"
    echo
    echo "--$boundary--"
  } > "$MAIL_FILE"

  if (( DRY_RUN )); then
    echo "=== Dry-Run, Betreff: $SUBJECT ==="
    cat "$MAIL_FILE"
    return 0
  fi

  local curl_args=(--silent --show-error --crlf --max-time 60
                   --mail-from "$MAIL_FROM" --upload-file "$MAIL_FILE")
  local rcpts r url
  IFS=',' read -ra rcpts <<< "$MAIL_TO"
  for r in "${rcpts[@]}"; do
    curl_args+=(--mail-rcpt "$(echo "$r" | xargs)")
  done

  case "$SMTP_TLS" in
    smtps)    url="smtps://$SMTP_HOST:$SMTP_PORT" ;;
    starttls) url="smtp://$SMTP_HOST:$SMTP_PORT"; curl_args+=(--ssl-reqd) ;;
    none)     url="smtp://$SMTP_HOST:$SMTP_PORT" ;;
    *) echo "SMTP_TLS muss none, starttls oder smtps sein" >&2; exit 1 ;;
  esac

  if [[ -n "$SMTP_USER" ]]; then curl_args+=(--user "$SMTP_USER:$SMTP_PASS"); fi

  curl "${curl_args[@]}" --url "$url"
}

# --- Keine Updates mehr offen: ggf. Installation melden --------------------------
if (( ${#UPDATES[@]} == 0 )); then
  # Nur Pakete mit geänderter Version zählen – zurückgezogene oder gesperrte Updates sind nicht installiert
  DONE=()
  if [[ -r "$LIST_FILE" ]]; then
    while IFS='|' read -r pkg old _; do
      cur=$(dpkg-query -W -f='${Version}\n' "$pkg" 2>/dev/null | head -n1 || true)
      if [[ "${cur:--}" != "$old" ]]; then DONE+=("$pkg|$old|${cur:--}"); fi
    done < "$LIST_FILE"
  fi

  if (( ${#DONE[@]} )); then
    TOTAL=0
    SEC_COUNT=0
    REPLY_TO=$(cat "$MSGID_FILE" 2>/dev/null || true)
    SUBJECT="$SUBJECT_PREFIX $HOST_LABEL: Updates installiert"
    if (( REBOOT_REQUIRED )); then SUBJECT+=" – Neustart ausstehend"; fi
    INFO=(
      "Host|$FQDN"
      "IP|${IPS:--}"
      "System|$OS_NAME"
      "Kernel|$KERNEL"
      "Geprüft am|$NOW"
      "Installiert|$(plural ${#DONE[@]} Paket Pakete), keine Updates mehr offen"
      "Neustart|$( (( REBOOT_REQUIRED )) && echo "ausstehend" || echo "nicht ausstehend")"
    )
    BODY=$(cat <<EOF
Auf $HOST_LABEL wurden die gemeldeten Updates installiert.

$(info_text)

$({ echo "Paket|Vorher|Jetzt"; printf '%s\n' "${DONE[@]}"; } | text_table)

--
Automatische Meldung von update-notify auf $HOST_LABEL
EOF
)
    BODY_HTML=$(cat <<EOF
<html><body style="$FONT">
<p style="font-size:16px"><b>Auf $(html_escape <<< "$HOST_LABEL") wurden die gemeldeten Updates installiert.</b></p>
$(info_html)
<p><b>Pakete</b></p>
$({ echo "Paket|Vorher|Jetzt"; printf '%s\n' "${DONE[@]}"; } | html_escape | html_table)
<p style="color:#888888;font-size:12px">Automatische Meldung von update-notify auf $(html_escape <<< "$HOST_LABEL")</p>
</body></html>
EOF
)
    send_mail
    (( DRY_RUN )) || echo "Gemeldet: $SUBJECT"
  fi

  # Zustand zurücksetzen, damit neue Updates wieder gemeldet werden
  (( DRY_RUN )) || rm -f "$HASH_FILE" "$LIST_FILE" "$MSGID_FILE"
  echo "Keine Updates verfügbar."
  exit 0
fi

# --- Änderungsprüfung ----------------------------------------------------------
NEW_HASH=$(printf '%s\n' "${UPDATES[@]}" | sha256sum | cut -d' ' -f1)
OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null || true)

if [[ "$NEW_HASH" == "$OLD_HASH" && $FORCE -eq 0 && $DRY_RUN -eq 0 ]]; then
  echo "Updates unverändert seit letzter Meldung – keine Mail."
  exit 0
fi

# --- Mailinhalt aufbauen -------------------------------------------------------
TOTAL=${#UPDATES[@]}
SEC_COUNT=$(printf '%s\n' "${UPDATES[@]}" | awk -F'|' '$5=="S"' | wc -l)

HELD=$(apt-mark showhold 2>/dev/null | xargs || true)

PKGS=$(printf '%s\n' "${UPDATES[@]}" | cut -d'|' -f1)
has_pkg() { grep -Eq "$1" <<< "$PKGS"; }

# Neustart nach dem Update?
REBOOT_AFTER=""
if has_pkg '^linux-image-'; then
  REBOOT_AFTER="nötig (Kernel-Update)"
elif has_pkg '^(libc6|systemd|dbus|libssl3(t64)?|openssl)$'; then
  REBOOT_AFTER="empfohlen ($(grep -E '^(libc6|systemd|dbus|libssl3(t64)?|openssl)$' <<< "$PKGS" | xargs | sed 's/ /, /g'))"
fi

# Dienste, die beim Update neu gestartet werden
HINTS=()
has_pkg '^(docker-ce|containerd\.io)$' && HINTS+=("Docker: Daemon startet neu – alle Container sind kurz nicht erreichbar")
has_pkg '^containerd$'                 && HINTS+=("containerd: Container-Runtime startet neu")
has_pkg '^nginx'                       && HINTS+=("nginx: Webserver wird neu gestartet")
has_pkg '^apache2$'                    && HINTS+=("Apache: Webserver wird neu gestartet")
has_pkg '^(mariadb-server|mysql-server)' && HINTS+=("MariaDB/MySQL: Datenbank wird neu gestartet")
has_pkg '^postgresql-[0-9]+$'          && HINTS+=("PostgreSQL: Datenbank wird neu gestartet")
has_pkg '^elasticsearch$'              && HINTS+=("Elasticsearch: Neustart, Suche kurz nicht verfügbar")
has_pkg '^zammad$'                     && HINTS+=("Zammad: Neustart inkl. Asset-Precompile (RAM-intensiv)")
has_pkg '^openssh-server$'             && HINTS+=("OpenSSH: sshd wird neu gestartet (bestehende Sitzungen bleiben)")

(( ${#HINTS[@]} )) || HINTS=("keine bekannten Dienst-Neustarts")
HINTS_TEXT=$(printf -- '- %s\n' "${HINTS[@]}")

SUBJECT="$SUBJECT_PREFIX $HOST_LABEL: $(plural "$TOTAL" Update Updates) verfügbar"
(( SEC_COUNT > 0 )) && SUBJECT+=" ($SEC_COUNT Sicherheit)"
if (( REBOOT_REQUIRED )); then
  SUBJECT+=" – Neustart ausstehend"
elif [[ "$REBOOT_AFTER" == nötig* ]]; then
  SUBJECT+=" – Neustart nötig"
fi

INFO=(
  "Host|$FQDN"
  "IP|${IPS:--}"
  "System|$OS_NAME"
  "Kernel|$KERNEL"
  "Geprüft am|$NOW"
  "Updates|$TOTAL, davon $(plural "$SEC_COUNT" Sicherheitsupdate Sicherheitsupdates)"
  "Neustart|$( (( REBOOT_REQUIRED )) && echo "bereits ausstehend (vor diesen Updates)" || echo "derzeit nicht ausstehend")"
  "Nach Update|Neustart ${REBOOT_AFTER:-nicht nötig}"
  "Gesperrt|${HELD:-keine}"
)
if [[ "$(self_state)" == veraltet ]]; then
  INFO+=("update-notify|neue Version verfügbar – einspielen mit: update-notify.sh --update")
fi

BODY=$(cat <<EOF
Auf $HOST_LABEL sind Updates verfügbar.

$(info_text)

Auswirkungen beim Update:
$HINTS_TEXT

$({ echo "Paket|Installiert|Neu|Sicherheit"
    printf '%s\n' "${UPDATES[@]}" | awk -F'|' '{ printf "%s|%s|%s|%s\n", $1, $2, $3, ($5=="S" ? "ja" : "") }'
  } | text_table)

--
Automatische Meldung von update-notify auf $HOST_LABEL
EOF
)

BODY_HTML=$(cat <<EOF
<html><body style="$FONT">
<p style="font-size:16px"><b>Auf $(html_escape <<< "$HOST_LABEL") $( (( TOTAL == 1 )) && echo ist || echo sind) $(plural "$TOTAL" Update Updates) verfügbar</b>, davon $(plural "$SEC_COUNT" Sicherheitsupdate Sicherheitsupdates).</p>
$(info_html)
<p><b>Auswirkungen beim Update</b></p>
<ul>
$(printf '%s\n' "${HINTS[@]}" | html_escape | sed 's|.*|<li>&</li>|')
</ul>
<p><b>Pakete</b></p>
$({ echo "Paket|Installiert|Neu|Art"
    printf '%s\n' "${UPDATES[@]}" | html_escape |
      awk -F'|' '{ printf "%s|%s|%s|%s\n", $1, $2, $3, ($5=="S" ? "<b style=\"color:#b3261e\">Sicherheit</b>" : "") }'
  } | html_table)
<p style="color:#888888;font-size:12px">Automatische Meldung von update-notify auf $(html_escape <<< "$HOST_LABEL")</p>
</body></html>
EOF
)

send_mail
(( DRY_RUN )) && exit 0

echo "$NEW_HASH" > "$HASH_FILE"
printf '%s\n' "${UPDATES[@]}" > "$LIST_FILE"
echo "$MSG_ID" > "$MSGID_FILE"
echo "Gemeldet: $SUBJECT"
