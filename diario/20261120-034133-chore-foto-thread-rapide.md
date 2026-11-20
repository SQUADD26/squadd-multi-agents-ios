## 2026-11-20 03:41 · claude-sandbox · 71a4dc73 · squadd-multi-agents-ios · ramo: chore/foto-thread-rapide
Foto dei thread Squadd più veloci: testPhotoSquaddThreads da 18.2 s a 8.6 s, 5 foto invece di 9, il resto come asserzioni su ciò che UIKit presenta
+ misura: tempi per foto scritti in un file dentro l'artefatto foto (le print del test non arrivano in tests.log); 4 foto ferme al limite 3 s di readyPhoto per cursore che lampeggia o foglio fuori processo
- UIView.setAnimationsEnabled(false): non aiuta, il cursore lampeggia lo stesso (20.4 s)
- etichette di accessibilità SwiftUI: vuote in un test unitario senza VoiceOver, quindi asserzioni sul testo SwiftUI non funzionano; vanno bene title di UIAlertController e presentedViewController
? f3-search-empty resta circa 3 s per il cursore: sotto i 3 s totali servirebbero 2 foto sole
