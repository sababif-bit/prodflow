# Browser-Smoke-Test gegen eine ausgelieferte Installation (nur lesend, von Hand)

Dieser Test meldet sich mit den **bestehenden** Demo-Benutzern `planner` und `purchaser` an (Keycloak, Authorization Code + PKCE), öffnet alle Seiten, prüft rollenabhängige Bedienelemente, lädt eine Unterseite neu,
meldet sich ab und prüft die Sicherheits-Header des Dokuments. Er ist die Nachprüfung nach einer Auslieferung (Plan B, Stufe S7) und **nicht Teil der CI** (er braucht Passwörter und eine laufende Installation).

## Sicherheitseigenschaften (im Code durchgesetzt)
- **Nur lesen.** Der Test klickt nie auf Aktionen (Anlegen, Genehmigen, Wareneingang, Abschließen). Zusätzlich bricht ein Routen-Filter **jede** Nicht-GET-Anfrage an `/api` ab und lässt den Test fehlschlagen.
- **Keine Zugangsdaten in Ausgaben.** Passwörter kommen nur aus der Umgebung. Tracing, Video und Screenshots sind aus (eine Trace-Datei würde eingetippte Werte enthalten). Schlägt ein Anmeldeschritt fehl, wird nur der Schrittname gemeldet,
  nicht das Aufrufprotokoll von Playwright (das den eingetippten Wert enthalten könnte). Anfragen werden ohne Query-String protokolliert (dort können Codes stehen).
- **Keine Voreinstellung für die Adresse.** Ohne `PROD_APP_URL` startet nichts; ein Lauf gegen die Produktion ist eine bewusste Entscheidung. `https` ist Pflicht (`http` nur für `localhost`).
- **Nichts wird eingecheckt:** keine Zugangsdaten, keine Berichte (`test-results/` und `playwright-report/` sind in `.gitignore`).

## Konfiguration (Umgebungsvariablen)
| Variable | Pflicht | Bedeutung |
|---|---|---|
| `PROD_APP_URL` | ja | Adresse der Anwendung, z. B. `https://prodflow-farhad.duckdns.org` |
| `PROD_AUTH_URL` | nein | erwarteter Anmeldeserver; wird gegen `GET /config.json` der Anwendung geprüft |
| `PRODSMOKE_PLANNER_PASSWORD`, `PRODSMOKE_PURCHASER_PASSWORD` | ja | Passwörter der Demo-Benutzer; ohne sie werden die Tests übersprungen |

## Ausführen (PowerShell; Passwörter nie anzeigen)
```powershell
cd frontend
$env:PROD_APP_URL  = 'https://prodflow-farhad.duckdns.org'
$env:PROD_AUTH_URL = 'https://prodflow-auth-farhad.duckdns.org'
# Passwörter aus dem Passwortmanager bzw. direkt aus der Server-.env in den Prozessspeicher lesen (nichts ausgeben):
$env:PRODSMOKE_PLANNER_PASSWORD   = (ssh -i $key ubuntu@$ip "sudo -n sed -n 's/^DEMO_PLANNER_PASSWORD=//p' /opt/prodflow/repo/deploy/.env").Trim()
$env:PRODSMOKE_PURCHASER_PASSWORD = (ssh -i $key ubuntu@$ip "sudo -n sed -n 's/^DEMO_PURCHASER_PASSWORD=//p' /opt/prodflow/repo/deploy/.env").Trim()
npx playwright test -c playwright.production.config.ts
Remove-Item Env:PRODSMOKE_PLANNER_PASSWORD, Env:PRODSMOKE_PURCHASER_PASSWORD
```
Nur auflisten, ohne etwas auszuführen: `npx playwright test -c playwright.production.config.ts --list` (mit gesetzter `PROD_APP_URL`; es findet keine Netzverbindung statt).

## Erwartetes Ergebnis und Auswertung
- 4 Tests grün: Konfiguration, Planer, Einkäufer, Dokument-Header. Pro Rolle eine Zeile `SUMMARY …` mit Zahlen (API-Aufrufe, Dashboard-Kacheln, Zeilenzahlen), ohne Zugangsdaten.
- **Abgebrochene GET-Anfragen:** Chromium meldet bei Angulars Fetch-Backend `net::ERR_ABORTED`, obwohl die Antwort (Status < 400) bereits angekommen ist. Der Test zählt solche Aufrufe getrennt als `abortedAfterResponse` und wertet sie nur dann als unkritisch, wenn zu **derselben Anfrage**
  eine erfolgreiche Antwort vorliegt. Alles andere (Netzwerkfehler, Abbruch ohne Antwort, 4xx/5xx) lässt den Test fehlschlagen.
- Die Zahlen der Kacheln hängen vom aktuellen Datenbestand ab; der Test vergleicht sie nicht mit festen Werten.

## Was der Test nicht tut
Er legt keine Benutzer an, ändert keine Passwörter, verändert keine Geschäftsdaten, ändert nichts an Keycloak und prüft nicht den Administrator. Die Prüfung der API-Rechte je Rolle übernimmt `scripts/smoke-auth.sh`, die Gesamtprüfung von außen `scripts/verify-deployment.sh`.
Getestet wird nur mit Chromium.
