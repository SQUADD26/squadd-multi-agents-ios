## 2026-11-20 14:48 · MacBook-Pro-di-Roberto · e74fdc0d · squadd-multi-agents-ios · ramo: chore/ci-build-driver
PR iOS: build col driver Swift esterno senza job emit-module separato, verde di #124 e #122 sotto 60 s
+ build: SWIFT_USE_INTEGRATED_DRIVER=NO con -no-emit-module-separately porta la build di #124 da 44 a 10 s (SwiftEmitModule dell app 21 s sparito)
- -no-emit-module-separately da solo: il driver integrato di Xcode lo ignora, emit-module resta 21 s
- -warn-long-function-bodies: fa controllare tutti i corpi anche in emit-module (103 s, run in timeout); non serve a misurare emit-module
? primo giro di ogni ramo dopo il cambio: ricompila tutto (~100 s), timeout del controllo portato a 3 min
