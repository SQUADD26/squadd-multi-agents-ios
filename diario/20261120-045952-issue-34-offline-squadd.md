## 2026-11-20 04:59 · claude-sandbox · 71a4dc73 · squadd-multi-agents-ios · ramo: issue/34-offline-squadd
Cache offline di Squadd #34: la home offline ritenta da sola e la riga della rotta cerca di nuovo, provato su PR iOS e live
+ SquaddAgentListModel: corregge il «?» della voce di prima, la home offline ritenta load() con attesa 1-2-4 s finché il computer risponde, senza gesto
+ SquaddServerHome: quando la copia lascia il posto ai dati veri la riga della rotta rifà find(), prima restava «Can't reach the computer.»
- fixture foto: le sonde /api/health a 404 nascondevano la riga della rotta ferma; ora la fixture risponde 200 e il test lo conta
- dev durante il lavoro: due conflitti in SquaddChatTests su makeChat, risolti tenendo le due firme unite
