# Demo-Skript ProdFlow – Live-Demo (ca. 8 Minuten)

Stand: 20.10.2026. Nur Funktionen, die es **heute** gibt: Oberfläche (Angular), Planer und Einkäufer, einstufige Stückliste. Alle Zahlen gelten für den **Ausgangszustand** der Demo-Daten (siehe 0.2).
Keine Zugangsdaten in diesem Dokument: die Passwörter der Demo-Benutzer stehen nur in der Server-`.env` und werden vor der Präsentation aus einem Passwortmanager/offline Zettel geholt.

## 0. Vorbereitung (nicht Teil der 8 Minuten)

### 0.1 Fenster und Tabs
| Fenster | Inhalt |
|---|---|
| A (normales Fenster) | `https://prodflow-farhad.duckdns.org` (Planer) |
| B (**privates** Fenster, eigene Sitzung) | dieselbe Adresse, später Einkäufer (zwei Rollen gleichzeitig, ohne ständiges Aus- und Einloggen) |
| C | GitHub Actions: letzter Lauf auf `main` (grün) · `https://prodflow-farhad.duckdns.org/version` · GHCR-Paketseite |
| Backup | Offline-Videos „Geschäftsablauf“ und „CI/CD“, lokaler Stack (`docker compose up`) |

Zoom 125 %, Benachrichtigungen aus, Passwörter nicht anzeigen (Anmeldemaske zeigt sie nur als Punkte).

### 0.2 Ausgangszustand der Demo-Daten (Voraussetzung, **nicht** ausgeführt)
**Stand der Produktion am 20.10.2026: nicht im Ausgangszustand.** Es gibt FA-00001 bis FA-00003, drei Bestellanforderungen (eine offen) und den Test-Artikel `TEST-MAT-001`, der Bestand von SC-M8 ist 0.
Das Skript unten funktioniert nur nach einem Zurücksetzen. Das Zurücksetzen **leert alle Anwendungstabellen** (Artikel, Stücklisten, Aufträge, Bestellanforderungen), lädt den festen Datensatz neu und
ändert **nie** Keycloak. Es braucht eine ausdrückliche Freigabe und ist **noch nicht durchgeführt**:

1. Freigabe des Projektverantwortlichen für das Zurücksetzen der Produktions-Demodaten.
2. Auf dem Server fehlt die Markierung `PRODFLOW_DEMO_RESET=allowed` in `deploy/.env` (eine Dateiänderung auf dem Server, ebenfalls freigabepflichtig).
3. Trockenlauf: `cd /opt/prodflow/repo && sudo scripts/reset-demo-data.sh --project prodflow-prod --env-file deploy/.env --dry-run` (zeigt Ziel und Plan, ändert nichts).
4. Ausführung erst nach dem Trockenlauf mit `--yes`; das Skript prüft den Ausgangszustand in derselben Transaktion und bricht sonst ab.
5. Kontrolle in der Oberfläche: Übersicht zeigt „Aufträge gesamt: 0“, „Artikel: 5“; Bestand: MR-200 0, SC-M8 25, PL-ST3 30, PR-40 50 m, BR-L60 100.
6. Danach vor jeder Probe/Aufführung erneut zurücksetzen (die Demo **verbraucht** den Ausgangszustand). Optional automatische Gegenprobe: `scripts/demo-run.sh` (verbraucht den Zustand ebenfalls).

Lokale Rückfallebene: `docker compose up --build` erzeugt den Ausgangszustand selbst (Profil `demo`); Anmeldung über `http://localhost:8180`, Anwendung `http://localhost:8080`.

### 0.3 Rechnung zur Kontrolle (Auftrag 10 × MR-200)
Stückliste je Stück: SC-M8 4, PL-ST3 2, PR-40 3,5 m, BR-L60 8 → Bedarf 40 / 20 / 35 m / 80. Bestand 25 / 30 / 50 / 100 → **Fehlmenge nur bei SC-M8: 15 Stück**.
Endbestand nach dem Abschluss: MR-200 10, SC-M8 0 (25 + 15 − 40), PL-ST3 10, PR-40 15 m, BR-L60 20.

## 1. Ablauf mit Zeitplan

| Zeit | Schritt | Rolle |
|---|---|---|
| 0:00–1:00 | 1. Anmeldung und Übersicht | Planer |
| 1:00–2:15 | 2. Bestand und einstufige Stückliste | Planer |
| 2:15–3:45 | 3. Auftrag 10 × MR-200 anlegen, Fehlmenge | Planer |
| 3:45–4:30 | 4. Funktionstrennung | Planer |
| 4:30–6:00 | 5. Genehmigen und Wareneingang | Einkäufer |
| 6:00–7:00 | 6. Automatische Freigabe, Abschluss, Endbestand | Planer |
| 7:00–8:00 | 7. Belege: CI/CD, AWS, Docker, Sicherheit | – |

### Schritt 1 – Anmeldung und Übersicht (Fenster A, Planer)
**Klicks:** Adresse öffnen → Keycloak-Anmeldemaske (andere Domain `prodflow-auth-farhad.duckdns.org`, Schloss zeigen) → Benutzer `planner`, Passwort → Übersicht.
**Erwartet:** Übersicht mit Kacheln „Aufträge gesamt 0“, „Wartet auf Material 0“, „Freigegeben 0“, „Abgeschlossen 0“, „Offene Bestellanforderungen 0“, „Artikel 5“; oben rechts Name und Chip „Planer“.
**Sagen:** „Das ist ProdFlow. Die Anwendung beantwortet eine Frage: Können wir diesen Auftrag fertigen – und wenn nicht, was müssen wir einkaufen? Die Anmeldung läuft über Keycloak mit Authorization-Code-Flow und PKCE:
das Passwort sieht nur Keycloak, die Anwendung bekommt ein kurzlebiges Token, das nur im Speicher liegt. Alle Zahlen hier kommen live aus der Datenbank, nichts ist vorgerechnet.“

### Schritt 2 – Bestand und einstufige Stückliste (Planer)
**Klicks:** Navigation „Bestand & Artikel“ → Liste mit fünf Artikeln („5 von 5 Artikeln“) → Link **MR-200**.
**Erwartet:** Detailseite MR-200 (Fertigprodukt), Bereich „Stückliste“ mit dem Hinweis „Einstufige Stückliste …“, vier Komponenten mit „Menge je Stück“ (4 / 2 / 3,5 / 8), Anzeige **„6 Stück (begrenzt durch SC-M8)“**.
**Sagen:** „Ein Rahmen besteht aus vier Materialien. Aus dem heutigen Bestand könnten wir sechs Rahmen bauen; die Schrauben begrenzen. Wichtig und ehrlich: Das System löst genau **eine** Stücklistenebene auf. Mehrstufige
Baugruppen sind vorbereitet, aber nicht umgesetzt – deshalb steht das auch so auf dem Bildschirm.“

### Schritt 3 – Auftrag über 10 Rahmen anlegen (Planer)
**Klicks:** Navigation „Fertigungsaufträge“ → Schaltfläche **„Neuer Auftrag“** → Dialog „Neuen Fertigungsauftrag anlegen“: Produkt **MR-200** wählen, Menge **10**, Fälligkeitsdatum belassen → **„Anlegen und Material prüfen“**.
**Erwartet:** Dialog „Materialprüfung · FA-00001“, Ergebnis **„Wartet auf Material“**, Hinweis „Bei 1 Material fehlt Bestand. Das System hat eine Bestellanforderung angelegt.“; Tabelle: SC-M8 benötigt 40, vorhanden 25, **Fehlmenge 15**, neu angefordert 15;
die anderen drei Materialien ohne Fehlmenge („–“). Toast „Auftrag angelegt – Es fehlt Material – siehe Materialprüfung.“ → **„Schließen“**; in der Liste FA-00001 mit Status „Wartet auf Material“.
**Sagen:** „Das System multipliziert die Stückliste mit der Menge und vergleicht mit dem Lager: 40 Schrauben nötig, 25 da. Der Auftrag wartet, und es entsteht automatisch genau **eine** Bestellanforderung über die Fehlmenge von 15.“
**Optional (20 s):** In der Zeile **„Material prüfen“** → Meldung „Die Fehlmenge ist bereits durch offene Bestellanforderungen abgedeckt.“ – „Die Prüfung ist idempotent: Wiederholen erzeugt keine Doppelbestellung.“

### Schritt 4 – Funktionstrennung (Planer)
**Klicks:** Navigation „Bestellanforderungen“.
**Erwartet:** Nr. 1, SC-M8, 15 pcs, Status **„Offen“**, Auftrag FA-00001; **keine** Schaltflächen „Genehmigen“/„Wareneingang buchen“; Hinweis „Funktionstrennung: Genehmigung und Wareneingang sind dem Einkauf vorbehalten. …“.
**Sagen:** „Wer plant, darf nicht einkaufen. Das erzwingt nicht die Oberfläche, sondern das Backend: ein Planer-Token bekommt auf diese Aktion ein 403. Die Oberfläche zeigt nur, was die Rolle darf.“
**Optional (30 s, Beleg):** Im Terminal `curl -s -o /dev/null -w "%{http_code}\n" https://prodflow-farhad.duckdns.org/api/items` → **401** („ohne Token kommt man nirgends hinein“).

### Schritt 5 – Einkäufer genehmigt und bucht den Wareneingang (Fenster B, privat)
**Klicks:** Fenster B: Adresse öffnen → Benutzer `purchaser` → „Bestellanforderungen“ → in der Zeile Nr. 1 **„Genehmigen“** → Bestätigungsdialog „Bestellanforderung genehmigen?“ → **„Genehmigen“** →
danach **„Wareneingang buchen“** → Dialog „Wareneingang buchen?“ → **„Wareneingang buchen“**.
**Erwartet:** Toast „Nr. 1 genehmigt – Der Wareneingang kann jetzt gebucht werden.“, Status „Genehmigt“; dann Toast „Nr. 1: Wareneingang gebucht – Bestand erhöht; wartende Aufträge wurden vom System neu geprüft.“, Status **„Wareneingang gebucht“**.
Der Einkäufer sieht bei „Fertigungsaufträge“ **keinen** Knopf „Neuer Auftrag“.
**Sagen:** „Jetzt die andere Rolle, in einer eigenen Sitzung. Der Einkäufer genehmigt und bucht die 15 Schrauben ein. Dabei prüft das System alle wartenden Aufträge **selbst** neu – niemand muss daran denken.“

### Schritt 6 – Automatische Freigabe, Abschluss, Endbestand (Fenster A, Planer)
**Klicks:** Fenster A → „Fertigungsaufträge“ → ggf. **„Aktualisieren“** → FA-00001 steht auf **„Freigegeben“** → **„Abschließen“** → Dialog „Auftrag abschließen?“ → **„Abschließen“** → „Bestand & Artikel“ → „Übersicht“.
**Erwartet:** Toast „FA-00001 abgeschlossen – Der Bestand wurde gebucht.“, Status „Abgeschlossen“; Bestand **MR-200 10, SC-M8 0, PL-ST3 10, PR-40 15 m, BR-L60 20**; Übersicht „Abgeschlossen 1“, „Material ohne Bestand 1“ (SC-M8).
**Sagen:** „Der Auftrag wurde vom System freigegeben, sobald das Material da war. Der Planer schließt ab: Das Material wird verbraucht, die zehn Rahmen eingebucht. Der Bestand ist nachvollziehbar und kann nie negativ werden.“

### Schritt 7 – Belege für Cloud und DevOps (Fenster C)
**Klicks/Zeigen (je 20–30 s):**
1. GitHub Actions, letzter Lauf auf `main`: Jobs `test`, `frontend`, `ops`, `build`, `verify` grün. **Sagen:** „Jede Änderung läuft durch Tests; erst dann entsteht ein Container-Image.“
2. GHCR/`/version`: `https://prodflow-farhad.duckdns.org/version` zeigt den Commit, der als `sha-…`-Tag im Image steckt. **Sagen:** „Der Verify-Job prüft von außen, dass genau dieser Commit läuft.“
3. Folie Architektur: ein Server, Docker Compose, Caddy mit HTTPS, Keycloak getrennt, Datenbanken nur im Docker-Netz. **Sagen:** „Ein Image enthält Oberfläche und Backend. Der Server holt neue Versionen selbst (pull), prüft Gesundheit **und** Anwendung und rollt bei Fehlern zurück.“
4. Sicherheit: HTTPS-Zertifikate (Let's Encrypt), CSP, nur 80/443 offen, Admin-Konsole nur per SSH-Tunnel, Geheimnisse nur auf dem Server. Belege: `verify-deployment.sh` 41/41, `smoke-auth.sh` 38/38.

## 2. Was nicht gezeigt wird (und warum)
- Kein Merge und keine Auslieferung während der Geschäftsdemo: Eine Auslieferung unterbricht die Anwendung etwa 30 Sekunden. Falls der Merge live gezeigt wird, dann **erst nach** Schritt 6 (siehe `docs/presentation/folien-gliederung-de.md`).
- Keine Pflege von Artikeln oder Stücklistenpositionen in der Oberfläche (nur über die API, nicht umgesetzt) und keine mehrstufige Stückliste.

## 3. Wenn etwas schiefgeht (Rückfallplan)
| Störung | Sofortmaßnahme |
|---|---|
| Anmeldung schlägt fehl / Keycloak antwortet nicht | Zweiten Benutzer/Fenster nutzen; sonst Offline-Video „Geschäftsablauf“ oder lokaler Stack (`http://localhost:8080`); Cloud-Belege aus den Folien/Clips erklären |
| Anwendung nicht erreichbar (502/Zeitüberschreitung) | 30–60 s warten (kann eine Auslieferung sein), `…/actuator/health` prüfen; sonst lokaler Stack |
| Daten nicht im Ausgangszustand (andere Nummern/Bestände) | Zahlen aus der Oberfläche vorlesen statt der Skriptzahlen; Auftrag trotzdem vorführen; Zurücksetzen nur vor der Demo, nie währenddessen |
| Auftrag bleibt „Wartet auf Material“ nach dem Wareneingang | Fenster A „Aktualisieren“; sonst „Material prüfen“ in der Zeile (löst dieselbe Prüfung aus) |
| Sitzung abgelaufen (Token 5 Minuten, wird still erneuert) | Seite neu laden, erneut anmelden |
| Netzwerk fällt aus | Offline-Videos abspielen und live kommentieren |
| Toast verschwindet zu früh | Status in der Tabelle zeigen (bleibt stehen) |
