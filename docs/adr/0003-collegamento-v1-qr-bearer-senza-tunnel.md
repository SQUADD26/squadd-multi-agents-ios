---
status: accepted
---

# Collegamento v1: QR di pairing, token bearer, LAN o tailnet ed endpoint HTTPS; il tunnel E2E dopo

Il telefono si collega al companion di Squadd, che gira sul computer dell'utente. Il companion offre il pairing con un link `openmausbot://pair?...` mostrato come QR sul desktop (`packages/phone-protocol/src/pairing-link.ts`) o con un codice digitato, poi un token del device che viaggia come bearer a ogni richiesta (`companion/src/proxy.ts`). Le vie per raggiungerlo sono l'endpoint HTTPS ospitato, la tailnet, la LAN e Bonjour (`companion/src/endpoints.ts`). Fuori casa c'è anche un tunnel cifrato Noise NKpsk0 P-256 su yamux, diretto o via relay (`companion/src/e2e/`).

Decidiamo che la v1 usa QR o codice, token bearer nel Keychain e le vie HTTPS ospitato, tailnet, LAN e Bonjour, provate nell'ordine del companion. Il tunnel Noise, yamux e il relay vengono in un passo dopo la v1: in Swift non esistono, sono il pezzo a rischio più alto della mappa e l'endpoint HTTPS ospitato copre già il caso fuori casa. Il prezzo: senza HTTPS ospitato né tailnet, fuori dalla LAN di casa il telefono non arriva al computer.

## Conseguenze

- Sulla LAN il traffico è in chiaro, come documenta `companion/README.md`: l'app non manda envelope di credenziali (card segreto) su LAN o Bonjour, solo su HTTPS ospitato o tailnet.
- Ogni pairing diventa un server nel registro che c'è già; un nuovo pairing dallo stesso telefono manda `replacesToken`.
- Il login all'account cloud di Squadd non serve per questa via ed è fuori dalla v1.
- Quando arriva il tunnel E2E, vale la nota dell'ADR 0005: scriverlo nel core Kotlin Multiplatform lo rende riusabile su Android.
