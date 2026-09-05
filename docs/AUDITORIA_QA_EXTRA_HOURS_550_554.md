# Auditoría de cierre — sql/550 a sql/555 (horas extra: doble crédito, idempotencia y regresión automatizada)

**Estado: APROBADO Y CERRADO** (autorizado por el usuario el 2026-08-20)
**Alcance:** 3 rutas de pago de horas extra (`approve_extra_hour_payment_atomic`, `group_confirm_extra_hours`, `confirm_cash_extra_payment`) + verificación de las 2 funciones de liberación (`release_extra_hours_partial`, `release_extra_hours_final`) + suite de regresión automatizada y repetible (`sql/555`) que cubre las 5 funciones anteriores.
**Entorno:** proyecto Supabase único `music-market-global` (ref `sqgzyipqpewzbnfrtdqk`) — no existe un proyecto Sandbox separado; todo el QA se ejecutó contra el mismo proyecto que usa la app, bajo un protocolo estricto de snapshot/guard/limpieza en vez de aislamiento de entorno.

---

## Resumen ejecutivo

Se encontró y corrigió un patrón repetido en 3 funciones: al marcar una hora extra como pagada, dejaban `payout_status` en el valor por defecto de tabla (`'held'`) en vez de `'released'`, aun cuando el dinero ya se había acreditado (o nunca debía acreditarse). Esto exponía a `release_extra_hours_partial`/`_final` a recoger esas filas más tarde y acreditar dinero una segunda vez (rutas que sí mueven saldo) o una primera vez indebida (ruta efectivo, que nunca debe tocar wallets). Al auditar la tercera función se descubrió un cuarto problema, más severo: su `INSERT` de auditoría usaba columnas inexistentes y **la función nunca se había completado exitosamente ni una sola vez** en toda su historia. Corregido eso, quedó expuesta una quinta falla — ausencia total de guard de idempotencia — cerrada en un fix final separado (sql/554).

**Ninguno de los 4 fixes requirió backfill.** La tabla `extra_hours` estuvo vacía (0 filas) durante toda la auditoría y sigue vacía hoy — todos los fixes son puramente hacia adelante.

Como cierre, se construyó `sql/555_extra_hours_regression_tests.sql`, una suite de regresión automatizada y **autorevertible** (no requiere fases manuales de limpieza) que ejercita las 5 funciones — las 3 corregidas más las 2 de liberación — con 68 aserciones cubriendo comportamiento exitoso, doble-crédito, idempotencia, autorización y manejo de errores. Ejecutada el 2026-08-20: **68/68 aserciones = 100% pass**, con rollback completo confirmado y 0 residuos. Detalle completo más abajo.

---

## Fix 1 — `sql/550_fix_extra_hour_double_credit.sql`

**Función:** `approve_extra_hour_payment_atomic` (cliente aprueba y paga hora extra, ramas efectivo y saldo)

**Causa raíz:** ambas ramas fijaban `status='paid'` sin fijar `payout_status`, quedando en el default `'held'`. En la rama saldo el crédito a `group_wallets.available_balance` y la comisión admin ya ocurrían de forma inmediata y directa en la misma función — dejar `'held'` habría permitido que `release_extra_hours_partial/_final` acreditaran el mismo monto una segunda vez. En la rama efectivo, la plataforma nunca procesa ese dinero — dejar `'held'` habría generado un crédito completamente indebido (dinero que Daricefy nunca tuvo).

**Cambio aplicado:** se agregó `payout_status = 'released'` a los dos `UPDATE extra_hours` (rama efectivo y rama saldo). Sin otros cambios.

**Hash:** `03b5eda62d7e165f64deea78a50958f6` → `33628daffb34921cfe883a8205b97607` (2377 → 10749 caracteres; la función es más larga porque incluye lógica completa de acreditación, no solo el fix)

**Filas históricas afectadas:** 0 (tabla vacía) — sin backfill.

**QA realizado:** ronda en vivo sql/553, 2026-08-18, Fase 3a (rama efectivo) y Fase 3b (rama saldo), con IDs sintéticos (`...a552-...0002`, `...0003`) sobre reserva QA aislada (`status='completed'`, fuera de `estados_que_ocupan()`).

**Resultado:**
- Rama efectivo: `status='paid'`, `payout_status='released'`; 0 `wallet_transactions`; saldo del cliente sin cambio (5000.00 → 5000.00); 1 `financial_audit_logs` (`action='extra_approved_cash'`).
- Rama saldo: `status='paid'`, `payout_status='released'`; saldo del cliente descontado **exactamente una vez** (5000.00 → 4800.00); grupo acreditado **una vez** (+160.00); admin acreditado **una vez** (+40.00); 2 `wallet_transactions` nuevas; 1 `financial_audit_logs` (`action='extra_approved_balance'`).

**Evidencia de no-doble-crédito:** Fase 6 del QA simuló los filtros `WHERE` exactos de ambas funciones de liberación sobre la fila resultante — `elegibles_release_partial=0`, `elegibles_release_final=0` — confirmando que ninguna fila con `payout_status='released'` sería recogida.

**Idempotencia:** fuera de alcance de este fix específico (la función ya tenía su propio guard preexistente, sin cambios: `IF status='paid' THEN RETURN skipped`).

**Limpieza:** Fase 7 del QA — restauración exacta verificada (ver sección de limpieza global).

---

## Fix 2 — `sql/551_fix_group_confirm_extra_hours_payout_status.sql`

**Función:** `group_confirm_extra_hours` (grupo confirma hora extra iniciada por el cliente, rama saldo)

**Causa raíz:** mismo patrón de `payout_status` sin fijar en la única rama que mueve dinero real (saldo, `awaiting_group_confirmation`). Además, esa rama nunca dejaba registro en `financial_audit_logs` pese a mover dinero real — a diferencia de sus funciones hermanas. Hoy no producía doble crédito porque `status` queda en `'accepted'`, valor que nunca coincide con el filtro `status='paid'` de las funciones de liberación — pero esa era una protección accidental, no por diseño.

**Cambio aplicado (2 puntos, autorizados explícitamente):**
1. `payout_status='released'` agregado al `UPDATE extra_hours` final (las 3 ramas que llegan a ese punto: legado, saldo, efectivo).
2. Nuevo `INSERT INTO financial_audit_logs` dentro del bloque de crédito de saldo (única rama que mueve dinero en esta función).

**Hash:** `53a368624f81295dc1391767575e9e51` → `a7d390424f07f16c8581ad8b7178e022` (10093 caracteres)

**Filas históricas afectadas:** 0 — sin backfill.

**QA realizado:** sql/553 Fase 4, 2026-08-18, ID sintético `...a552-...0004`, incluyendo prueba de idempotencia (guard propio, preexistente).

**Resultado:** `status='accepted'`, `payout_status='released'`; saldo del cliente descontado una vez (4800.00 → 4650.00); grupo acreditado una vez (+120.00); admin acreditado una vez (+30.00); 2 `wallet_transactions`; 1 `financial_audit_logs` (`action='group_confirmed_balance'`).

**Evidencia de no-doble-crédito:** mismo chequeo de Fase 6 — 0 filas elegibles para las funciones de liberación (adicionalmente protegido porque `status='accepted'` nunca coincide con su filtro, pero ahora también correcto por diseño vía `payout_status`).

**Evidencia de idempotencia:** segunda llamada sobre la misma fila devolvió `{"ok":true,"skipped":true,"reason":"already_processed"}` — saldo del cliente sin cambio (4650.00 antes/después), 0 `financial_audit_logs` nuevos.

**Limpieza:** Fase 7 — restauración exacta verificada.

---

## Fix 3 — `sql/552_fix_confirm_cash_extra_payment.sql`

**Función:** `confirm_cash_extra_payment` (grupo confirma recepción de efectivo)

**Causa raíz (hallazgo más severo del round):** el `INSERT INTO financial_audit_logs` original referenciaba columnas inexistentes (`reservation_id`, `extra_hour_id`) y omitía las columnas `NOT NULL` reales (`entity_type`, `entity_id`). Esa sentencia **siempre fallaba**, revirtiendo toda la transacción — incluido el `UPDATE extra_hours` que la precedía. Confirmado con evidencia directa: 0 filas en toda la historia con `cash_confirmed_at IS NOT NULL`, 0 entradas con `action='cash_extra_confirmed'` — **la función nunca se había completado exitosamente ni una sola vez.**

**Cambio aplicado (2 puntos, autorizados explícitamente):**
1. `INSERT` reescrito con las columnas reales de `financial_audit_logs`.
2. `payout_status='released'` agregado al `UPDATE extra_hours` (mismo patrón que fixes 1 y 2 — latente hasta corregir el bug #1, ya que antes la función nunca llegaba a completarse).

**Hash:** `163d20cdaf7ed18410dbf57a3f336773` → `2ddb5640bc4b04f5f8ce5761d91eb7f0` (1245 → 2377 caracteres)

**Filas históricas afectadas:** 0 — no había filas que backfillear porque la función jamás había completado exitosamente.

**QA realizado:** sql/553 Fase 5, 2026-08-18, ID sintético `...a552-...0005` — **primera vez en la historia de la función que se completó exitosamente.**

**Resultado (1ª llamada):** `status='paid'`, `payout_status='released'`, `is_cash_payment=true`, `cash_confirmed_at` fijado; 1 `financial_audit_logs` (`action='cash_extra_confirmed'`, `amount=NULL` — deliberado, fuera de alcance capturarlo); 0 `wallet_transactions` (la función nunca toca wallets).

**Hallazgo abierto detectado en esta misma ronda (2ª llamada, solo observación, sin corregir por instrucción explícita):** la función no tenía guard de idempotencia — la 2ª llamada volvía a ejecutarse sin error, sobreescribía `cash_confirmed_at` y creaba una fila **duplicada** en `financial_audit_logs`. Documentado y diferido a un fix separado (sql/554).

**Limpieza:** Fase 7 — restauración exacta verificada.

---

## Fix 4 — `sql/554_fix_confirm_cash_extra_payment_idempotency.sql`

**Función:** `confirm_cash_extra_payment` (guard de idempotencia)

**Causa raíz:** ausencia total de guard — confirmada empíricamente en el QA de sql/552 (ver arriba).

**Cambio aplicado (mínimo, 1 punto):** la comprobación de existencia se movió de después del `UPDATE` (`IF NOT FOUND`) a antes, vía `SELECT ... FOR UPDATE`; se agregó `IF status='paid' AND payout_status='released' AND is_cash_payment THEN RETURN; END IF;` — no-op silencioso si la fila ya fue confirmada. El `UPDATE` y el `INSERT` de la 1ª confirmación quedaron carácter por carácter idénticos a sql/552. Sin cambio de firma ni tipo de retorno (sigue `void`) — no requirió tocar el frontend (`ExtraHoursScreen.tsx`).

**Hash:** `2ddb5640bc4b04f5f8ce5761d91eb7f0` → `9b51bddfd4cc1fecf004288312586862` (2377 → 3017 caracteres)

**Filas históricas afectadas:** 0 — sin backfill.

**QA realizado:** ronda dedicada, 2026-08-19, reserva sintética `00000000-0000-4000-a554-000000000001` + hora extra `...0002`.

**Resultado (1ª llamada):** `status='paid'`, `payout_status='released'`, `cash_confirmed_at=2026-08-19 16:53:29.622114+00` (capturado); 1 `financial_audit_logs`; 0 `wallet_transactions`; 0 cambios de wallet — idéntico al comportamiento validado en sql/552.

**Evidencia de idempotencia (2ª llamada sobre la misma fila):** completó sin excepción; `cash_confirmed_at` **exactamente igual** al capturado en la 1ª llamada (verificado por comparación directa, `timestamp_sin_cambio=true`); `financial_audit_logs` permaneció en **1** fila (sin duplicado); 0 `wallet_transactions`; 0 cambios de saldo. **El hallazgo de sql/552 queda cerrado.**

**Limpieza:** transacción única con guards pre/post-DELETE — todos pasaron, `COMMIT` confirmado.

---

## Suite de regresión — `sql/555_extra_hours_regression_tests.sql`

**Propósito:** dejar una prueba automatizada y repetible de las 5 funciones auditadas (las 3 corregidas + las 2 de liberación), para poder re-ejecutarla en el futuro sin repetir todo el proceso manual de sql/553-554.

**Diseño (mismo patrón que `sql/536`/`sql/537`/`sql/540`, ya establecido en el repo):** un único `DO $test555$ ... END $test555$;` que crea sus propios fixtures sintéticos (grupo temporal `__TEST_EXTRAHOURS_555__` con wallet propia arrancando en 0, reservas y filas `extra_hours` aisladas), ejecuta 68 aserciones cubriendo:
- `approve_extra_hour_payment_atomic`: rama efectivo y rama saldo, saldo insuficiente, moneda no soportada, autorización, guard de "ya pagada", hora rechazada (casos A1-A7).
- `group_confirm_extra_hours`: primera llamada, segunda llamada idempotente, autorización, saldo insuficiente, moneda no soportada (casos B1-B5).
- `confirm_cash_extra_payment`: primera llamada, segunda llamada idempotente (verificando que `cash_confirmed_at` no cambia y que `financial_audit_logs` no se duplica — el fix de sql/554), autorización, IDs desalineados (casos C1-C4).
- Invariante `payout_status='released'` en las 3 rutas exitosas (D1).
- No doble crédito en `group_wallets`/`wallets`, y confirmación de que `release_extra_hours_partial`/`_final` no vuelven a recoger las filas ya liberadas (E1-E6).
- Las rutas de efectivo nunca tocan `wallet_transactions` (F1).
- Errores/autorización sin sesión y verificación consolidada de que ningún intento fallido dejó residuo (G1-G3).
- Invariantes finales: saldos exactos, columnas `_usd`/`pending` sin tocar, ningún bucket negativo.

**Resultado de la ejecución (2026-08-20): 68/68 aserciones = 100% pass, 0 fallos.** Ningún caso arrojó `false`.

**Sobre el `unexpected status 400` / `P0001` en la salida del comando:** el archivo termina siempre en `RAISE EXCEPTION '%', v_report;` — **intencional, no un fallo del test.** Es el mecanismo que fuerza a Postgres a revertir automáticamente toda la transacción (fixtures, wallets, wallet_transactions, financial_audit_logs) sin importar si las aserciones pasaron o no. El código de error `P0001` (excepción genérica de PL/pgSQL) y el HTTP 400 reportado por la API de Supabase son la forma en que ese `RAISE` intencional se propaga hacia el cliente — el mensaje de la excepción contiene el reporte completo de los 68 asserts, no una descripción de una falla real.

**Rollback confirmado por verificación independiente (solo lectura, después de la ejecución):**

| chequeo | resultado |
|---|---|
| Grupo temporal `__TEST_EXTRAHOURS_555__` | 0 (ausente) |
| `extra_hours` (global) | 0 filas |
| Reservas QA residuales | 0 |
| `wallets` admin — available/total_earned | 5495.20 / 5495.20 (idéntico al snapshot pre-existente) |
| `group_wallets` grupo de referencia — available/total_earned | 0.00 / 9000.00 (sin tocar) |
| `wallet_transactions` ligadas al grupo temporal | 0 |
| `financial_audit_logs` con referencia al grupo temporal | 0 |
| `group_wallets` huérfanos | 0 |

**Repetibilidad:** al ser 100% autorevertible por diseño (nunca hace `COMMIT`), `sql/555` puede ejecutarse cualquier número de veces en el futuro — por ejemplo, cada vez que se toque alguna de las 5 funciones cubiertas — sin dejar cambios en producción en ningún escenario, incluso si alguna aserción llegara a fallar en una corrida futura.

---

## Estado final de limpieza (verificado, todas las rondas)

| verificación | resultado |
|---|---|
| IDs sintéticos QA (rondas sql/553, sql/554 y sql/555) | 0 remanentes en todas las tablas |
| `extra_hours` (global) | 0 filas — igual que antes de iniciar la auditoría |
| `wallet_transactions` / `financial_audit_logs` ligados a IDs/fixtures QA | 0 remanentes |
| `group_wallets` (grupo de referencia `83911568-...`) | `available_balance=0.00`, `total_earned=9000.00` — idéntico al snapshot pre-QA |
| `wallets` admin (`013ce98d-...`) | `available_balance=5495.20`, `total_earned=5495.20` — idéntico al snapshot pre-QA |
| `pending_balance` / campos `_usd` (ambos wallets) | sin tocar en ningún momento de las 5 rondas |

`sql/555` no requirió fases de limpieza manual (a diferencia de sql/553/554) — su rollback es automático e incondicional por diseño, y quedó confirmado por verificación independiente en su propia sección arriba.

## Funciones hermanas — confirmado sin cambios en toda la auditoría

`confirm_extra_hour_stripe_payment` (hash `fca14301fc3ae170a5f8024e709f4c39`, sin variación en ningún punto de la auditoría) — no fue tocada por ningún `CREATE OR REPLACE` de sql/550-554, y `sql/555` solo la deja fuera de cobertura de tests (no la invoca, no la modifica). `release_extra_hours_partial` y `release_extra_hours_final` tampoco fueron objeto de ningún `CREATE OR REPLACE` en esta auditoría; su comportamiento se verificó dos veces — Fase 6 de sql/553 (datos reales de QA manual) y de nuevo en `sql/555` (suite automatizada) — mostrando 0 filas elegibles bajo sus propios filtros en ambas ocasiones.

## Confirmación explícita: sin backfill pendiente

Ninguno de los 4 fixes (sql/550-554) requirió, generó ni dejó pendiente ningún backfill de datos históricos. La tabla `extra_hours` estuvo vacía (0 filas) en cada punto de verificación de esta auditoría — desde antes del primer fix hasta después de la ejecución de `sql/555` — por lo que **no existe ninguna fila de producción que haya sido creada bajo el comportamiento defectuoso** de ninguna de las 3 funciones corregidas. `sql/555` en sí mismo tampoco requiere ni deja backfill: es una suite de prueba autorevertible, no una migración de datos.

---

## Hallazgos descartados / diferidos (fuera de alcance de esta auditoría, no corregidos)

Estos hallazgos surgieron durante el inventario de riesgos financieros más amplio que precedió a este round de fixes. Se documentan aquí por completitud, pero **no forman parte del alcance de sql/550-554** y no fueron modificados:

- **`admin_complete_payout` — bug cosmético** en la descripción de `wallet_transactions` generada por esa función. Diferido explícitamente por el usuario.
- **`stripe-webhook` — manejo de eventos de disputa/chargeback ausente.** Diferido explícitamente por el usuario.
- **Cuentas de grupo con perfil de talento (`job_board_profiles`) auto-creado.** Causa raíz identificada (3 rutas de código redundantes) y fix propuesto, pero **no autorizado ni construido**.
- **Incidente histórico MercadoPago/Stripe:** el faltante real de MercadoPago ($4,087 MXN) fue reconstruido y acreditado vía `sql/548` (cerrado en round anterior). El conjunto de $5,716 pagado vía Stripe queda **explícitamente indeterminado, sin tocar**, por instrucción directa del usuario de no salir de Stripe Sandbox.
- **Feature "novedades" (feed de noticias):** solo se dio una opinión exploratoria; no se construyó nada.

---

*Auditoría 550–555 cerrada 2026-08-20. Sin modificaciones de producción pendientes ni autorizadas más allá de lo documentado en este informe.*
