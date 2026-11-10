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
- Meldet sich noch einmal, sobald die gemeldeten Updates installiert sind

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
| `/var/lib/update-notify/last.{hash,list,msgid}` | Zustand der letzten Meldung |
| `/usr/share/bash-completion/completions/update-notify.sh` | Tab-Vervollständigung für `--dry-run` und `--force` |

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

Die Optionen lassen sich mit Tab vervollständigen, wenn das Paket `bash-completion` installiert ist (`apt install bash-completion`, danach neu anmelden).

### Wann wird gemeldet?

| Situation | Mail? |
|---|---|
| Updates verfügbar, erstmals gesehen | ja |
| Dieselben Updates wie bei der letzten Meldung | nein |
| Neues Update oder neuere Version eines Pakets | ja, mit der vollständigen Liste |
| Teil der Updates installiert, Rest offen | ja, mit dem Rest |
| Alle gemeldeten Updates installiert | ja, „Updates installiert“ mit den Paketen und Versionen vorher/jetzt |
| Keine Updates, ohne dass sich eine Version geändert hat (z. B. Update zurückgezogen) | nein, Zustand wird zurückgesetzt |
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

### Meldung nach der Installation

Sind beim nächsten Lauf keine Updates mehr offen und haben sich Versionen der gemeldeten Pakete geändert, geht eine zweite Mail raus:

```
Betreff: [Linux-Updates] grov81: Updates installiert – Neustart ausstehend

Auf grov81 wurden die gemeldeten Updates installiert.

Host:          grov81.example.local
...
Installiert:   14 Pakete, keine Updates mehr offen
Neustart:      ausstehend

Paket              Vorher      Jetzt
-----              ------      -----
apt                3.0.3       3.0.4
linux-image-amd64  6.12.113-1  6.12.116-1
...
```

Die Mail kommt mit dem nächsten Timer-Lauf. Wer sie sofort möchte, ruft nach dem Einspielen `update-notify.sh` von Hand auf. Sie verweist per `In-Reply-To`/`References` auf die ursprüngliche Meldung, damit das Ticketsystem sie demselben Ticket zuordnen kann (in Zammad muss dafür die Follow-up-Erkennung über References aktiv sein).

Zusätzlich setzen beide Mails die Header `X-Update-Notify-Host`, `X-Update-Notify-Count` und `X-Update-Notify-Security` für Filter im Ticketsystem (bei der Installationsmeldung jeweils `0`).

### Zeitplan ändern

In `/etc/systemd/system/update-notify.timer` die Zeile `OnCalendar=` anpassen, dann `systemctl daemon-reload`.
