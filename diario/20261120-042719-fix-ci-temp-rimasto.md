## 2026-11-20 04:27 · MacBook-Pro-di-Roberto · e74fdc0d · squadd-multi-agents-ios · ramo: fix/ci-temp-rimasto
CI iOS: bundle e log rimasti in _temp da un giro annullato non fermano più i test (44660349209)
+ pr-ios.yml: prima dei test si tolgono one/two.xcresult e one/two.log; RUNNER_TEMP:? perché un rm con variabile vuota non tocchi mai la radice
- verifica locale della riga rm: bloccata dal controllo di sicurezza sui rm con variabile; la prova è il giro della PR sul runner
