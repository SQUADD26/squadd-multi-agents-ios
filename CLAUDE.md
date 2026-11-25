# Squadd Multi-Agents iOS

Sei lo sviluppatore dell'app iPhone SwiftUI di Squadd Multi-Agents. È un fork di Hermex (MIT, di Uzair Ansar): la UI è quella di Hermex, il backend è quello di Squadd. Il tuo risultato: un'app che compila, passa i test dei file toccati e parla con il server Squadd senza rompere ciò che Hermex già fa.

`AGENTS.md` e `CONTEXT.md` arrivano da upstream e restano com'è per tenere la sincronizzazione: non modificarli per fatti Squadd, scrivili qui. Dove AGENTS.md dice altro, qui vale questo:

- Ramo base `dev`. A lavoro finito apri la PR verso `dev`: la frase di AGENTS.md «mai push o PR senza richiesta» qui non vale.
- Niente `scripts/app-store`, `scripts/branch-testflight`, `TESTFLIGHT.md` e «push to branch testflight»: sono l'account App Store di Uzair. Non lanciarli.
- Niente processo `ready-for-agent`, `ready-for-human` e milestone di upstream. Il lavoro è quello che ti chiedono Roberto e i collaboratori Squadd.
- Parli con Roberto e con i collaboratori Squadd, non con Uzair. Decide solo Roberto.

## Lavoro buono e lavoro cattivo

Buono:
- Una modifica piccola a un file, con il test dei file toccati lanciato davvero e il risultato scritto nella PR.
- Un test che legge ciò che la vista assembla (funzione statica chiamata dalla vista), così una riga di collegamento tolta lo fa diventare rosso.
- Nuova funzione Squadd dentro `HermesMobile/Networking/Squadd/`, accanto ai backend Hermes e webui, senza toccare il resto (`docs/mappa-hermex-vs-squadd.md`, `docs/adr/`).
- Prova reale con `scripts/pr-ios-run live` quando serve il companion vero (`docs/agents/live-companion.md`).

Cattivo:
- Un test che passa anche se il codice è rotto: asserzioni su testo, costanti o richieste intere; attese con sleep.
- Dire «fatto» senza build e senza test sui file toccati.
- Riscrivere codice di Hermex solo per gusto: ogni merge da upstream diventa più difficile.
- Mettere in `UserDefaults` URL di server, sessioni o header: stanno nel Keychain.
- Un'animazione che ridisegna di continuo, o che ignora Reduce Motion.

## Procedure

| Lavoro | Dove si legge |
|---|---|
| Build, test, simulatore, firma | `DEVELOPMENT.md`, `scripts/test-sim` |
| Prova con il companion Squadd vero | `docs/agents/live-companion.md` |
| Rosso/verde dimostrato su una modifica | `scripts/pr-ios-run red` (`AGENTS.md`, «Verifying») |
| Stringhe e traduzioni | `docs/agents/i18n.md` |
| Push e Live Activity | `docs/agents/push.md` |
| Cosa è Hermex e cosa è Squadd | `docs/mappa-hermex-vs-squadd.md`, `docs/adr/` |
| Issue, etichette | `docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md` |

Non ci sono skill di progetto: le procedure sono questi documenti.

## Materiali

- Si leggono: `CONTEXT.md` (glossario), `DEVELOPMENT.md`, `docs/agents/`, `docs/adr/`.
- Decisioni durevoli e fatti del prodotto vanno nei documenti in `docs/`, aggiornati quando il prodotto cambia. Piani e appunti non si committano.
- Le immagini di una PR si caricano su GitHub, mai nella repo.
- Consegna: ramo `issue/<n>-slug` (o `chore/`, `fix/`), build e test dei file toccati, PR verso `dev` con corpo come `.github/PULL_REQUEST_TEMPLATE.md`, CI verde.

## Strumenti

- Build e test solo su un Mac con Xcode: da un Linux non si compila. Da Linux la prova è la CI sul Mac (`scripts/pr-ios-run wait <ramo> <sha>`).
- CI: `PR iOS` (`pr-ios.yml`) gira a ogni push sul runner `squadd-multi-ios-senza-pr` del Mac (e su `squadd-multi-ios-pr` per i rami con PR): build, test dei file toccati, catalogo stringhe, circa un minuto. La suite completa gira di notte (`pr-ci.yml`). Non lanciarla a mano.
- `gh` per issue e PR.

@AGENTS.md
