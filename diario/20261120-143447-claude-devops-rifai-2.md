## 2026-11-20 14:34 · claude-sandbox · 3a03452f · squadd-multi-agents-ios · ramo: claude/devops-rifai-2
Push vera nel simulatore portata in pr-ios-run live --push sul runner Mac, verde al quarto giro (run 44754359099)
- scripts/pr-ios-push.yml: fb-idb 1.7.8 non esiste su PyPI, il client giusto è 1.7.7; il companion v1.7.8 c'è
- ci/foto/tap_allow.py: un simulatore nuovo eredita l'italiano del Mac, il popup dice Consenti; ora cerca Allow|Consenti e il passo muore a 8 minuti
- HermesMobileTests/SquaddPushTests.swift: testPrepareTheSimulatorForARealPush c'era già su dev (#65), il cherry-pick l'ha duplicato e la build è caduta
+ scripts/pr-ios-run: il verde dipende dal GET del thread al companion dopo il tocco, non da una foto
