## 2026-11-20 03:04 · claude-sandbox · f5a6cbb9 · squadd-multi-agents-ios · ramo: test/squadd-foto-veloci
Foto Squadd più veloci in CI: SquaddScreenPhoto da 6,9 s a circa 4,1-4,9 s, una finestra sola e readyPhoto
+ SquaddCompanionTests.swift: una finestra per test, cambio del rootViewController a ogni foto; foto identiche a dev byte per byte (quelle con orari relativi cambiano anche fra due giri di dev)
- readyPhoto: il minimo è 0,6 s a foto (4 render da 70 ms più 3 attese da 100 ms), quindi con 5 foto i 3 s non si raggiungono; la madre porta la proposta di abbassare l'attesa a chi gestisce la CI
- layer.speed: impostarlo a 100 sulla finestra non accorcia niente, provato in CI
