# Konzept: Sicherung und Wiederherstellung der PostgreSQL-Datenbanken (ENTWURF)

Stand: 20.10.2026 (S10B bis S10E-1). Auf dem Server ist **Skriptversion 1** installiert und wurde einmal ausgeführt (Satz `set-20261020T140124Z`); der Satz wurde auf den Laptop gezogen und dort **isoliert wiederhergestellt** (Abschnitt 14). **Nicht geübt** sind die Wiederherstellung in die Produktion und ein vollständiger Systemaufbau. Die in S10E-1 gehärtete **Version 2** der Skripte liegt nur lokal vor und ist nicht installiert. Test: Attrappen (68 Prüfungen) und echte Datenbankprobe (44 Prüfungen, Wegwerf-Container und -Schlüssel). Grundlage: Befunde der Prüfung S10A (lesend, 20.10.2026).
Verwandte Issues: #20 (Backups, Bonus), #22 (Wiederaufbau-Übung).

## 1. Ausgangslage (S10A, verifiziert)
- Zwei PostgreSQL-16.15-Container: Anwendung (`prodflow`, 7,9 MB, 5 Tabellen) und Keycloak (`keycloak`, 13 MB, 89 Tabellen). Beide auf Docker-Volumes auf **derselben** EBS-Root-Platte einer `t3.small` (12 GB frei, 556 MB Speicher verfügbar, 110 MB Swap).
- **Keine** Sicherung, **kein** Off-Instance-Exemplar, **keine** WAL-Archivierung (kein PITR), kein getesteter Restore. Keine IAM-Rolle und kein AWS-CLI auf der Instanz. EBS-Snapshots: unbekannt (nur in der Konsole prüfbar).
- Die Volumes überleben Deployments (`deploy.sh` entfernt nie Volumes). Die Daten der Anwendung sind Demo-Daten; der Ausgangszustand ist mit `scripts/reset-demo-data.sh` wiederherstellbar, der Keycloak-Realm aus `keycloak/prodflow-realm.json` plus Server-`.env`.

## 2. Zielbild (Architektur)
```
EC2 (nur root)                                                        Laptop (Git Bash, Docker Desktop)
┌───────────────────────────────────────────────────────────┐          ┌──────────────────────────────────────────────┐
│ backup-db.sh   (von Hand oder später per Timer)            │          │ fetch-backups.sh   ssh + sudo tar (Stream)  │
│  docker exec <db-container> pg_dump -Fc   (Leserechte)     │          │   → ~/prodflow-backups-enc/set-<UTC>/ (ausser-│
│        │ Strom                                              │  SSH     │     jedes Git-Repos), SHA256SUMS geprüft     │
│        ▼                                                    │ ───────► │                                              │
│  gpg --encrypt --recipient <öffentlicher Schlüssel>         │ (nur     │ restore-test.sh                              │
│        ▼ (Klartext berührt nie die Platte)                  │ Pull)    │   gpg --decrypt │ pg_restore  → Wegwerf-     │
│  /var/backups/prodflow/set-<UTC>/  (700, root)              │          │   Container (internes Netz, tmpfs, kein Port)│
│    app.dump.gpg  keycloak.dump.gpg  *.manifest  SHA256SUMS  │          │   Vergleich mit dem Manifest                 │
│    SET_OK | SET_FAILED                                      │          │ privater Schlüssel: NUR hier (+ Offline-Kopie)│
└───────────────────────────────────────────────────────────┘          └──────────────────────────────────────────────┘
```
**Kosten:** keine neuen AWS-Ressourcen. Optional ergänzend: ein EBS-Snapshot in der Konsole (siehe 12).

## 3. Entwurfsentscheidungen
| Thema | Entscheidung | Begründung |
|---|---|---|
| Format | `pg_dump -Fc -Z 6` je Datenbank, **im Container** ausgeführt (`docker exec`, lokaler Socket) | Kein Datenbankpasswort wird gelesen oder angezeigt; konsistenter Schnappschuss (MVCC), blockiert keine Schreibzugriffe; das Format erlaubt `pg_restore` mit Prüfung |
| Nur lesen | `PGOPTIONS=-c default_transaction_read_only=on` für alle Abfragen des Skripts; `pg_dump` liest ohnehin nur | Das Skript kann keine Daten ändern |
| Verschlüsselung | `gpg` mit **öffentlichem** Schlüssel, AES-256, während der Strom fließt | Der Server kann nicht entschlüsseln; der Klartext liegt nie auf der Platte; `gpg` ist auf Ubuntu vorhanden (keine Installation) |
| Schlüsselhygiene | Schlüsselbund auf dem Server enthält nur den öffentlichen Schlüssel; das Skript **bricht ab**, wenn dort ein privater Schlüssel liegt oder der öffentliche abgelaufen/widerrufen ist | Verhindert, dass ein Serverdiebstahl Backups lesbar macht |
| Speicherort | `/var/backups/prodflow` (700, root), Dateien 600, `umask 077`; verboten sind `/tmp`, `/var/lib/docker`, Pseudo-Dateisysteme | Nur root; nicht in Volumes, die ein `down -v` vernichten würde |
| Satz | ein Verzeichnis `set-<UTC-Zeitstempel>` je Lauf, zuerst als `.partial`, nach Prüfung atomar umbenannt; `SET_OK` oder `SET_FAILED` | Ein unvollständiger Satz kann nie als vollständig gelten |
| Manifest | `<name>.manifest` (Klartext `key=value`): Skriptversion, Satz, Datenbank, Container, Image-Id, PostgreSQL-Version, Größen, Flyway-Version, **genaue Tabellenzeilenzahlen**, Schlüssel-Fingerprint, SHA-256 der verschlüsselten Datei | Prüfwerte für den Restore-Test; enthält keine Geheimnisse |
| Prüfsummen | `SHA256SUMS` über alle Dateien des Satzes; Prüfung auf dem Laptop nach dem Download | Erkennt Übertragungs- und Speicherfehler |
| Übertragung | **Pull** vom Laptop: `ssh … sudo -n tar -cf - set-…`, die Ausgabe wird direkt in `tar -xf -` auf dem Laptop eingelesen | Kein Archiv auf dem Server, keine neuen Rechte, kein neuer Port, nichts auf dem Server wird gelöscht |
| Aufbewahrung | Server: die letzten 7 vollständigen Sätze (mindestens 2); Laptop: alles, optional `--keep-local N`; fehlgeschlagene Sätze nach 14 Tagen | Wenige MB je Satz; Server-Kopie ist nur Zwischenspeicher |
| Fehlerfälle | je Datenbank unabhängig; Zeitlimit; Prüfung auf leeren Dump und Empfänger-Paket; Sperre gegen Parallellauf; Exit-Codes 0/1/2/3 | Siehe Abschnitt 7 |
| Verworfen | S3 (IAM-Rolle, Bucket, Kosten); WAL-Archivierung/PITR (Container-Neustart, unverhältnismäßig bei 8–13 MB); symmetrische Verschlüsselung mit Server-Passwort | Siehe S10A |

## 4. Schlüsselverwaltung (einmalig, auf dem Laptop; umgesetzt in S10D-2a)
1. **Schlüsselpaar auf dem Laptop** (Git Bash, GnuPG 2.4): Hauptschlüssel `ed25519` (nur Zertifizieren) und Verschlüsselungs-Unterschlüssel `cv25519`, Laufzeit 3 Jahre, Benutzer-ID `ProdFlow Backup <adresse>`: `gpg --batch --pinentry-mode ask --quick-generate-key "ProdFlow Backup <adresse>" ed25519 cert 3y`, danach `gpg --batch --pinentry-mode ask --quick-add-key <Fingerprint> cv25519 encr 3y`. Die Passphrase wird nur im pinentry-Fenster eingegeben (nie in Skripten, Verlauf oder Protokollen). Als `RECIPIENT_FPR` dient der 40-stellige Fingerprint des **Hauptschlüssels**. Ohne `--batch --pinentry-mode ask` scheitert gpg in einer Shell ohne Terminal mit „cannot open 'no tty'“.
2. **Privaten Schlüssel offline sichern:** `gpg --batch --pinentry-mode ask --export-secret-keys --armor --output <Ziel>/prodflow-backup-private-PROTECTED.asc <Fingerprint>` auf einen USB-Stick, der getrennt vom Laptop aufbewahrt wird, dazu Widerrufszertifikat (liegt nach der Erzeugung in `~/.gnupg/openpgp-revocs.d/`), öffentlicher Schlüssel und eine `RECOVERY.txt` mit Fingerprint und Wiederherstellungsschritten (**ohne** Geheimnisse). Die Datei ist durch die Passphrase geschützt (S2K-Schutz geprüft); die Passphrase gehört nur in den Passwortmanager, **nie** auf den Stick. **Geht der private Schlüssel verloren, sind alle Backups unlesbar.**
3. **Wiederherstellungsübung** (in S10D-2a bestanden): Kopie in ein leeres Schlüsselbund importieren (`gpg --homedir <kurzer Pfad> --batch --pinentry-mode ask --import <Datei>`; der Agent verlangt dafür die Passphrase) und eine Testdatei entschlüsseln. Für ein eigenes `--homedir` einen **kurzen** Pfad wählen: bei langen Pfaden startet der gpg-Agent nicht (Grenze für Unix-Sockets).
4. **Nur den öffentlichen Schlüssel exportieren** (`gpg --export --armor <Fingerprint>`); er wird später (freigabepflichtig) auf dem Server in einen eigenen Schlüsselbund unter `/etc/prodflow-backup/gnupg` importiert. Vorab mit einem leeren „Server-Schlüsselbund“ geprüft: Import, Suche per Fingerprint, nicht abgelaufen, verschlüsselt, kann **nicht** entschlüsseln.
5. **Ablage:** Öffentlicher Schlüssel, `RECOVERY.txt` und alle Schlüsselkopien liegen **außerhalb dieses Repositories** (Laptop: `~/prodflow-backup-keys/`; Stick). Niemals committen.
6. **Rotation:** vor Ablauf (Oktober 2029) neuen Schlüssel erzeugen, auf dem Server austauschen, alte Backups mit dem alten privaten Schlüssel behalten. Optional zweiter Empfänger als Absicherung gegen Verlust. Bei Kompromittierung: Widerrufszertifikat importieren, neuen Schlüssel erzeugen, öffentlichen Schlüssel auf dem Server ersetzen, neues Backup ziehen.

## 5. Dateien und Rechte
| Pfad | Zweck | Rechte |
|---|---|---|
| `/etc/prodflow-backup/backup.conf` | Konfiguration (Vorlage `scripts/backup/backup.conf.example`; **keine Geheimnisse**) | root, 600 |
| `/etc/prodflow-backup/gnupg/` | Schlüsselbund nur mit öffentlichem Schlüssel | root, 700 |
| `/var/backups/prodflow/` | Sätze | root, 700 |
| `…/set-<UTC>/{app,keycloak}.dump.gpg`, `*.manifest`, `SHA256SUMS`, `SET_OK`/`SET_FAILED` | Inhalt eines Satzes | root, 600 |
| `~/prodflow-backups-enc/` (Laptop; Standardziel von `fetch-backups.sh`) | Kopien, außerhalb jedes Git-Repositories (das Skript verweigert sonst) | Benutzer |

Der Keycloak-Dump enthält Signaturschlüssel und Passwort-Hashes und ist **sensibler** als der Anwendungs-Dump; beide werden gleich behandelt (verschlüsselt, nur lokal entschlüsselt).

## 6. Betrieb
- **Auslöser (Empfehlung):** von Hand vor jedem riskanten Schritt (Zurücksetzen der Demo-Daten, Release mit neuer Flyway-Migration, Präsentation) und täglich vor 04:00 UTC in der Präsentationsphase. Ein systemd-Timer ist optional (Entwurf unten) und wäre eine Serveränderung.
- **Vor Releases mit Migration:** Ein Image-Rollback macht eine Schema-Migration **nicht** rückgängig (Flyway läuft vorwärts). Deshalb vorher `backup-db.sh --label pre-deploy` ausführen. Prüfung, ob ein Release Migrationen enthält: `git diff <alt> <neu> --stat -- backend/src/main/resources/db/migration`.
- **Nicht während einer Auslieferung** sichern: der Dump ist konsistent, hält aber kurz Sperren, die eine Migration verzögern könnten.
- **Alter prüfen:** `fetch-backups.sh` warnt, wenn der neueste Satz älter als 26 Stunden ist; in die Präsentations-Checkliste aufnehmen.

Optionaler Timer (NICHT installiert; Entwurf):
```
[Service]   Type=oneshot   Nice=19   IOSchedulingClass=idle   ExecStart=/usr/local/sbin/prodflow-backup-db.sh --label daily
[Timer]     OnCalendar=*-*-* 03:30:00 UTC   Persistent=true   RandomizedDelaySec=300
```

## 7. Fehlerbehandlung
| Situation | Verhalten |
|---|---|
| Voraussetzung nicht erfüllt (kein root, Schlüssel, falscher Container/Compose-Projekt, falsche Datenbank oder PostgreSQL-Hauptversion, zu wenig Platz, Konfiguration unsicher) | Abbruch, Exit 2, **nichts** geschrieben |
| Ein Dump scheitert oder ist leer/nicht verschlüsselt | Diese Datei wird gelöscht, die andere Datenbank wird trotzdem gesichert, Satz erhält `SET_FAILED`, Exit 1; fehlgeschlagene Sätze zählen nicht für die Aufbewahrung |
| Zweiter Lauf gleichzeitig | Exit 3 (Sperre `.lock`) |
| Abbruch mitten im Lauf | `.partial`-Verzeichnis bleibt, wird nie als Satz gewertet und nach einem Tag gelöscht; `.part`-Dateien werden aufgeräumt |
| Download unvollständig/verfälscht | `fetch-backups.sh` entfernt den Teilsatz, meldet Fehler (Exit 1) |
| Keine Alarmierung vorhanden | Ergebnis steht in Journal/Ausgabe (`logger -t prodflow-backup`); ohne Monitoring muss der Betreiber den Satz-Alter-Hinweis beachten |
Alle Meldungen enthalten keine Passwörter, Schlüssel oder Datenwerte.

## 8. Isolierter Restore-Test (Laptop, Wegwerf-Container)
`restore-test.sh --set ~/prodflow-backups-enc/set-<UTC>` prüft, dass sich ein Backup wirklich einspielen lässt und mit dem Manifest übereinstimmt.
1. **Schutz** (Abbruch Exit 2, bevor etwas angelegt wird): `DOCKER_HOST` gesetzt; Docker-Kontext nicht lokal; Rechnername oder Docker-Name wie eine AWS-Instanz (`ip-…`); `/opt/prodflow/repo/deploy/.env` vorhanden; Container `prodflow-prod-*` auf diesem Docker; Satz unvollständig oder `SHA256SUMS` falsch.
2. **Eigene Umgebung:** Netz `--internal` (kein Weg hinaus), je Datenbank ein Container `postgres:<Hauptversion aus dem Manifest>-alpine`, Daten auf `tmpfs`, zufälliges Passwort, **keine veröffentlichten Ports**, Label `pfrestore=<Lauf-Id>`.
3. **Einspielen:** `gpg --decrypt | pg_restore --exit-on-error --no-owner --no-privileges` (Klartext nur im Strom). Die Passphrase fragt der gpg-Agent über ein pinentry-Fenster ab (`gpg --batch --pinentry-mode ask`; ohne diese Option scheitert gpg in Umgebungen ohne Terminal mit „cannot open 'no tty'“). Die Passphrase läuft nie durch das Skript.
4. **Prüfung:** alle Tabellen aus dem Manifest vorhanden mit **identischer** Zeilenzahl (Keycloak: nur stabile Konfigurationstabellen streng, flüchtige wie `user_session` nur Info), Flyway-Version, Keycloak: Realm `prodflow`, Clients `prodflow-web`/`-api`/`-swagger`, Rollen `ADMIN`/`PLANNER`/`PURCHASER`. **Struktur (ab Version 2):** keine `NOT VALID`-Constraints, keine ungültigen Indizes, Sequenzwerte in ihren Grenzen, Anzahl der Constraints je Typ, Indizes und Sequenzen gleich dem Manifest (`struct.*`; bei älteren Sätzen entfällt nur der Manifestvergleich). Jeder Fehlschlag ergibt Exit 1.
5. **Aufräumen:** entfernt genau die Container mit dem Label und das Netz des Laufs (außer `--keep`). Gemessene Dauer = Eingabe für die RTO-Schätzung.
**Es gibt keinen Parameter, der ein Ziel auswählt.** Das Skript kann nur in den Container schreiben, den es selbst erzeugt hat. Eine Wiederherstellung in die Produktion ist **absichtlich nicht** Teil dieser Skripte (Abschnitt 9).

## 9. Echte Wiederherstellung in die Produktion (nur Runbook, jeder Schritt freigabepflichtig)
Grundsätze: nur aus einem **zuvor erfolgreich restore-getesteten** Satz; zuerst ein frischer Vorher-Dump (`--label pre-restore`); Anwendung stoppen (`docker compose stop backend`), damit niemand schreibt; zuerst in eine **neue** Datenbank einspielen, prüfen, dann umschalten; Bestätigung durch den Projektverantwortlichen vor dem Umschalten.
| Szenario | Vorgehen (Kurzform) | geschätzte Dauer |
|---|---|---|
| Versehentlich Daten gelöscht (Anwendung) | Satz auf dem Laptop in Wegwerf-Container einspielen, betroffene Zeilen exportieren und gezielt zurückspielen; nur wenn nötig die ganze Datenbank ersetzen (neue Datenbank, prüfen, umbenennen) | 20–40 Min |
| Fehlgeschlagenes Release | Image-Rollback (`DEPLOY_ROLLBACK_TO_BACKEND_ONLY`/Agent); nur bei Migration zusätzlich Datenbank aus dem `pre-deploy`-Satz | 10–40 Min |
| Container/Volume beschädigt | Container neu erzeugen (leeres Volume), Datenbank aus dem Satz einspielen, Backend starten | 15–30 Min |
| Instanz verloren | Neue Instanz mit `bootstrap-server.sh` (neue Geheimnisse), Datenbanken aus den Sätzen vom Laptop einspielen, Realm prüfen | 60–90 Min (Wiederaufbau ungeübt, Issue #22) |
| Keycloak-Datenbank verloren | Variante A: leere Datenbank, Realm-Import (`--import-realm`) mit denselben `.env`-Werten, Demo-Benutzer entstehen neu; Variante B: Dump einspielen (behält alle Änderungen) | 15–30 Min |
Die genauen Befehle werden erst in S10D geschrieben, nachdem der Restore-Test echte Daten bestanden hat.

## 10. Empfohlene Ziele (Empfehlung, keine Zusage)
| Ziel | Empfehlung | Anmerkung |
|---|---|---|
| RPO Anwendung/Keycloak | 24 h, plus Sicherung vor jedem riskanten Schritt | Bei reinen Demo-Daten genügt das; „Stand der letzten Probe“ |
| RTO Datenbank | ≤ 30 Min | Die Wiederherstellung dauert Sekunden bis Minuten, der Rest ist Vorgehen |
| RTO Instanz | ≤ 60 Min | Wiederaufbau noch nicht geübt |
| Restore-Test | nach dem ersten Backup und vor der Präsentation, danach wöchentlich | |

## 11. Ressourcenbewertung (t3.small)
| Größe | Wert | Art |
|---|---|---|
| Datenbanken | 7,9 MB und 13 MB (Verzeichnisse 47 und 68 MB inkl. WAL) | gemessen (S10A) |
| Verschlüsselte Dumps | ≈ 1 MB und 2–4 MB je Lauf; 7 Sätze ≈ < 50 MB | **Schätzung** |
| Laufzeit | wenige Sekunden je Datenbank | Schätzung |
| Speicher | `pg_dump` läuft im DB-Container (Limit 192 MB, Nutzung heute 31/23 MB) → einige MB zusätzlich; `gpg` und `docker exec` auf dem Host < 20 MB; Host hat 556 MB verfügbar | Schätzung |
| CPU/IO | wenige CPU-Sekunden; `nice`/`ionice` im Timer; T3-Guthaben unproblematisch | Schätzung |
| Platte | 12 GB frei; Mindestfreigrenze im Skript 1 GB | gemessen/konfiguriert |
| Netz | ≈ 5 MB je Pull über SSH | Schätzung |
Auswirkung auf den Live-Betrieb: vernachlässigbar; ein Lauf während einer Auslieferung ist zu vermeiden. **Alle Schätzungen sind erst mit einem echten Lauf (S10C) zu bestätigen.**

## 12. Sicherheitsrisiken und Gegenmaßnahmen
| Risiko | Gegenmaßnahme |
|---|---|
| Privater Schlüssel geht verloren (Backups unlesbar) | Offline-Kopie, Test-Entschlüsselung, optional zweiter Empfänger |
| Privater Schlüssel gelangt auf den Server | Skript bricht ab, solange dort ein geheimer Schlüssel liegt |
| Klartext-Dump auf Platte, in Logs oder Prozessliste | Verschlüsselung im Strom; kein Passwort wird verarbeitet; Manifeste ohne Werte; Skript-Test prüft, dass kein Klartext gefunden wird |
| Falscher Container (andere Umgebung) | Container-, Compose-Projekt-, Dienst-, Datenbank- und PostgreSQL-Versionsprüfung vor jedem Dump |
| Wiederherstellung trifft die Produktion | Restore-Skript ohne Zielparameter, nur eigene Wegwerf-Container, Schutzprüfungen (Abschnitt 8); echte Wiederherstellung nur als Runbook |
| Backup-Dateien gelangen ins Git | Zielverzeichnis außerhalb jedes Repositories (Prüfung), `.gitignore`-Hinweis, nur verschlüsselte Dateien |
| Beschädigte Sicherung unbemerkt | Prüfsummen, Manifest-Hash, Restore-Test; `data_checksums` der Datenbank bleiben aus (nicht änderbar ohne Neuinitialisierung) |
| Sicherung blockiert/verlangsamt Betrieb | Zeitlimit, `nice`, kleine Daten, nicht während Auslieferungen |
| Alle Kopien gehen gemeinsam verloren | Pull auf den Laptop; optional EBS-Snapshot (Konsole) und zweite Kopie (z. B. verschlüsselter USB-Stick) |
| Keycloak-Dump enthält Geheimnisse | wie Anwendungs-Dump verschlüsselt, strenger behandeln, nie unverschlüsselt weitergeben |

## 13. Künftige Produktionsoperationen (jede braucht eine ausdrückliche, getrennte Freigabe)
1. **Serverdateien anlegen:** `/etc/prodflow-backup/` (Konfiguration, öffentlicher Schlüssel, Schlüsselbund), `/var/backups/prodflow/` (700), Skript nach `/usr/local/sbin/` kopieren.
2. **Trockenlauf auf dem Server:** `sudo backup-db.sh --check` (liest nur; legt nichts an).
3. **Erster echter Backup-Lauf:** `sudo backup-db.sh --label first` (schreibt Dateien auf dem Server, liest die Datenbanken).
4. **Pull auf den Laptop:** `fetch-backups.sh` (liest per `sudo tar`).
5. **Restore-Test auf dem Laptop** (Wegwerf-Container lokal; Docker-Ausführung braucht die Freigabe nach `CLAUDE.md`).
6. Optional: systemd-Timer installieren/aktivieren (Serveränderung).
7. Optional: EBS-Snapshot/DLM in der AWS-Konsole (AWS-Änderung).
8. Optional: `deploy.sh`/Runbook-Schritt „Backup vor Release mit Migration“ (Skriptänderung per PR, wirkt auf jede künftige Auslieferung).
9. Echte Wiederherstellung (Abschnitt 9) – nur im Notfall.
**Stand 20.10.2026:** Die Operationen 1–5 wurden ausgeführt (S10D-2b/2c); offen sind 6–9 sowie Commit/Push/PR der Härtung und die Installation der Version 2 auf dem Server (Serveränderung).

## 14. Validierung (S10B bis S10E-1)
**Verifiziert (Datenbank-Wiederherstellung, isoliert):**
- **Echter Produktionslauf (S10D-2c-1, 20.10.2026):** `backup-db.sh --label first` (installierte Skriptversion 1) sicherte beide Datenbanken in 2 s: Satz `set-20261020T140124Z`, `SET_OK`, `SHA256SUMS` auf dem Server geprüft; Anwendung `app.dump.gpg` 16.663 B (5 Tabellen, 18 Zeilen, Flyway 100), Keycloak `keycloak.dump.gpg` 215.916 B (89 Tabellen, 1.550 Zeilen); beide für den Unterschlüssel des vorgesehenen Schlüssels verschlüsselt, kein Klartext auf dem Server. Pull mit `fetch-backups.sh` in 2 s, Hashes unabhängig gegen die Manifeste bestätigt.
- **Echter Restore-Test (S10D-2c-2, 20.10.2026):** `restore-test.sh` auf dem Laptop (Wegwerf-`postgres:16-alpine`, internes Netz, tmpfs, keine Ports): Entschlüsselung mit pinentry-Abfrage der Passphrase, beide Datenbanken eingespielt (**Anwendung 0,4 s, Keycloak 0,8 s**; gesamter Lauf 40 s einschließlich der Passphrase-Eingabe), alle Tabellen und Zeilenzahlen gleich dem Manifest, Flyway-Version 100, Keycloak-Realm `prodflow`, drei Clients, drei Rollen; anschließend nur die eigenen Container und das eigene Netz entfernt, Docker-Zustand identisch zu vorher. **Damit ist belegt: dieser Satz lässt sich in einer isolierten PostgreSQL-16-Umgebung wiederherstellen.**
- **Schlüssel (S10D-2a):** pinentry, Verschlüsseln mit dem öffentlichen Schlüssel, Entschlüsseln mit dem privaten (Text und Zufallsdatei, über eine Pipe wie in `restore-test.sh`), „Server-Schlüsselbund“ nur mit dem öffentlichen Schlüssel kann nicht entschlüsseln, Wiederherstellung des Schlüssels aus der Offline-Kopie.
- **Server (S10D-1/2b):** lesender Bereitschaftstest, Installation, `backup-db.sh --check` (Exit 0, beide Container und PostgreSQL 16.15 erkannt).

**Verifiziert (lokal, Skripte; S10E-1):**
- `scripts/test-backup-scripts.sh` (68 Prüfungen mit Attrappen, 1 übersprungen) und `scripts/test-backup-roundtrip.sh` (44 Prüfungen, echtes `pg_dump`/`pg_restore` in Wegwerf-Containern mit synthetischen Daten und Wegwerf-Schlüsseln; der Docker-Kontext wird zuerst geprüft, nur eigene Ressourcen werden entfernt). Neu in S10E-1 (Skriptversion 2):
  - **Flyway-Abfrage:** Die Tabelle wird in einer **eigenen** Abfrage gesucht. Die frühere Einzelabfrage nannte `flyway_schema_history` in einem nie ausgeführten `CASE`-Zweig; PostgreSQL löst Tabellennamen aber beim Analysieren auf und meldete bei Keycloak (ohne Flyway) `relation "flyway_schema_history" does not exist` (harmlos, weil ein Rückfallwert den Fehler verdeckte, aber laut und gefährlich, weil er auch echte Fehler verdeckte). Jetzt: Keycloak behält `flyway_latest=` leer, die Anwendung meldet weiter ihre Version, und ein **echter** Fehler bei der Abfrage lässt die betroffene Datenbank scheitern.
  - **Lock-Datei:** `umask 077` steht jetzt **vor** dem Anlegen von `.lock` (früher danach, daher Modus 644), und eine vorhandene Lock-Datei (Modus 644 aus Version 1) wird auf 600 gesetzt. Pfad und `flock`-Verhalten sind unverändert. Der Test des tatsächlichen Dateimodus wird auf Dateisystemen ohne Modus-Unterstützung (Windows-Temp-Verzeichnis) **übersprungen**; dort prüft nur die Reihenfolge-Prüfung im Quelltext.
  - **Struktur im Manifest (`struct.*`):** Anzahl der Constraints je Typ, der Indizes und der Sequenzen.
  - **Struktur im Restore-Test:** keine `NOT VALID`-Constraints, keine ungültigen oder nicht bereiten Indizes, Sequenzwerte innerhalb ihrer Grenzen; bei Sätzen der Version 2 außerdem Constraint-, Index- und Sequenzanzahl gegen das Manifest. Alle Abfragen lesen nur den Katalog, es werden keine Tabellenwerte angezeigt. Eine Sequenz **hinter** dem Maximum ihrer Spalte wird nur als Info gemeldet (ein Einfügen mit expliziten IDs ist erlaubt). Sätze der Version 1 (wie `set-20261020T140124Z`) haben keine `struct.*`-Zeilen und werden mit den immer geltenden Prüfungen weiter unterstützt.
  - **Regressionstests:** mit und ohne Flyway-Tabelle (die Attrappe verhält sich wie PostgreSQL und scheitert bei jeder Abfrage, die die fehlende Tabelle nennt), Lock-Datei, alle Strukturfehler, ein echtes `NOT VALID`-Constraint über Dump und Restore, unabhängig abgeleitete Struktur gegen Manifest und Restore. Die neuen Tests scheitern an den alten Skripten genau an den behobenen Stellen. Die echte Datenbank fand dabei einen Fehler der neuen Abfrage (`unknown || "char"`, behoben mit `::text`), den die Attrappe nicht zeigen konnte.
- **Kompatibilität:** Die auf dem Server **installierte** Version 1 wurde nicht verändert. Die Version 2 ist ein Ersatz mit gleicher Konfiguration, gleichen Pfaden, Exit-Codes und gleichem Satzaufbau; ihre Installation ist eine eigene, freigabepflichtige Serveränderung. Der neue `restore-test.sh` verarbeitet Sätze beider Versionen.

**Nicht verifiziert / Grenzen:**
- **Vollständige Systemwiederherstellung:** Es wurde **keine** Anwendung gegen die wiederhergestellten Daten gestartet; die Wiederherstellung in die Produktion (Abschnitt 9) ist nicht geschrieben und nicht geübt. Verifiziert ist nur: Sicherung, Übertragung und Einspielen in eine isolierte PostgreSQL-16-Umgebung.
- **Kein Wiederaufbau der AWS-Infrastruktur geübt** (Issue #22); die Zeitangabe für „Instanz verloren“ ist eine Schätzung.
- **Keine automatische Sicherung:** kein Timer; es gibt nur den von Hand erzeugten Satz vom 20.10.2026 (Server und Laptop).
- **EBS-Snapshot-Status unbekannt** (nur in der AWS-Konsole prüfbar).
- **Ausstehender Neustart des Servers** (Kernel-Update); nicht durchgeführt, Entscheidung offen.
- **Alter Klartext-Dump** `~/prodflow-backups/keycloak-db_keycloak_20261016-104556Z.dump` (Laptop, unverschlüsselt, vermutlich aus der lokalen Entwicklungsumgebung): Entscheidung über Aufbewahrung oder Löschung steht aus; Inhalt wurde nie geöffnet.
- **Nicht in der CI:** die Backup-Tests laufen nicht in GitHub Actions (der Integrationstest braucht Docker und ein lokales `postgres:16-alpine`).
- **Schlüsselverwahrung:** der Schlüssel und die Passphrase liegen allein in der Verantwortung des Betreibers (Abschnitt 4); ohne beide sind alle Sätze unlesbar.

## 15. Nächste Schritte (jeweils nach Freigabe)
1. ~~Entwürfe prüfen und lokal committen~~ (S10D-2b-0, Commit `b889ffe`). ~~Lokale Echtprobe~~ (S10C). ~~Schlüssel erzeugen, Offline-Kopie~~ (S10D-2a). ~~Server einrichten, `--check`~~ (S10D-2b). ~~Erster Lauf, Pull, isolierter Restore-Test~~ (S10D-2c).
2. Härtung (S10E-1, lokal): Version 2 der Skripte und Tests wie in Abschnitt 14; **noch nicht committet und nicht auf dem Server installiert**.
3. Entscheidungen: Version 2 auf dem Server installieren (Serveränderung), Timer ja/nein, EBS-Snapshot ja/nein, Sicherung vor Releases mit Migration, ausstehender Neustart, alter Klartext-Dump.
4. Runbook für die echte Wiederherstellung (Abschnitt 9) mit den gemessenen Werten schreiben und üben; Präsentations-Checkliste um „Alter des neuesten Satzes“ ergänzen.
