-- ============================================================
-- 553_qa_plan_extra_hours_fixes.sql
--
-- PLAN DE QA — NO EJECUTAR — solo para revisión y autorización
--
-- Valida en vivo las 3 rutas corregidas en sql/550, 551 y 552
-- (approve_extra_hour_payment_atomic, group_confirm_extra_hours,
-- confirm_cash_extra_payment) más el comportamiento de
-- release_extra_hours_partial/_final sobre esas filas ya corregidas.
--
-- ── Respuesta al punto 1 (verificación de entorno) ─────────────────
-- `supabase projects list` confirma que esta cuenta solo tiene un
-- proyecto Supabase vinculado para Daricefy (music-market-global,
-- ref sqgzyipqpewzbnfrtdqk) — no existe un proyecto Sandbox separado.
-- Es producción, y es el mismo proyecto usado en toda la sesión. Por
-- decisión explícita del usuario, no se agrega ningún check de
-- "abortar si no es Sandbox" (sería falso). En su lugar, este plan
-- usa el mismo protocolo riguroso de siempre — reforzado aquí al
-- máximo porque no hay red de seguridad de un entorno aislado:
--   · IDs QA fijos, sintéticos, verificados como inexistentes ANTES
--     de usarlos (Fase 0).
--   · Snapshot exacto de todo saldo/fila que se va a tocar (Fase 1).
--   · Todo INSERT usa esos IDs fijos — nunca gen_random_uuid() — así
--     la limpieza puede filtrar por ID exacto, no por rango de tiempo.
--   · Reserva QA con status='completed' (fuera de
--     estados_que_ocupan()) — no dispara triggers de disponibilidad
--     ni de finalización de evento.
--   · Restauración de saldos al valor EXACTO snapshoteado, con guard
--     que aborta si el valor actual no es el esperado antes de pisarlo
--     (mismo patrón de pre-check de hash usado en sql/550-552).
--
-- ── Entidades de referencia (mismas usadas toda la sesión) ─────────
--   Grupo:  83911568-2694-4541-81ae-af1f80bc490e
--           (owner 929ba9ba-1dfd-4b76-abf1-18168b1ac1ba, push_tokens=0)
--   Cliente: 889e7168-a30a-49c5-a32a-cbeb320d00f8 ("Lala")
--   Admin:  resuelto dinámicamente vía get_platform_admin_id()
--
-- ── IDs QA fijos y sintéticos (nunca generados al azar) ─────────────
--   Reserva QA:                 00000000-0000-4000-a552-000000000001
--   Extra hour (cash, ruta A):  00000000-0000-4000-a552-000000000002
--   Extra hour (saldo, ruta A): 00000000-0000-4000-a552-000000000003
--   Extra hour (saldo, ruta B): 00000000-0000-4000-a552-000000000004
--   Extra hour (cash, ruta C):  00000000-0000-4000-a552-000000000005
--
-- ── Cómo se ejecutaría ───────────────────────────────────────────────
-- Cada FASE de abajo es un archivo/ejecución separada (igual que
-- 550→551→552), para poder inspeccionar el resultado entre fases y
-- detenerse si algo no cuadra. Nada se ejecuta hasta autorización
-- explícita, fase por fase.
-- ============================================================


-- ════════════════════════════════════════════════════════════════
-- FASE 0 — Pre-checks (solo lectura, aborta si algo no coincide)
-- ════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_hash TEXT;
BEGIN
  -- 0a. Las 3 funciones corregidas deben seguir exactamente como quedaron
  SELECT md5(prosrc) INTO v_hash FROM pg_proc WHERE proname='approve_extra_hour_payment_atomic' AND pronamespace='public'::regnamespace;
  IF v_hash <> '33628daffb34921cfe883a8205b97607' THEN
    RAISE EXCEPTION 'ABORT: approve_extra_hour_payment_atomic cambió desde sql/550 (md5=%)', v_hash;
  END IF;

  SELECT md5(prosrc) INTO v_hash FROM pg_proc WHERE proname='group_confirm_extra_hours' AND pronamespace='public'::regnamespace;
  IF v_hash <> 'a7d390424f07f16c8581ad8b7178e022' THEN
    RAISE EXCEPTION 'ABORT: group_confirm_extra_hours cambió desde sql/551 (md5=%)', v_hash;
  END IF;

  SELECT md5(prosrc) INTO v_hash FROM pg_proc WHERE proname='confirm_cash_extra_payment' AND pronamespace='public'::regnamespace;
  IF v_hash <> '2ddb5640bc4b04f5f8ce5761d91eb7f0' THEN
    RAISE EXCEPTION 'ABORT: confirm_cash_extra_payment cambió desde sql/552 (md5=%)', v_hash;
  END IF;

  -- 0b. confirm_extra_hour_stripe_payment (hermana, no tocada) sigue igual
  SELECT md5(prosrc) INTO v_hash FROM pg_proc WHERE proname='confirm_extra_hour_stripe_payment' AND pronamespace='public'::regnamespace;
  IF v_hash <> 'fca14301fc3ae170a5f8024e709f4c39' THEN
    RAISE EXCEPTION 'ABORT: confirm_extra_hour_stripe_payment cambió — fuera del plan, revisar manualmente (md5=%)', v_hash;
  END IF;

  -- 0c. Ninguno de los 5 IDs sintéticos QA existe ya en ninguna tabla relevante
  IF EXISTS (SELECT 1 FROM reservations WHERE id = '00000000-0000-4000-a552-000000000001') THEN
    RAISE EXCEPTION 'ABORT: el ID de reserva QA ya existe — elegir otro antes de continuar';
  END IF;
  IF EXISTS (
    SELECT 1 FROM extra_hours WHERE id IN (
      '00000000-0000-4000-a552-000000000002','00000000-0000-4000-a552-000000000003',
      '00000000-0000-4000-a552-000000000004','00000000-0000-4000-a552-000000000005'
    )
  ) THEN
    RAISE EXCEPTION 'ABORT: alguno de los IDs de extra_hours QA ya existe — elegir otros antes de continuar';
  END IF;

  -- 0d. Grupo y cliente de referencia siguen siendo los esperados (rol correcto, sin cambios de dueño)
  IF NOT EXISTS (SELECT 1 FROM groups WHERE id='83911568-2694-4541-81ae-af1f80bc490e' AND owner_id='929ba9ba-1dfd-4b76-abf1-18168b1ac1ba') THEN
    RAISE EXCEPTION 'ABORT: el grupo de referencia cambió de dueño o no existe — verificar manualmente';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id='889e7168-a30a-49c5-a32a-cbeb320d00f8' AND role='client') THEN
    RAISE EXCEPTION 'ABORT: el cliente de referencia cambió de rol o no existe — verificar manualmente';
  END IF;

  RAISE NOTICE 'FASE 0 OK: funciones sin cambios, IDs QA libres, entidades de referencia válidas';
END $$;


-- ════════════════════════════════════════════════════════════════
-- FASE 1 — Snapshot PRE (solo lectura, guardar esta salida completa)
-- ════════════════════════════════════════════════════════════════

-- 1a. Saldo del wallet del grupo de referencia ANTES de tocar nada
SELECT id, available_balance, available_balance_usd, pending_balance, pending_balance_usd,
       total_earned, total_earned_usd
FROM group_wallets WHERE group_id = '83911568-2694-4541-81ae-af1f80bc490e';
-- Si no existe fila, anotar "no_wallet_pre_qa" — ensure_group_wallet la creará en Fase 3b.

-- 1b. Saldo del wallet del admin (resuelto dinámicamente) ANTES de tocar nada
SELECT w.user_id, w.available_balance, w.available_balance_usd, w.total_earned, w.total_earned_usd
FROM wallets w WHERE w.user_id = public.get_platform_admin_id();

-- 1c. Filas preexistentes relacionadas con los 5 IDs QA (deben ser 0 en todos los casos)
SELECT
  (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = '00000000-0000-4000-a552-000000000001') AS wt_por_reserva,
  (SELECT COUNT(*) FROM financial_audit_logs WHERE entity_id IN (
     '00000000-0000-4000-a552-000000000002','00000000-0000-4000-a552-000000000003',
     '00000000-0000-4000-a552-000000000004','00000000-0000-4000-a552-000000000005'
   )) AS logs_por_entity_id,
  (SELECT COUNT(*) FROM extra_hours WHERE id IN (
     '00000000-0000-4000-a552-000000000002','00000000-0000-4000-a552-000000000003',
     '00000000-0000-4000-a552-000000000004','00000000-0000-4000-a552-000000000005'
   )) AS extra_hours_preexistentes;
-- Esperado: 0, 0, 0 — esto es lo que hace seguro filtrar la limpieza (Fase 7)
-- por estos IDs exactos: cualquier fila que aparezca después con estos IDs
-- fue creada por este QA, sin ambigüedad.


-- ════════════════════════════════════════════════════════════════
-- FASE 2 — Crear la reserva QA (aislada, fuera de estados_que_ocupan())
-- ════════════════════════════════════════════════════════════════
BEGIN;

INSERT INTO reservations (
  id, group_id, client_id, event_date, address, total_price, status,
  currency_code, client_available_balance, payment_provider
) VALUES (
  '00000000-0000-4000-a552-000000000001',
  '83911568-2694-4541-81ae-af1f80bc490e',
  '889e7168-a30a-49c5-a32a-cbeb320d00f8',
  CURRENT_DATE,
  'QA — reserva sintética sql/553, no es un evento real',
  1000.00,
  'completed',              -- fuera de estados_que_ocupan(): sin trigger de disponibilidad ni de finalización
  'MXN',
  5000.00,                  -- saldo controlado, aislado a esta fila — no toca el saldo real del cliente
  'stripe'
);

COMMIT;

SELECT id, status, client_available_balance FROM reservations WHERE id = '00000000-0000-4000-a552-000000000001';
-- Esperado: status='completed', client_available_balance=5000.00


-- ════════════════════════════════════════════════════════════════
-- FASE 3a — Ruta A: approve_extra_hour_payment_atomic, rama EFECTIVO
-- ════════════════════════════════════════════════════════════════
BEGIN;

INSERT INTO extra_hours (
  id, reservation_id, hours_added, price_per_hour, total_extra_cost,
  platform_commission, group_extra_earnings, status, is_cash_payment, currency_code
) VALUES (
  '00000000-0000-4000-a552-000000000002',
  '00000000-0000-4000-a552-000000000001',
  1, 300, 300, 0, 300, 'pending', TRUE, 'MXN'
);

SET LOCAL request.jwt.claim.sub = '889e7168-a30a-49c5-a32a-cbeb320d00f8';  -- caller = cliente de la reserva
SELECT public.approve_extra_hour_payment_atomic('00000000-0000-4000-a552-000000000002'::uuid) AS resultado;

COMMIT;

-- Verificación 3a
SELECT status, payout_status, is_cash_payment FROM extra_hours WHERE id = '00000000-0000-4000-a552-000000000002';
-- Esperado: status='paid', payout_status='released' (antes del fix quedaba en 'held')
SELECT client_available_balance FROM reservations WHERE id = '00000000-0000-4000-a552-000000000001';
-- Esperado: sigue en 5000.00 — la rama efectivo NUNCA descuenta saldo
SELECT COUNT(*) AS wt_nuevas FROM wallet_transactions WHERE reservation_id = '00000000-0000-4000-a552-000000000001';
-- Esperado: 0 — la rama efectivo no acredita ningún wallet
SELECT action, amount FROM financial_audit_logs WHERE entity_id = '00000000-0000-4000-a552-000000000002';
-- Esperado: 1 fila, action='extra_approved_cash', amount=300


-- ════════════════════════════════════════════════════════════════
-- FASE 3b — Ruta A: approve_extra_hour_payment_atomic, rama SALDO
-- ════════════════════════════════════════════════════════════════
BEGIN;

INSERT INTO extra_hours (
  id, reservation_id, hours_added, price_per_hour, total_extra_cost,
  platform_commission, group_extra_earnings, status, is_cash_payment, currency_code
) VALUES (
  '00000000-0000-4000-a552-000000000003',
  '00000000-0000-4000-a552-000000000001',
  1, 200, 200, 40, 160, 'pending', FALSE, 'MXN'
);

SET LOCAL request.jwt.claim.sub = '889e7168-a30a-49c5-a32a-cbeb320d00f8';
SELECT public.approve_extra_hour_payment_atomic('00000000-0000-4000-a552-000000000003'::uuid) AS resultado;

COMMIT;

-- Verificación 3b — el punto crítico: que el crédito ocurra EXACTAMENTE una vez
SELECT status, payout_status FROM extra_hours WHERE id = '00000000-0000-4000-a552-000000000003';
-- Esperado: status='paid', payout_status='released'
SELECT client_available_balance FROM reservations WHERE id = '00000000-0000-4000-a552-000000000001';
-- Esperado: 5000.00 - 200.00 = 4800.00 (descontado UNA vez)
SELECT available_balance FROM group_wallets WHERE group_id = '83911568-2694-4541-81ae-af1f80bc490e';
-- Esperado: snapshot Fase 1a + 160.00 (acreditado UNA vez)
SELECT available_balance FROM wallets WHERE user_id = public.get_platform_admin_id();
-- Esperado: snapshot Fase 1b + 40.00 (comisión acreditada UNA vez)
SELECT type, amount FROM wallet_transactions WHERE reservation_id = '00000000-0000-4000-a552-000000000001' ORDER BY created_at;
-- Esperado: 2 filas — ('extra_hour', 160.00) y ('commission', 40.00)
SELECT action, amount FROM financial_audit_logs WHERE entity_id = '00000000-0000-4000-a552-000000000003';
-- Esperado: 1 fila, action='extra_approved_balance', amount=200


-- ════════════════════════════════════════════════════════════════
-- FASE 4 — Ruta B: group_confirm_extra_hours, rama SALDO
-- (incluye prueba de idempotencia — esta función SÍ tiene guard propio)
-- ════════════════════════════════════════════════════════════════
BEGIN;

INSERT INTO extra_hours (
  id, reservation_id, hours_added, price_per_hour, total_extra_cost,
  platform_commission, group_extra_earnings, status, is_cash_payment, currency_code
) VALUES (
  '00000000-0000-4000-a552-000000000004',
  '00000000-0000-4000-a552-000000000001',
  1, 150, 150, 30, 120, 'awaiting_group_confirmation', FALSE, 'MXN'
);

SET LOCAL request.jwt.claim.sub = '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';  -- caller = owner del grupo
SELECT public.group_confirm_extra_hours('00000000-0000-4000-a552-000000000004'::uuid) AS resultado_1a_llamada;

COMMIT;

-- Verificación 4 (primera llamada)
SELECT status, payout_status, group_confirmed_at FROM extra_hours WHERE id = '00000000-0000-4000-a552-000000000004';
-- Esperado: status='accepted', payout_status='released'
SELECT client_available_balance FROM reservations WHERE id = '00000000-0000-4000-a552-000000000001';
-- Esperado: 4800.00 - 150.00 = 4650.00
SELECT type, amount FROM wallet_transactions
WHERE reservation_id = '00000000-0000-4000-a552-000000000001' AND created_at > NOW() - INTERVAL '5 minutes'
ORDER BY created_at;
-- Esperado (acumulado con Fase 3b): ahora 4 filas totales; las 2 nuevas son ('extra_hour', 120.00) y ('commission', 30.00)
SELECT action, amount FROM financial_audit_logs WHERE entity_id = '00000000-0000-4000-a552-000000000004';
-- Esperado: 1 fila, action='group_confirmed_balance', amount=120

-- Segunda llamada — prueba de idempotencia (esta función SÍ está diseñada para
-- no repetir el crédito: status ya es 'accepted', fuera de la lista que dispara el bloque de dinero)
BEGIN;
SET LOCAL request.jwt.claim.sub = '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
SELECT public.group_confirm_extra_hours('00000000-0000-4000-a552-000000000004'::uuid) AS resultado_2a_llamada;
COMMIT;
-- Esperado: {"ok":true,"skipped":true,"reason":"already_processed"}

SELECT client_available_balance FROM reservations WHERE id = '00000000-0000-4000-a552-000000000001';
-- Esperado: sigue en 4650.00 — sin cambio por la segunda llamada
SELECT COUNT(*) FROM financial_audit_logs WHERE entity_id = '00000000-0000-4000-a552-000000000004';
-- Esperado: sigue en 1 — sin fila nueva por la segunda llamada


-- ════════════════════════════════════════════════════════════════
-- FASE 5 — Ruta C: confirm_cash_extra_payment
-- (segunda llamada es SOLO OBSERVACIÓN — no se corrige en esta ronda)
-- ════════════════════════════════════════════════════════════════
BEGIN;

INSERT INTO extra_hours (
  id, reservation_id, hours_added, price_per_hour, total_extra_cost,
  platform_commission, group_extra_earnings, status, is_cash_payment, currency_code
) VALUES (
  '00000000-0000-4000-a552-000000000005',
  '00000000-0000-4000-a552-000000000001',
  1, 250, 250, 0, 250, 'pending', FALSE, 'MXN'
);

SET LOCAL request.jwt.claim.sub = '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';  -- caller = owner del grupo
SELECT public.confirm_cash_extra_payment(
  '00000000-0000-4000-a552-000000000005'::uuid,
  '00000000-0000-4000-a552-000000000001'::uuid
) AS resultado_1a_llamada;  -- función retorna void; NULL es el resultado esperado si no lanza excepción

COMMIT;

-- Verificación 5 (primera llamada — esta es la que antes SIEMPRE fallaba)
SELECT status, payout_status, is_cash_payment, cash_confirmed_at FROM extra_hours WHERE id = '00000000-0000-4000-a552-000000000005';
-- Esperado: status='paid', payout_status='released', is_cash_payment=true, cash_confirmed_at NOT NULL
SELECT action, amount, notes FROM financial_audit_logs WHERE entity_id = '00000000-0000-4000-a552-000000000005';
-- Esperado: 1 fila, action='cash_extra_confirmed', amount=NULL (deliberado, ver sql/552)
SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = '00000000-0000-4000-a552-000000000001' AND created_at > NOW() - INTERVAL '2 minutes';
-- Esperado: 0 — esta función nunca toca wallets

-- Segunda llamada — SOLO OBSERVACIÓN, NO ES UN FIX. Si produce una fila
-- duplicada en financial_audit_logs, se reporta como hallazgo nuevo y
-- se deja así, sin corregir, por instrucción explícita.
BEGIN;
SET LOCAL request.jwt.claim.sub = '929ba9ba-1dfd-4b76-abf1-18168b1ac1ba';
SELECT public.confirm_cash_extra_payment(
  '00000000-0000-4000-a552-000000000005'::uuid,
  '00000000-0000-4000-a552-000000000001'::uuid
) AS resultado_2a_llamada;
COMMIT;

SELECT COUNT(*) AS logs_totales_tras_2a_llamada FROM financial_audit_logs WHERE entity_id = '00000000-0000-4000-a552-000000000005';
-- Si da 2: confirma el hallazgo (sin idempotencia) — se reporta, no se corrige aquí.
-- Si da 1: la función sí es idempotente de algún modo no documentado — reportar también.


-- ════════════════════════════════════════════════════════════════
-- FASE 6 — release_extra_hours_partial / _final sobre las filas QA
-- Las 4 filas QA ya tienen payout_status='released' — ninguna debe
-- ser recogida por estas funciones (ambas filtran payout_status
-- IN ('held','half_released') o ='held'). Deben ser un no-op total.
-- ════════════════════════════════════════════════════════════════

-- Snapshot inmediatamente antes
SELECT
  (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = '00000000-0000-4000-a552-000000000001') AS wt_antes,
  (SELECT COUNT(*) FROM financial_audit_logs WHERE entity_id IN (
     '00000000-0000-4000-a552-000000000002','00000000-0000-4000-a552-000000000003',
     '00000000-0000-4000-a552-000000000004','00000000-0000-4000-a552-000000000005'
   )) AS logs_antes,
  (SELECT available_balance FROM group_wallets WHERE group_id='83911568-2694-4541-81ae-af1f80bc490e') AS gw_balance_antes;

SELECT public.release_extra_hours_partial('00000000-0000-4000-a552-000000000001'::uuid) AS resultado_partial;
-- Esperado: {"ok":true,"released":0,"skipped":4}

SELECT public.release_extra_hours_final('00000000-0000-4000-a552-000000000001'::uuid) AS resultado_final;
-- Esperado: {"ok":true,"released":0,"amount":0}

-- Snapshot inmediatamente después — debe ser IDÉNTICO al de "antes"
SELECT
  (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = '00000000-0000-4000-a552-000000000001') AS wt_despues,
  (SELECT COUNT(*) FROM financial_audit_logs WHERE entity_id IN (
     '00000000-0000-4000-a552-000000000002','00000000-0000-4000-a552-000000000003',
     '00000000-0000-4000-a552-000000000004','00000000-0000-4000-a552-000000000005'
   )) AS logs_despues,
  (SELECT available_balance FROM group_wallets WHERE group_id='83911568-2694-4541-81ae-af1f80bc490e') AS gw_balance_despues;
-- Confirma explícitamente los 4 puntos pedidos: 0 releases, 0 wallet_transactions
-- nuevas, 0 cambio de balance, 0 financial_audit_logs nuevos.


-- ════════════════════════════════════════════════════════════════
-- FASE 7 — Limpieza (acotada por ID exacto, no por rango de tiempo)
-- Segura porque Fase 0/1 probaron que estos IDs no existían antes del QA.
-- ════════════════════════════════════════════════════════════════
BEGIN;

DELETE FROM wallet_transactions
WHERE reservation_id = '00000000-0000-4000-a552-000000000001';

DELETE FROM financial_audit_logs
WHERE entity_id IN (
  '00000000-0000-4000-a552-000000000002','00000000-0000-4000-a552-000000000003',
  '00000000-0000-4000-a552-000000000004','00000000-0000-4000-a552-000000000005'
);

DELETE FROM extra_hours
WHERE id IN (
  '00000000-0000-4000-a552-000000000002','00000000-0000-4000-a552-000000000003',
  '00000000-0000-4000-a552-000000000004','00000000-0000-4000-a552-000000000005'
);

DELETE FROM reservations
WHERE id = '00000000-0000-4000-a552-000000000001';

-- Restaurar saldos al valor EXACTO del snapshot Fase 1 — con guard: aborta
-- si el valor actual no es el esperado post-QA (mismo patrón de pre-check
-- de hash usado en sql/550-552, aplicado aquí a valores de saldo).
-- NOTA (hallazgo propio, detectado en revisión de Fase 1, corregido antes
-- de cualquier ejecución): la versión anterior de este bloque solo
-- restauraba available_balance. approve_extra_hour_payment_atomic y
-- group_confirm_extra_hours también incrementan total_earned /
-- total_earned_usd en la misma UPDATE — dejarlo sin restaurar habría
-- inflado permanentemente el "total histórico ganado" del grupo y del
-- admin en $280.00 y $70.00 respectivamente. Corregido: se restauran
-- las 2 columnas, cada una con su propio guard.
DO $$
DECLARE
  -- group_wallets (grupo 83911568-2694-4541-81ae-af1f80bc490e, fila 1a91d439-003a-41ef-aae0-b5adbcc6e8b4)
  v_gw_avail_pre    CONSTANT NUMERIC := 0.00;      -- snapshot Fase 1a
  v_gw_avail_post   CONSTANT NUMERIC := 280.00;    -- 0.00 + 160.00 (Fase 3b) + 120.00 (Fase 4)
  v_gw_earned_pre   CONSTANT NUMERIC := 9000.00;   -- snapshot Fase 1a
  v_gw_earned_post  CONSTANT NUMERIC := 9280.00;   -- 9000.00 + 160.00 + 120.00
  -- wallets admin (013ce98d-d8b6-42cf-b466-30e27d937914)
  v_ad_avail_pre    CONSTANT NUMERIC := 5495.20;   -- snapshot Fase 1b
  v_ad_avail_post   CONSTANT NUMERIC := 5565.20;   -- 5495.20 + 40.00 (Fase 3b) + 30.00 (Fase 4)
  v_ad_earned_pre   CONSTANT NUMERIC := 5495.20;   -- snapshot Fase 1b
  v_ad_earned_post  CONSTANT NUMERIC := 5565.20;   -- 5495.20 + 40.00 + 30.00
  v_current NUMERIC;
BEGIN
  SELECT available_balance INTO v_current FROM group_wallets WHERE group_id = '83911568-2694-4541-81ae-af1f80bc490e';
  IF v_current <> v_gw_avail_post THEN
    RAISE EXCEPTION 'ABORT: group_wallets.available_balance actual (%) no coincide con lo esperado post-QA (%) — no se restaura a ciegas', v_current, v_gw_avail_post;
  END IF;
  SELECT total_earned INTO v_current FROM group_wallets WHERE group_id = '83911568-2694-4541-81ae-af1f80bc490e';
  IF v_current <> v_gw_earned_post THEN
    RAISE EXCEPTION 'ABORT: group_wallets.total_earned actual (%) no coincide con lo esperado post-QA (%) — no se restaura a ciegas', v_current, v_gw_earned_post;
  END IF;
  UPDATE group_wallets
  SET available_balance = v_gw_avail_pre, total_earned = v_gw_earned_pre, updated_at = NOW()
  WHERE group_id = '83911568-2694-4541-81ae-af1f80bc490e';

  SELECT available_balance INTO v_current FROM wallets WHERE user_id = public.get_platform_admin_id();
  IF v_current <> v_ad_avail_post THEN
    RAISE EXCEPTION 'ABORT: wallets.available_balance del admin actual (%) no coincide con lo esperado post-QA (%) — no se restaura a ciegas', v_current, v_ad_avail_post;
  END IF;
  SELECT total_earned INTO v_current FROM wallets WHERE user_id = public.get_platform_admin_id();
  IF v_current <> v_ad_earned_post THEN
    RAISE EXCEPTION 'ABORT: wallets.total_earned del admin actual (%) no coincide con lo esperado post-QA (%) — no se restaura a ciegas', v_current, v_ad_earned_post;
  END IF;
  UPDATE wallets
  SET available_balance = v_ad_avail_pre, total_earned = v_ad_earned_pre, updated_at = NOW()
  WHERE user_id = public.get_platform_admin_id();

  RAISE NOTICE 'Saldos y total_earned restaurados exactamente al snapshot Fase 1';
END $$;

COMMIT;


-- ════════════════════════════════════════════════════════════════
-- FASE 8 — Verificación final (todo debe volver a verse como en Fase 1)
-- ════════════════════════════════════════════════════════════════
SELECT
  (SELECT COUNT(*) FROM reservations WHERE id = '00000000-0000-4000-a552-000000000001') AS reserva_restante,
  (SELECT COUNT(*) FROM extra_hours WHERE id IN (
     '00000000-0000-4000-a552-000000000002','00000000-0000-4000-a552-000000000003',
     '00000000-0000-4000-a552-000000000004','00000000-0000-4000-a552-000000000005'
   )) AS extra_hours_restantes,
  (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = '00000000-0000-4000-a552-000000000001') AS wt_restantes,
  (SELECT COUNT(*) FROM financial_audit_logs WHERE entity_id IN (
     '00000000-0000-4000-a552-000000000002','00000000-0000-4000-a552-000000000003',
     '00000000-0000-4000-a552-000000000004','00000000-0000-4000-a552-000000000005'
   )) AS logs_restantes;
-- Esperado: 0, 0, 0, 0

SELECT available_balance FROM group_wallets WHERE group_id = '83911568-2694-4541-81ae-af1f80bc490e';
-- Esperado: idéntico al valor de Fase 1a
SELECT available_balance FROM wallets WHERE user_id = public.get_platform_admin_id();
-- Esperado: idéntico al valor de Fase 1b

SELECT '553_qa_plan_extra_hours_fixes preparado — NO EJECUTADO' AS status;
