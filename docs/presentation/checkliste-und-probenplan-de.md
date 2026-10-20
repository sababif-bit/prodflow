# Checkliste für den Präsentationstag und Probenplan 21.–25.10.2026

Stand: 20.10.2026 · Präsentation: **Montag, 26.10.2026** · Code-Freeze: **Freitag, 23.10.2026**. Alle Schritte, die die Produktion verändern (Zurücksetzen der Demo-Daten, Hold-Datei, Merge, Auslieferung), brauchen die ausdrückliche Freigabe des Projektverantwortlichen.
Keine Zugangsdaten in diesem Dokument; Passwörter nie anzeigen, nie in Chats oder Folien.

## 1. Preflight am Präsentationstag (ca. 25 Minuten, spätestens 60 Minuten vor Beginn)

### 1.1 Produktion (lesend)
| # | Prüfung | Befehl / Ort | Erwartet |
|---|---|---|---|
| 1 | Revision und Gesundheit | `curl -sS https://prodflow-farhad.duckdns.org/version` und `…/actuator/health` | Revision = `git ls-remote origin refs/heads/main`; `UP` |
| 2 | Verifikation von außen | `docker run --rm -v "<Repo>\scripts:/s:ro" alpine:3 sh -c "apk add -q bash curl jq && bash /s/verify-deployment.sh --app-url https://prodflow-farhad.duckdns.org --expect-revision <40-stelliger Commit> --expect-auth-url https://prodflow-auth-farhad.duckdns.org"` | `0 FAIL` (41 Prüfungen) |
| 3 | Zertifikate | im Container: `openssl s_client -connect <Host>:443 -servername <Host> -verify_return_error` beide Hosts | `Verification: OK`, Ablauf nach 16.01.2027 |
| 4 | Server | SSH: `free -m`, `docker ps`, `systemctl is-active prodflow-agent.timer`, `ls /var/lib/prodflow` | verfügbarer Speicher > 400 MB, alle Container up/healthy, Timer aktiv; Hold/failed siehe 1.3 |
| 5 | Anmeldung Planer/Einkäufer | je einmal in einem **eigenen** Browserprofil anmelden und wieder abmelden | beide laufen durch; keine Bearbeitung von Daten |
| 6 | GitHub | letzter Lauf auf `main` grün; offene PRs: nur der vorbereitete harmlose PR mit grünen Checks; Repository-Variable `PROD_APP_URL` gesetzt | – |
| 7 | AWS-Konsole | Instanz läuft, Security Group: nur 80/443 öffentlich, 22 nur eigene IP; Budget/Kosten ansehen | wie dokumentiert |

Optional: `scripts/smoke-auth.sh` auf dem Server (Runbook Abschnitt 5). Es erzeugt drei **absichtlich fehlgeschlagene** Anmeldungen im Keycloak-Protokoll (Platzhalter-Passwort-Test) und ändert keine Daten.

### 1.2 Demo-Daten
- **Zustand prüfen:** Übersicht „Aufträge gesamt: 0“, „Artikel: 5“; Bestand MR-200 0, SC-M8 25, PL-ST3 30, PR-40 50 m, BR-L60 100.
- **Wenn nicht im Ausgangszustand:** Zurücksetzen nach `docs/presentation/demo-skript-de.md`, Abschnitt 0.2 (Freigabe, Markierung `PRODFLOW_DEMO_RESET=allowed`, Trockenlauf, `--yes`). Stand 20.10.2026: Produktion **nicht** im Ausgangszustand; Zurücksetzen **nicht** durchgeführt.
- Nach dem Zurücksetzen **keine** Probe mehr in der Produktion, sonst ist der Zustand verbraucht (Demo erzeugt FA-00001).

### 1.3 Automatische Auslieferung während der Präsentation
| Variante | Wann | Maßnahme | Risiko |
|---|---|---|---|
| A (empfohlen ohne Live-Merge) | Kein Live-Merge geplant | Agent läuft; es darf bis zur Präsentation kein Merge auf `main` erfolgen (vorher prüfen: `prod` = laufende Revision) | gering |
| B (mit Live-Merge) | Vorbereiteter PR wird nach der Demo gemergt | Agent läuft; Merge erst **nach** Schritt 6 der Demo; während des Neustarts (ca. 30–40 s) nichts anklicken | Neustart sichtbar; Pipeline braucht ca. 5–6 Minuten |
| C (Absicherung) | Schutz vor ungewollter Auslieferung | `sudo touch /var/lib/prodflow/hold` kurz vor Beginn und nach der Präsentation mit `sudo rm` entfernen (nur mit Freigabe; **nicht** zusammen mit Variante B) | Hold vergessen → spätere Releases kommen nicht an |

### 1.4 Präsentationsrechner
- Offline-Videos (Geschäftsablauf, CI/CD) abspielbar **ohne** Netz; Folien als PDF-Kopie; Ersatzrechner/USB-Stick mit allen Dateien.
- Browserprofile: Fenster A normal, Fenster B privat; Zoom 125 %; Benachrichtigungen aus; Lesezeichen für App, Actions, `/version`.
- **Norton-Hinweis (dieser Laptop):** Das Antivirenprogramm ersetzt TLS-Zertifikate durch eigene („Norton Web/Mail Shield“). Zeigt der Browser dort „Zertifikat“, erscheint **nicht** Let's Encrypt. Für den Zertifikatsbeleg stattdessen die Ausgabe von `openssl s_client` aus einem Container,
  ein zweites Gerät oder ein Foto/Screenshot aus der Vorbereitung verwenden – oder die Web-Prüfung vorher bewusst abschalten.
- Strom, Adapter, Mikrofon, Bildschirmauflösung, Timer sichtbar (Uhr/Handy).
- Lokaler Notfallstack: `docker compose up --build` einmal am Vortag testen (Anwendung `http://localhost:8080`, Keycloak `http://localhost:8180`, Demo-Daten kommen mit dem Profil `demo`).

### 1.5 Go/No-Go (5 Minuten vor Beginn)
**GO:** Prüfungen 1–5 grün, Demo-Daten im Ausgangszustand, Videos starten, beide Anmeldungen getestet.
**NO-GO → Rückfall:** lokale Demo oder Videos + erklärende Folien; Cloud-Belege aus Beleg-Matrix und Screenshots (Abschnitt 3 in `folien-gliederung-de.md`) transparent als „Stand vom …“ kennzeichnen.

## 2. Probenplan 21.–25.10.2026

| Tag | Ziel | Aufgaben | Ausgang (Kriterium) |
|---|---|---|---|
| **Mi 21.10.** | Skript und Gerüst | Entscheidung Demo-Daten (deutsch/englisch); Freigaben holen (Zurücksetzen, ggf. Branch-Schutz); Produktion zurücksetzen; **Probe 1** (nur Demo, mit Stoppuhr, Schritt für Schritt); Folien-Gerüst (13 Folien) anlegen; Dokumentations-PR (dieser Stand) prüfen und mergen | Demo läuft ohne Abweichung; Zeit je Schritt notiert; Gerüst vollständig |
| **Do 22.10.** | Inhalt und Rückfall | Folien fertig (Entwurf); Videos aufnehmen (Geschäftsablauf, CI/CD, je ≤ 2 Minuten, **ohne** Passwörter im Bild); harmlosen PR vorbereiten; **Probe 2** komplett (Folien + Demo + Live-Merge), Pipeline-Dauer messen; Rückfall-Übung (Netz aus → Video) | Gesamtzeit ≤ 18 Minuten; Demo ≤ 8:30; Rückfall in ≤ 2 Minuten |
| **Fr 23.10.** | **Code-Freeze** | Nur Folien/Dokumentation; Produktion prüfen (Preflight 1.1); Datei-Sicherungen (USB + Cloud); keine Merges nach Freeze außer Notfall; Entscheidung Variante A/B/C aus 1.3 | Preflight grün; Freeze dokumentiert |
| **Sa 24.10.** | Sicherheit | **Probe 3** (optional, Rückfallfall zuerst: Produktion „ausgefallen“ → lokaler Stack); Fragenrunde laut `folien-gliederung-de.md`, Abschnitt 5 | Beide Pfade laufen |
| **So 25.10.** | Ruhen | Nur Folien-Durchlauf ohne Produktion; Checkliste ausdrucken; Geräte laden; kein Merge, kein Eingriff in die Produktion | Alles gepackt |
| **Mo 26.10.** | Präsentation | Preflight (Abschnitt 1), Zurücksetzen der Demo-Daten **falls nötig** (Freigabe vorab), Go/No-Go | – |

**Regeln für alle Proben:** Wer die Produktions-Demo probt, setzt danach zurück (Freigabe nötig) – oder probt gegen den lokalen Stack. Probe 1 und 2 in der Produktion verbrauchen jeweils den Ausgangszustand.
Nach Freeze gibt es keine Funktionsänderung mehr; Fehler, die nur die Folien betreffen, werden in den Folien gelöst.

## 3. Nach der Präsentation
- AWS-Ressourcen abbauen (GitHub Issue #13): Instanz beenden, öffentliche IP/Volumes/Snapshots löschen, DuckDNS-Einträge und serverbezogene GitHub-Einstellungen aufräumen, Endzustand im Devlog festhalten.
- Hold-Datei und Reset-Markierung sind danach gegenstandslos.
