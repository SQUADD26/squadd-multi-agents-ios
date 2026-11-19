---
status: accepted
---

# Android dopo la v1 iOS: app Kotlin/Compose nativa con un core di protocollo Kotlin Multiplatform

Hermex non ha un client Android e il suo maintainer l'ha escluso (uzairansaruzi/hermex#1311). I port della community esistenti parlano con Hermes o webui, non con Squadd; il contratto di Squadd sta in TypeScript in `packages/phone-protocol`. Le strade valutate sono in `docs/mappa-hermex-vs-squadd.md`, sezione Android: app Kotlin separata, core KMP con UI native, Skip, React Native o PWA.

Decidiamo che Android parte solo quando la v1 iOS è in piedi, ed è un'app Kotlin/Compose nativa con un core Kotlin Multiplatform che contiene solo protocollo, decodifica dei frame, pairing, Noise e yamux, sul modello di `unsupportedpastels/mercury` (MIT), costruito su `packages/phone-protocol`. Il core KMP evita di scrivere due volte la parte più rischiosa, il tunnel cifrato. Skip è scartato perché non provato su un'app con estensioni e Live Activity; React Native e PWA buttano via il lavoro SwiftUI e peggiorano background e notifiche. Il prezzo: iOS tiene il suo strato di rete in Swift, quindi per ora il core KMP serve solo ad Android.

## Conseguenze

- Android non ha ticket nella v1.
- Se il tunnel E2E (ADR 0003) si scrive prima di Android, conviene scriverlo nel core KMP e chiamarlo da Swift, così Android lo eredita.
