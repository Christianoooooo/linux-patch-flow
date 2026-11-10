# linux-patch-flow

Patch-Management für Debian-Server über das Ticketsystem: Verfügbare Updates werden erkannt und per Mail als Ticket gemeldet.

| Baustein | Status |
|---|---|
| **update-notify** – Updates erkennen und melden | ✅ fertig |
| Freigabe im Ticketsystem | geplant |
| Durchführung nach Freigabe, Ergebnis zurück ins Ticket | geplant |

## update-notify

Ein systemd-Timer prüft werktags um 06:30 (± 30 min), ob APT-Updates anstehen, und schickt eine Mail per SMTP, zum Beispiel an das Postfach des Ticketsystems.

- Reines Bash, benötigt nur `curl` (installiert der Installer bei Bedarf)
- Installiert nichts: die Prüfung läuft per `apt-get -s dist-upgrade` (Simulation)
- Meldet nur, wenn sich die Liste der Updates seit der letzten Meldung **geändert** hat, also kein tägliches Ticket mit demselben Inhalt
- Erkennt Sicherheitsupdates (Quelle `*-security`)
- Weist aus, ob nach dem Update ein Neustart nötig ist (Kernel) oder empfohlen wird (libc6, systemd, dbus, OpenSSL)
- Weist aus, welche Dienste beim Update neu starten (Docker, nginx, Apache, MariaDB/MySQL, PostgreSQL, Elasticsearch, Zammad, OpenSSH)

### Installation

Direkt aus GitHub:

```bash
wget -qO- https://raw.githubusercontent.com/Christianoooooo/linux-patch-flow/main/install.sh | sudo bash
```

Oder aus einem Klon:

```bash
git clone https://github.com/Christianoooooo/linux-patch-flow.git
cd linux-patch-flow && sudo ./install.sh
```

Der Installer legt ab:

| Datei | Zweck |
|---|---|
| `/usr/local/sbin/update-notify.sh` | Skript |
| `/etc/update-notify.conf` | Konfiguration (nur beim ersten Mal, wird nie überschrieben) |
| `/etc/systemd/system/update-notify.{service,timer}` | Zeitsteuerung |
| `/var/lib/update-notify/last.hash` | Zustand der letzten Meldung |

Für ein Update des Skripts den Installer einfach erneut ausführen.

### Konfiguration

`/etc/update-notify.conf` (Vorlage: [`update-notify.conf.example`](update-notify.conf.example)):

| Variable | Bedeutung |
|---|---|
| `SMTP_HOST`, `SMTP_PORT` | SMTP-Server oder Relay |
| `SMTP_TLS` | `none`, `starttls` oder `smtps` |
| `SMTP_USER`, `SMTP_PASS` | nur bei Authentifizierung |
| `MAIL_FROM`, `MAIL_TO` | Absender und Empfänger (mehrere mit Komma) |
| `SUBJECT_PREFIX` | Betreff-Präfix, Standard `[Linux-Updates]` |
| `HOST_LABEL` | Anzeigename des Servers, Standard `hostname -s` |

### Bedienung

```bash
update-notify.sh --dry-run   # Mail anzeigen, nichts senden, Zustand nicht ändern
update-notify.sh --force     # auch bei unveränderter Liste senden
update-notify.sh             # normaler Lauf (wie der Timer)
journalctl -u update-notify  # Protokoll
```

### Wann wird gemeldet?

| Situation | Mail? |
|---|---|
| Updates verfügbar, erstmals gesehen | ja |
| Dieselben Updates wie bei der letzten Meldung | nein |
| Neues Update oder neuere Version eines Pakets | ja, mit der vollständigen Liste |
| Teil der Updates installiert, Rest offen | ja, mit dem Rest |
| Keine Updates | nein, Zustand wird zurückgesetzt |
| Versand fehlgeschlagen | erneuter Versuch beim nächsten Lauf |

### Beispielmail

```
Betreff: [Linux-Updates] grov81: 14 Updates verfügbar (9 Sicherheit) – Neustart nötig

Auf grov81 sind Updates verfügbar.

Host:          grov81.example.local
IP:            10.10.70.81
System:        Debian GNU/Linux 13 (trixie)
Kernel:        6.12.113+deb13-amd64
Geprüft am:    10.11.2026 08:35
Updates:       14, davon 9 Sicherheitsupdates
Neustart:      derzeit nicht ausstehend
Nach Update:   Neustart nötig (Kernel-Update)
Gesperrt:      keine

Auswirkungen beim Update:
- Docker: Daemon startet neu – alle Container sind kurz nicht erreichbar

Paket                             Installiert                  Neu                          Sicherheit
-----                             -----------                  ---                          ----------
apt                               3.0.3                        3.0.4                        ja
docker-ce                         5:29.9.2-1~debian.13~trixie  5:29.9.3-1~debian.13~trixie
linux-image-amd64                 6.12.113-1                   6.12.116-1                   ja
...
```

Die Mail wird als `multipart/alternative` verschickt: Neben der Textfassung oben enthält sie eine HTML-Fassung mit echten Tabellen, damit die Spalten auch im Ticketsystem (Proportionalschrift) sauber ausgerichtet sind. Sicherheitsupdates sind dort farblich markiert.

Zusätzlich setzt die Mail die Header `X-Update-Notify-Host`, `X-Update-Notify-Count` und `X-Update-Notify-Security` für Filter im Ticketsystem.

### Zeitplan ändern

In `/etc/systemd/system/update-notify.timer` die Zeile `OnCalendar=` anpassen, dann `systemctl daemon-reload`.
