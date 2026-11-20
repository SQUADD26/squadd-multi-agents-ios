## 2026-11-20 14:12 · MacBook-Pro-di-Roberto · e74fdc0d · squadd-multi-agents-ios · ramo: chore/ci-foto-dopo
PR iOS: il verde della PR è build, test toccati non-foto e catalogo; le foto in un job dopo sullo stesso runner
+ divisione: anchor YAML (steps: &passi / *passi) funziona su GitHub; il job foto va sullo stesso runner con etichette squadd-multi-ios-uno/-due
- etichette: squadd-multi-ios-r1 e -r2 danno HTTP 500 alla creazione; uno/due passano
- tempo: #124 replicata 83 s al verde (era 92-101), la build da 44 s resta il limite
? guardie: cursore-guard scambia `open(` di Python in un heredoc per il comando open; usare Path.read_text
