#!/usr/bin/env bash
# install.sh – installiert oder aktualisiert update-notify aus linux-patch-flow
#
# Aus einem geklonten Repo:   sudo ./install.sh
# Direkt aus GitHub:          wget -qO- https://raw.githubusercontent.com/Christianoooooo/linux-patch-flow/main/install.sh | sudo bash
#
# Optional:
#   BRANCH=dev        anderen Branch installieren (Standard: main)
#   GITHUB_TOKEN=...  falls das Repo privat ist
#
# Eine vorhandene /etc/update-notify.conf wird nie überschrieben.

set -euo pipefail

REPO="Christianoooooo/linux-patch-flow"
BRANCH="${BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen" >&2; exit 1; }

if ! command -v curl >/dev/null; then
  echo "Installiere curl ..."
  apt-get install -y -qq curl
fi

if [[ ! -f /usr/share/bash-completion/bash_completion ]]; then
  echo "Installiere bash-completion ..."
  apt-get install -y -qq bash-completion
fi

# Quelle: lokales Repo (wenn install.sh daneben liegt) oder GitHub
SRC_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$candidate/update-notify.sh" ]] && SRC_DIR="$candidate"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fetch() {  # fetch <pfad im repo> <ziel>
  if [[ -n "$SRC_DIR" ]]; then
    cp "$SRC_DIR/$1" "$2"
  else
    local auth=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: token $GITHUB_TOKEN")
    curl -fsSL "${auth[@]}" "$RAW_BASE/$1" -o "$2" \
      || { echo "Download fehlgeschlagen: $RAW_BASE/$1" >&2; exit 1; }
  fi
}

if [[ -n "$SRC_DIR" ]]; then
  echo "Installiere aus lokalem Repo: $SRC_DIR"
else
  # Commit-SHA statt Branchname: der Branch wird von raw.githubusercontent.com bis zu 5 Minuten veraltet ausgeliefert
  auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: token $GITHUB_TOKEN")
  sha=$(curl -fsSL --max-time 10 "${auth[@]}" -H "Accept: application/vnd.github.sha" \
    "https://api.github.com/repos/$REPO/commits/$BRANCH" 2>/dev/null || true)
  if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    RAW_BASE="https://raw.githubusercontent.com/$REPO/$sha"
    echo "Installiere aus GitHub: $REPO ($BRANCH, Commit ${sha:0:7})"
  else
    echo "Installiere aus GitHub: $REPO ($BRANCH)"
  fi
fi

fetch update-notify.sh              "$TMP/update-notify.sh"
fetch update-notify.conf.example    "$TMP/update-notify.conf.example"
fetch systemd/update-notify.service "$TMP/update-notify.service"
fetch systemd/update-notify.timer   "$TMP/update-notify.timer"
fetch systemd/update-notify.path    "$TMP/update-notify.path"
fetch completion/update-notify.sh   "$TMP/update-notify.completion"

bash -n "$TMP/update-notify.sh" || { echo "update-notify.sh fehlerhaft, Abbruch" >&2; exit 1; }

install -m 750 "$TMP/update-notify.sh"      /usr/local/sbin/update-notify.sh
install -m 644 "$TMP/update-notify.service" /etc/systemd/system/update-notify.service
install -m 644 "$TMP/update-notify.timer"   /etc/systemd/system/update-notify.timer
install -m 644 "$TMP/update-notify.path"    /etc/systemd/system/update-notify.path
install -D -m 644 "$TMP/update-notify.completion" /usr/share/bash-completion/completions/update-notify.sh

if [[ -e /etc/update-notify.conf ]]; then
  echo "/etc/update-notify.conf existiert bereits – bleibt unverändert."
  NEW_CONF=0
else
  install -m 600 "$TMP/update-notify.conf.example" /etc/update-notify.conf
  echo "Konfiguration angelegt: /etc/update-notify.conf"
  NEW_CONF=1
fi

# Installierten Commit merken, damit --update erkennt, ob es etwas zu tun gibt
install -d -m 700 /var/lib/update-notify
if [[ "${sha:-}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "$sha" > /var/lib/update-notify/installed.commit
else
  rm -f /var/lib/update-notify/installed.commit
fi

systemctl daemon-reload
systemctl enable --now update-notify.timer update-notify.path

echo
echo "Fertig."
if (( NEW_CONF )); then
  echo "Nächste Schritte:"
  echo "  nano /etc/update-notify.conf     # SMTP und Empfänger eintragen"
  echo "  update-notify.sh --dry-run       # Mail anzeigen, nichts senden"
  echo "  update-notify.sh --force         # Testmail senden"
fi
systemctl list-timers update-notify.timer --no-pager
