---
status: accepted
---

# Push e Live Activity passano dagli endpoint e dal relay di Squadd

Hermex registra i token APNs sul relay hermex-push del maintainer di Hermex (`HermesMobile/Push/PushRelayClient.swift`). Squadd ha già i suoi endpoint nel companion, `PUT`/`DELETE /api/push/device` e `/api/push/activity`, e un relay suo lato server (`server/phone-push.ts`), che manda notifiche senza contenuto con un `kind` (approval, question, sign-in, done).

Decidiamo di registrare token del device e token delle Live Activity solo sugli endpoint di Squadd, e di non parlare più con hermex-push. Il relay di Squadd firma le push con la nostra chiave APNs, quindi l'app gira con bundle ID, app group e team Apple di Squadd, per l'app e per ogni estensione. Abbiamo scartato di continuare con hermex-push: è il servizio di un'altra persona, vede i token dei nostri utenti e ci lega alla sua chiave APNs.

## Conseguenze

- Bundle ID, team e chiave APNs si creano nell'account Apple di Squadd: è un lavoro di chi gestisce quell'account (issue con etichetta `serve-roberto`), e blocca la prova delle push su un iPhone vero.
- Le push di Squadd non portano testo: l'estensione che decifra la notifica non serve nella v1.
- La prova `POST …/notify` di hermex-push non ha un equivalente nel companion e sparisce dalle impostazioni.
