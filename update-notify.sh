#!/usr/bin/env bash
# update-notify.sh – meldet verfügbare APT-Updates per SMTP an Zammad
# Meldet nur, wenn sich die Liste der verfügbaren Updates seit der letzten Meldung geändert hat.
#
# Aufruf:  update-notify.sh            normaler Lauf (Timer)
#          update-notify.sh --force    meldet auch bei unveränderter Liste
#          update-notify.sh --dry-run  zeigt die Mail nur an, sendet nichts, speichert keinen Zustand

set -euo pipefail

CONF="/etc/update-notify.conf"
STATE_DIR="/var/lib/update-notify"
HASH_FILE="$STATE_DIR/last.hash"

FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
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

# --- Paketquellen aktualisieren -----------------------------------------------
if ! apt_err=$(apt-get update -qq 2>&1); then
  echo "apt-get update fehlgeschlagen:" >&2
  echo "$apt_err" >&2
  exit 1
fi

# --- Verfügbare Updates ermitteln (Simulation, ändert nichts) -----------------
# Format der Zeilen: Inst paket [altversion] (neuversion quelle [arch])
mapfile -t UPDATES < <(
  apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null |
  awk '/^Inst / {
         pkg=$2
         old="-"
         if ($3 ~ /^\[/) { old=$3; gsub(/[\[\]]/, "", old); rest=4 } else { rest=3 }
         new=$rest; sub(/^\(/, "", new)
         src=$(rest+1)
         sec = (src ~ /security/) ? "S" : ""
         printf "%s|%s|%s|%s|%s\n", pkg, old, new, src, sec
       }' | sort
)

REBOOT_REQUIRED=0
[[ -f /var/run/reboot-required ]] && REBOOT_REQUIRED=1

if (( ${#UPDATES[@]} == 0 )); then
  # Keine Updates: Zustand zurücksetzen, damit neue Updates wieder gemeldet werden
  (( DRY_RUN )) || rm -f "$HASH_FILE"
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

OS_NAME=$(. /etc/os-release && echo "${PRETTY_NAME:-unbekannt}")
KERNEL=$(uname -r)
# Nur die IP der Schnittstelle mit Default-Route (keine Docker-/Bridge-Adressen)
IPS=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i=1; i<NF; i++) if ($i=="src") { print $(i+1); exit } }' || true)
[[ -z "$IPS" ]] && IPS=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
HELD=$(apt-mark showhold 2>/dev/null | xargs || true)
NOW=$(date '+%d.%m.%Y %H:%M')

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

if (( ${#HINTS[@]} )); then
  HINTS_TEXT=$(printf -- '- %s\n' "${HINTS[@]}")
else
  HINTS_TEXT="- keine bekannten Dienst-Neustarts"
fi

SUBJECT="$SUBJECT_PREFIX $HOST_LABEL: $TOTAL Updates verfügbar"
(( SEC_COUNT > 0 )) && SUBJECT+=" ($SEC_COUNT Sicherheit)"
if (( REBOOT_REQUIRED )); then
  SUBJECT+=" – Neustart ausstehend"
elif [[ "$REBOOT_AFTER" == nötig* ]]; then
  SUBJECT+=" – Neustart nötig"
fi

TABLE=$(
  {
    echo "Paket|Installiert|Neu|Sicherheit"
    echo "-----|-----------|---|----------"
    printf '%s\n' "${UPDATES[@]}" | awk -F'|' '{ printf "%s|%s|%s|%s\n", $1, $2, $3, ($5=="S" ? "ja" : "") }'
  } | awk -F'|' '
      { for (i=1; i<=NF; i++) { cell[NR,i]=$i; if (length($i) > w[i]) w[i]=length($i) } n=NR; nf=(NF>nf?NF:nf) }
      END { for (r=1; r<=n; r++) { line=""; for (i=1; i<=nf; i++) line = line sprintf("%-" w[i]+2 "s", cell[r,i]); sub(/ +$/, "", line); print line } }'
)

BODY=$(cat <<EOF
Auf $HOST_LABEL sind Updates verfügbar.

Host:          $(hostname -f 2>/dev/null || hostname)
IP:            ${IPS:--}
System:        $OS_NAME
Kernel:        $KERNEL
Geprüft am:    $NOW
Updates:       $TOTAL, davon $SEC_COUNT Sicherheitsupdates
Neustart:      $( (( REBOOT_REQUIRED )) && echo "bereits ausstehend (vor diesen Updates)" || echo "derzeit nicht ausstehend")
Nach Update:   Neustart ${REBOOT_AFTER:-nicht nötig}
Gesperrt:      ${HELD:-keine}

Auswirkungen beim Update:
$HINTS_TEXT

$TABLE

--
Automatische Meldung von update-notify auf $HOST_LABEL
EOF
)

encode_subject() {
  printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 -w0)"
}

MAIL_FILE=$(mktemp)
trap 'rm -f "$MAIL_FILE"' EXIT

{
  echo "From: update-notify $HOST_LABEL <$MAIL_FROM>"
  echo "To: $MAIL_TO"
  echo "Subject: $(encode_subject "$SUBJECT")"
  echo "Date: $(LC_ALL=C date -R)"
  echo "Message-ID: <update-notify.$(date +%s).$RANDOM@$(hostname -f 2>/dev/null || hostname)>"
  echo "X-Update-Notify-Host: $HOST_LABEL"
  echo "X-Update-Notify-Count: $TOTAL"
  echo "X-Update-Notify-Security: $SEC_COUNT"
  echo "MIME-Version: 1.0"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo "Content-Transfer-Encoding: 8bit"
  echo
  echo "$BODY"
} > "$MAIL_FILE"

if (( DRY_RUN )); then
  echo "=== Dry-Run, Betreff: $SUBJECT ==="
  cat "$MAIL_FILE"
  exit 0
fi

# --- Versand per SMTP ----------------------------------------------------------
CURL_ARGS=(--silent --show-error --crlf --max-time 60
           --mail-from "$MAIL_FROM" --upload-file "$MAIL_FILE")

IFS=',' read -ra RCPTS <<< "$MAIL_TO"
for r in "${RCPTS[@]}"; do
  CURL_ARGS+=(--mail-rcpt "$(echo "$r" | xargs)")
done

case "$SMTP_TLS" in
  smtps)    URL="smtps://$SMTP_HOST:$SMTP_PORT" ;;
  starttls) URL="smtp://$SMTP_HOST:$SMTP_PORT"; CURL_ARGS+=(--ssl-reqd) ;;
  none)     URL="smtp://$SMTP_HOST:$SMTP_PORT" ;;
  *) echo "SMTP_TLS muss none, starttls oder smtps sein" >&2; exit 1 ;;
esac

[[ -n "$SMTP_USER" ]] && CURL_ARGS+=(--user "$SMTP_USER:$SMTP_PASS")

curl "${CURL_ARGS[@]}" --url "$URL"

echo "$NEW_HASH" > "$HASH_FILE"
echo "Gemeldet: $SUBJECT"
