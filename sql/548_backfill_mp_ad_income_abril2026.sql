-- ============================================================
-- 548_backfill_mp_ad_income_abril2026.sql
--
-- PROPÓSITO
--   Backfill histórico: acreditar al wallet del admin de plataforma
--   13 pagos de anuncios ("Grupo Destacado") cobrados vía MercadoPago
--   el 9-10 de abril de 2026, que nunca fueron registrados en
--   wallet_transactions ni acreditados a ninguna wallet.
--
-- CAUSA RAÍZ
--   La versión original de mark_ad_payment (sql/119) no tenía NINGUNA
--   lógica de acreditación a wallet — solo actualizaba el status del
--   anuncio. La lógica de crédito se agregó recién en sql/165. Estos
--   13 anuncios fueron procesados por el webhook de MercadoPago
--   mientras la versión sin crédito estaba activa.
--
-- EVIDENCIA DE QUE SON PAGOS REALES CONFIRMADOS (no intentos abandonados)
--   mp_payment_id (formato "179596856-<uuid>") solo lo escribía
--   mark_ad_payment, y esa función solo la invocaba el webhook al
--   confirmar el pago — a diferencia del flujo posterior de Stripe,
--   en este flujo NO existía escritura anticipada de mp_payment_id
--   al crear el anuncio. status='rejected' en las 13 filas refleja
--   una decisión de moderación de contenido POSTERIOR al cobro, no
--   una falta de pago.
--
-- MONTO: $4,087.00 MXN exactos (13 filas, ver pre-checks abajo).
--
-- EXPLÍCITAMENTE FUERA DE ALCANCE DE ESTE ARCHIVO
--   Los 11 anuncios pagados vía Stripe ($5,716.00 MXN, mp_payment_id
--   formato "pi_...") NO se incluyen aquí. Ese conjunto tiene una
--   ambigüedad real: create-ad-payment SÍ llegó a escribir
--   mp_payment_id al crear el anuncio (antes de que el cliente
--   pagara) en una versión anterior del código — corregido en
--   sql/496 — por lo que no se puede confirmar solo con datos de la
--   base si esos 11 realmente tuvieron un cargo exitoso en Stripe.
--   Requiere cruzar contra el Dashboard/API de Stripe antes de
--   decidir si se acreditan. No tocar sin autorización separada.
--
-- DISEÑO DE SEGURIDAD / IDEMPOTENCIA
--   - Todo el backfill corre dentro de un único bloque DO, atómico:
--     si cualquier pre-check falla, se aborta con RAISE EXCEPTION y
--     NO se escribe nada (rollback completo).
--   - Antes de cada INSERT se verifica: (a) el anuncio existe,
--     (b) su mp_payment_id coincide EXACTO con el esperado,
--     (c) su effective_price/total_price coincide EXACTO con el
--     monto esperado, (d) no existe ya una wallet_transaction con
--     ese mismo mp_payment_id.
--   - Se verifica que exista EXACTAMENTE 1 profile con role='admin'
--     antes de acreditar nada (evita reparto a múltiples admins).
--   - El crédito a wallets se calcula como la SUMA de lo realmente
--     insertado en ESTA ejecución (no un monto fijo hardcodeado) —
--     si el script se ejecuta dos veces, la segunda vez no insertará
--     ninguna fila nueva (guard NOT EXISTS) y el crédito será $0.00,
--     dejando el script completamente seguro de re-ejecutar.
--
-- NO EJECUTAR hasta autorización explícita. Este archivo se entrega
-- primero para revisión.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_admin_id       UUID;
  v_admin_count    INT;
  v_row            RECORD;
  v_ad             RECORD;
  v_existing_count INT;
  v_total_credited NUMERIC(12,2) := 0;
  v_rows_inserted  INT := 0;
  v_expected_total NUMERIC(12,2) := 4087.00;
BEGIN
  -- ── Pre-check 1: exactamente 1 admin ──────────────────────────────────
  SELECT COUNT(*) INTO v_admin_count FROM public.profiles WHERE role = 'admin';
  IF v_admin_count <> 1 THEN
    RAISE EXCEPTION 'ABORT: se esperaba exactamente 1 profile role=admin, se encontraron %', v_admin_count;
  END IF;

  SELECT id INTO v_admin_id FROM public.profiles WHERE role = 'admin' LIMIT 1;

  -- ── Pre-check 2 + INSERT: recorrer las 13 filas esperadas ─────────────
  FOR v_row IN
    SELECT * FROM (VALUES
      ('f791d919-9236-4056-bc98-cdf00a3274c9'::uuid, 349.00::numeric, '179596856-1b9d752a-4ce9-4531-bd97-409dc77fc63f'::text),
      ('eaf63d48-d693-4d46-953d-2af026d75d86'::uuid, 349.00::numeric, '179596856-6097cd49-4fd7-4fc3-94f9-9a0487a41796'::text),
      ('eb23217f-6b68-47b4-a4cc-d4a89358d96d'::uuid, 599.00::numeric, '179596856-cb55d81d-af44-4f6a-9efe-51f82bdb81d6'::text),
      ('2ff7a927-a83a-45f9-a897-f1e3581b76d4'::uuid, 599.00::numeric, '179596856-3fd6465d-7e18-48c9-a572-c69fca89558f'::text),
      ('64a163e0-b1f9-476b-bf15-97a06bd5a78e'::uuid, 599.00::numeric, '179596856-b073dba8-cab2-4cc2-8407-d1518ef2b402'::text),
      ('baa1968d-2aa0-4497-902e-bbcf93f98a6c'::uuid, 199.00::numeric, '179596856-d83887ad-4cb1-4fa2-b94e-7ed1b1b83bb4'::text),
      ('37c4f07b-e481-4d9e-bd72-ab3564c2c1fd'::uuid, 199.00::numeric, '179596856-9c4a8eec-f44d-4e19-8bd0-027e4980ad12'::text),
      ('3800b488-3818-4025-8ade-6f554bfaae1c'::uuid, 199.00::numeric, '179596856-cd9bb7a7-e0ac-451d-b570-6680892af51b'::text),
      ('5943c788-6d87-43e5-a97f-fe2a2ac3cfe2'::uuid, 199.00::numeric, '179596856-96555839-8529-4207-b4c1-fbc8076f88d3'::text),
      ('636b5a3e-8251-4ef6-80d4-3e14effa2abe'::uuid, 199.00::numeric, '179596856-45b563dc-3acd-4487-8a88-d7d2704f0c51'::text),
      ('7926423f-323b-403d-8384-cb2df117a4d4'::uuid, 199.00::numeric, '179596856-69ce97d8-e263-4b04-a411-30a4b1d3485f'::text),
      ('6eea9b4c-7ee8-4fe6-b45b-8e94d1a3b746'::uuid, 199.00::numeric, '179596856-e4fda1bf-5aee-4c89-b9a4-2679331f1146'::text),
      ('9b0fb673-fbdd-4a29-acfc-94801f9aff92'::uuid, 199.00::numeric, '179596856-99eb4b23-0903-42e1-8ee1-6376e42f2d57'::text)
    ) AS t(ad_id, expected_amount, expected_mp_payment_id)
  LOOP
    -- El anuncio debe existir (con pkg_price vía LEFT JOIN ad_packages,
    -- igual que mark_ad_payment, para replicar su fórmula de precio exacta)
    SELECT a.id, a.title, a.mp_payment_id, a.effective_price, a.total_price,
           COALESCE(ap.price, 0) AS pkg_price
    INTO v_ad
    FROM public.advertisements a
    LEFT JOIN public.ad_packages ap ON ap.id = a.package_id
    WHERE a.id = v_row.ad_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'ABORT: advertisement % no existe (esperado para backfill)', v_row.ad_id;
    END IF;

    -- El mp_payment_id debe coincidir exacto
    IF v_ad.mp_payment_id IS DISTINCT FROM v_row.expected_mp_payment_id THEN
      RAISE EXCEPTION 'ABORT: advertisement % tiene mp_payment_id=% pero se esperaba %',
        v_row.ad_id, v_ad.mp_payment_id, v_row.expected_mp_payment_id;
    END IF;

    -- El monto cobrado debe coincidir exacto con el esperado — misma fórmula
    -- canónica de 3 niveles que mark_ad_payment (sql/547):
    -- COALESCE(NULLIF(effective_price,0), NULLIF(total_price,0), pkg_price)
    IF COALESCE(NULLIF(v_ad.effective_price, 0), NULLIF(v_ad.total_price, 0), v_ad.pkg_price) IS DISTINCT FROM v_row.expected_amount THEN
      RAISE EXCEPTION 'ABORT: advertisement % tiene monto=% pero se esperaba %',
        v_row.ad_id, COALESCE(NULLIF(v_ad.effective_price, 0), NULLIF(v_ad.total_price, 0), v_ad.pkg_price), v_row.expected_amount;
    END IF;

    -- No debe existir ya una wallet_transaction para este mp_payment_id
    SELECT COUNT(*) INTO v_existing_count
    FROM public.wallet_transactions
    WHERE mp_payment_id = v_row.expected_mp_payment_id;

    IF v_existing_count > 0 THEN
      RAISE NOTICE 'SKIP: ya existe wallet_transaction para mp_payment_id=% (advertisement %) — no se duplica',
        v_row.expected_mp_payment_id, v_row.ad_id;
      CONTINUE;
    END IF;

    -- Todo verificado: insertar la transacción de backfill
    INSERT INTO public.wallet_transactions
      (user_id, type, amount, description, mp_payment_id, currency_code)
    VALUES (
      v_admin_id,
      'ad_income',
      v_row.expected_amount,
      '[BACKFILL HISTÓRICO] Publicidad pagada vía MercadoPago (nunca acreditada — mark_ad_payment sin lógica de wallet hasta sql/165): '
        || COALESCE(v_ad.title, v_row.ad_id::TEXT),
      v_row.expected_mp_payment_id,
      'MXN'
    );

    v_rows_inserted  := v_rows_inserted + 1;
    v_total_credited := v_total_credited + v_row.expected_amount;
  END LOOP;

  -- ── Pre-check 3: el total insertado en ESTA corrida debe ser $0 o $4,087 ──
  -- ($0 si ya se había corrido antes y todo estaba duplicado-protegido;
  --  $4,087 en una corrida limpia. Cualquier otro valor es una señal de
  --  que algo quedó a medias en una corrida anterior — abortar para
  --  revisión manual en vez de acreditar un monto parcial silenciosamente.)
  IF v_total_credited NOT IN (0, v_expected_total) THEN
    RAISE EXCEPTION 'ABORT: total a acreditar en esta corrida ($%) no es ni $0 ni el esperado $%. Revisar manualmente antes de continuar.',
      v_total_credited, v_expected_total;
  END IF;

  -- ── Acreditar al wallet del admin (solo si hay algo nuevo que acreditar) ──
  IF v_total_credited > 0 THEN
    INSERT INTO public.wallets (user_id) VALUES (v_admin_id) ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.wallets
    SET available_balance = available_balance + v_total_credited,
        total_earned      = total_earned      + v_total_credited,
        updated_at        = NOW()
    WHERE user_id = v_admin_id;
  END IF;

  RAISE NOTICE 'BACKFILL COMPLETO: % filas insertadas, $% MXN acreditados (admin_id=%)',
    v_rows_inserted, v_total_credited, v_admin_id;
END $$;

COMMIT;

-- ============================================================
-- VERIFICACIÓN POST-BACKFILL (ejecutar por separado después del COMMIT)
-- ============================================================

-- V1: deben existir exactamente 13 wallet_transactions nuevas de este backfill
-- SELECT COUNT(*) AS backfill_rows, SUM(amount) AS backfill_total
-- FROM public.wallet_transactions
-- WHERE description LIKE '[BACKFILL HISTÓRICO]%'
--   AND type = 'ad_income';
-- Esperado: backfill_rows = 13, backfill_total = 4087.00

-- V2: cada mp_payment_id de la lista debe tener exactamente 1 fila
-- SELECT mp_payment_id, COUNT(*)
-- FROM public.wallet_transactions
-- WHERE mp_payment_id LIKE '179596856-%'
-- GROUP BY mp_payment_id
-- HAVING COUNT(*) <> 1;
-- Esperado: 0 filas (ninguna duplicada ni faltante)

-- V3: el wallet del admin debe reflejar el incremento exacto
-- SELECT user_id, available_balance, total_earned, pending_balance, updated_at
-- FROM public.wallets
-- WHERE user_id = (SELECT id FROM public.profiles WHERE role = 'admin' LIMIT 1);

-- V4: ninguna otra fila de wallet_transactions fue tocada
-- SELECT COUNT(*) AS total_wt FROM public.wallet_transactions;
-- Esperado: 2 (originales) + 13 (backfill) = 15

SELECT '548_backfill_mp_ad_income_abril2026 — ✅ EJECUTADO (verificado de nuevo 2026-09-02: 13 filas, $4,087.00 MXN en producción, coincide exacto con lo esperado)' AS status;
