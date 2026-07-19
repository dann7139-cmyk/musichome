# Guion de concurrencia F2.2 — dos pestañas (gate de pagos v2) — v2 CORREGIDO

**Estado: EN REVISIÓN — no ejecutar hasta aprobación.**
**Entorno: EXCLUSIVAMENTE Supabase Branch / staging / clon. PROHIBIDO en producción.**

## Decisión de entorno (Opción 1)

Este guion corre solo en una rama o proyecto de staging que contenga el esquema
con sql/514, 516, 518 y 519 aplicados (una Branch de Supabase clona el esquema de
producción; un proyecto staging nuevo requiere correr los sql en orden).

Por qué la rama resuelve los riesgos 1 y 2 de raíz:
- **Perfiles:** se usa EXCLUSIVAMENTE un perfil dedicado de pruebas:
  `test-2tabs@daricefy.test`, creado en la rama desde el dashboard de Auth
  (su fila en profiles la genera el trigger de auth). El setup ABORTA si no
  existe — jamás elige otro perfil automáticamente. Ningún usuario real
  participa ni recibe nada.
- **Wallets:** la wallet del "admin" de la rama es un clon desechable. Ningún
  balance real cambia, ningún ledger real se mezcla, y el cleanup NO depende de
  compensar saldos de producción. (El cleanup igualmente revierte el crédito
  del admin-clon, por si reutilizas la rama para más pruebas.)

## Candado duro anti-producción (sentinela de entorno)

TODOS los bloques de escritura de este guion ABORTAN si no existe la marca de
staging. La marca se crea UNA vez, SOLO en la rama (jamás en producción):

```sql
-- ⚠️ SOLO EN LA RAMA/STAGING — JAMÁS ejecutar esto en producción
INSERT INTO payment_config (key, value, description)
VALUES ('environment', 'staging', 'Marca de entorno de pruebas — nunca debe existir en producción')
ON CONFLICT (key) DO NOTHING;
```

Producción no tiene esta clave → si por error pegas el setup allí, aborta sin
escribir nada.

## Identificadores únicos por corrida (test_run_id)

El setup genera un `test_run_id` (T2B_YYYYMMDDHHMMSS) y lo guarda en
`payment_config` — todos los bloques lo leen de ahí, así que NO hay que copiar
IDs a mano ni editar los SQL. Todo lo creado lo lleva:

- grupo: `__TEST_2TABS_<run>` · dirección: `Av. Prueba <run>`
- client keys: `<run>_k_m1/2` · órdenes: `<run>_ord_m1/2` · cargos: `<run>_ch_m1/2`

El cleanup filtra por ese run, muestra los conteos antes de borrar y aborta si
algo no está etiquetado.

## Qué NO participa

Cero llamadas externas: todo es SQL contra la rama. La RPC no hace red; los
webhooks, EFs, Stripe y Conekta no participan; las órdenes/cargos son cadenas
sintéticas inexistentes en cualquier proveedor. Ningún pago real.

## Orden de ejecución completo (aprobado)

1. Crear la Supabase Branch.
2. Confirmar que 514, 516, 518 y 519 existen en la rama.
3. Crear el usuario dedicado `test-2tabs@daricefy.test` en Auth de la rama.
4. Insertar la sentinela `environment=staging` (solo en la rama).
5. **Verificar visualmente el project ref de la rama en la URL** — sin esto no se ejecuta nada.
6. Preflight → `1 · 0 · 0 · 4 · 2 · 1 · <uuid>`.
7. Setup → `run · 1 · 2 · 2`.
8. Guion A + verificación A.
9. Guion B + verificación B.
10. Guion C + verificación C.
11. Cleanup + ceros finales.
12. Eliminar la rama.

Las claves `environment=staging` y `test_run_id` viven SOLO en la rama: no
forman parte de ningún archivo sql/ del repo (no están en 519 ni en ninguna
migración) y ningún dato de la rama se fusiona de vuelta — el branching de
Supabase solo propaga migraciones declaradas, y estas claves se insertan a
mano en la rama y mueren con ella en el paso 12.

---

## PASO 1 — PREFLIGHT (solo lectura, obligatorio)

```sql
SELECT
  (SELECT COUNT(*) FROM payment_config WHERE key='environment' AND value='staging') AS entorno_staging_1,
  (SELECT COUNT(*) FROM payment_config WHERE key='test_run_id')                     AS run_previo_0,
  (SELECT COUNT(*) FROM groups WHERE name ~ '^__TEST_2TABS')                        AS grupos_residuales_0,
  (SELECT COUNT(*) FROM pg_tables WHERE tablename IN
    ('payment_attempts','payment_receipts','refund_intents','payment_config'))      AS gate_tablas_4,
  (SELECT COUNT(*) FROM pg_proc WHERE proname IN
    ('can_schedule','confirm_reservation_payment_v2'))                              AS gate_funcs_2,
  (SELECT COUNT(*) FROM profiles WHERE email = 'test-2tabs@daricefy.test')          AS perfil_test_1,
  (SELECT id::text FROM profiles WHERE email = 'test-2tabs@daricefy.test')          AS perfil_test_id;
```

**Criterio de paro:** debe dar `1 · 0 · 0 · 4 · 2 · 1 · <uuid>`.
- `entorno_staging_1 = 0` → estás en producción o falta la sentinela → NO seguir.
- `run_previo_0 > 0` o residuos → corrida anterior sin limpiar → limpiar primero.
- `perfil_test_1 = 0` → crear el usuario `test-2tabs@daricefy.test` en Auth de la
  rama antes de continuar. El setup NO elige otro perfil: aborta.

Confirma además, manualmente, que la URL del proyecto en el dashboard es la de
la rama/staging (no el ref de producción).

## PASO 2 — SETUP (una corrida; aborta solo si falta la sentinela)

```sql
BEGIN;
DO $$
DECLARE
  v_run  TEXT;
  v_user UUID;
  v_g    UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM payment_config WHERE key='environment' AND value='staging') THEN
    RAISE EXCEPTION 'ABORTADO: sin marca de staging — esto parece PRODUCCIÓN. No se escribió nada.';
  END IF;
  IF EXISTS (SELECT 1 FROM payment_config WHERE key='test_run_id') THEN
    RAISE EXCEPTION 'ABORTADO: hay un test_run_id previo sin limpiar. Corre el cleanup primero.';
  END IF;

  v_run := 'T2B_' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS');
  INSERT INTO payment_config (key, value, description)
  VALUES ('test_run_id', v_run, 'Corrida activa del guion de concurrencia F2.2');

  SELECT id INTO v_user FROM profiles WHERE email = 'test-2tabs@daricefy.test';
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'ABORTADO: no existe el perfil dedicado test-2tabs@daricefy.test. Créalo en Auth de la rama. NO se elige otro perfil.';
  END IF;

  INSERT INTO groups (name, owner_id, state, country, is_active)
  VALUES ('__TEST_2TABS_' || v_run, v_user, 'Jalisco', 'México', false)
  RETURNING id INTO v_g;

  INSERT INTO reservations (group_id, client_id, event_date, event_time, hours_count,
                            status, payment_status, total_price, base_price, address)
  SELECT v_g, v_user, d.event_date, TIME '18:00', 3,
         'pending_payment', 'unpaid', 1200, 1000, 'Av. Prueba ' || v_run
  FROM (VALUES (DATE '2031-01-01'), (DATE '2031-01-02')) AS d(event_date);

  INSERT INTO payment_attempts (provider, client_key, provider_order_id, reservation_id,
                                expected_amount_minor, currency, method, status)
  SELECT 'stripe',
         v_run || CASE r.event_date WHEN DATE '2031-01-01' THEN '_k_m1' ELSE '_k_m2' END,
         v_run || CASE r.event_date WHEN DATE '2031-01-01' THEN '_ord_m1' ELSE '_ord_m2' END,
         r.id, 120000, 'MXN', 'card', 'created'
  FROM reservations r WHERE r.group_id = v_g;

  RAISE NOTICE 'SETUP OK — test_run_id = %', v_run;
END $$;
COMMIT;

-- Verificación del setup (esperado: run · 1 · 2 · 2)
SELECT
  (SELECT value FROM payment_config WHERE key='test_run_id')                          AS run,
  (SELECT COUNT(*) FROM groups
    WHERE name = '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id')) AS grupo_1,
  (SELECT COUNT(*) FROM reservations
    WHERE address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')) AS reservas_2,
  (SELECT COUNT(*) FROM payment_attempts
    WHERE client_key LIKE (SELECT value FROM payment_config WHERE key='test_run_id') || '%')     AS attempts_2;
```

---

## GUION A — Lock timeout real (sin efectos)

**Pestaña 1** (retiene el carril del grupo 20 segundos, una corrida):

```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext(
  (SELECT id::text FROM groups WHERE name =
    '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id'))));
SELECT pg_sleep(20);
COMMIT;
```

**Pestaña 2** (dispara DENTRO de los 20s):

```sql
SELECT public.confirm_reservation_payment_v2(
  'stripe',
  (SELECT value || '_ord_m1' FROM payment_config WHERE key='test_run_id'),
  (SELECT value || '_ch_m1'  FROM payment_config WHERE key='test_run_id'),
  (SELECT r.id FROM reservations r
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND r.event_date = DATE '2031-01-01'),
  120000,'MXN','card', NULL,NULL, NULL);
```

**Esperado:** espera ~5s y devuelve `{"result": "temporary_lock_timeout"}`. Cero escrituras.

**Verificación A (esperado: 0 · created · pending_payment/unpaid · 0):**

```sql
SELECT
  (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id =
    (SELECT value || '_ch_m1' FROM payment_config WHERE key='test_run_id'))          AS receipts_0,
  (SELECT status FROM payment_attempts WHERE client_key =
    (SELECT value || '_k_m1' FROM payment_config WHERE key='test_run_id'))           AS attempt_created,
  (SELECT r.status || '/' || r.payment_status FROM reservations r
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND r.event_date = DATE '2031-01-01')                                          AS reserva,
  (SELECT COUNT(*) FROM group_wallets gw JOIN groups g ON g.id = gw.group_id
    WHERE g.name = '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND gw.pending_balance <> 0)                                                   AS wallet_0;
```

**Paro A:** resultado ≠ `temporary_lock_timeout` o cualquier escritura → detener, pegar, NO limpiar.

---

## GUION B — Mismo pago simultáneo (idempotencia bajo carrera)

**Pestaña 1** (confirma m1 y retiene el lock ~3s antes de commitear):

```sql
BEGIN;
SELECT public.confirm_reservation_payment_v2(
  'stripe',
  (SELECT value || '_ord_m1' FROM payment_config WHERE key='test_run_id'),
  (SELECT value || '_ch_m1'  FROM payment_config WHERE key='test_run_id'),
  (SELECT r.id FROM reservations r
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND r.event_date = DATE '2031-01-01'),
  120000,'MXN','card', NULL,NULL, NULL);
SELECT pg_sleep(3);
COMMIT;
```

**Pestaña 2** (dispara inmediatamente después — la MISMA llamada exacta que pestaña 1).

**Esperado:** pestaña 1 → `confirmed`; pestaña 2 → espera lo que reste del lock y
devuelve `already_processed`.

Nota de tiempos (corregida): con retención de ~3s y `lock_timeout = 5s`, el
timeout es imposible en este guion — cuanto más tarde dispares la pestaña 2,
MENOS espera (si dispara tras el COMMIT, entra sin esperar y da
`already_processed` igual). El caso timeout ya lo cubre el Guion A con 20s.
También válido: si disparas la pestaña 2 ANTES que la 1, los roles se invierten
(2 → `confirmed`, 1 → `already_processed`) — el invariante es el mismo.

**Verificación B (esperado: 1 · confirmed/credited · 1 · 1000):**

```sql
SELECT
  (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id =
    (SELECT value || '_ch_m1' FROM payment_config WHERE key='test_run_id'))          AS receipts_1,
  (SELECT result || '/' || money_state FROM payment_receipts WHERE provider_payment_id =
    (SELECT value || '_ch_m1' FROM payment_config WHERE key='test_run_id'))          AS receipt_estado,
  (SELECT COUNT(*) FROM wallet_transactions wt
     JOIN reservations r ON r.id = wt.reservation_id
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND wt.type = 'credit_pending')                                                AS creditos_1,
  (SELECT gw.pending_balance FROM group_wallets gw JOIN groups g ON g.id = gw.group_id
    WHERE g.name = '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id')) AS bal_1000;
```

**Paro B:** 2 receipts, 2 créditos o balance ≠ 1000 → el UNIQUE falló bajo
carrera = fallo crítico → detener, pegar, NO limpiar.

---

## GUION C — Dos pagos del mismo grupo (serialización sin deadlock)

**Pestaña 1** (retiene el carril 3s):

```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext(
  (SELECT id::text FROM groups WHERE name =
    '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id'))));
SELECT pg_sleep(3);
COMMIT;
```

**Pestaña 2** (dispara durante el sueño — pago de la OTRA reserva, m2):

```sql
SELECT public.confirm_reservation_payment_v2(
  'stripe',
  (SELECT value || '_ord_m2' FROM payment_config WHERE key='test_run_id'),
  (SELECT value || '_ch_m2'  FROM payment_config WHERE key='test_run_id'),
  (SELECT r.id FROM reservations r
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND r.event_date = DATE '2031-01-02'),
  120000,'MXN','card', NULL,NULL, NULL);
```

**Esperado:** la pestaña 2 espera ~2-3s (serialización por grupo) y devuelve
`confirmed`. Sin error 40P01.

**Verificación C (esperado: 1 · 2 · 2000 · confirmed/paid · confirmed/paid):**

```sql
SELECT
  (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id =
    (SELECT value || '_ch_m2' FROM payment_config WHERE key='test_run_id'))          AS receipt_m2_1,
  (SELECT COUNT(*) FROM wallet_transactions wt
     JOIN reservations r ON r.id = wt.reservation_id
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')
      AND wt.type = 'credit_pending')                                                AS creditos_2,
  (SELECT gw.pending_balance FROM group_wallets gw JOIN groups g ON g.id = gw.group_id
    WHERE g.name = '__TEST_2TABS_' || (SELECT value FROM payment_config WHERE key='test_run_id')) AS bal_2000,
  (SELECT string_agg(r.status || '/' || r.payment_status, ' · ' ORDER BY r.event_date)
     FROM reservations r
    WHERE r.address = 'Av. Prueba ' || (SELECT value FROM payment_config WHERE key='test_run_id')) AS reservas;
```

**Paro C:** `40P01` (deadlock) = evidencia crítica contra el orden de locks →
detener TODO y pegar el error completo · balance ≠ 2000 → detener.

---

## CLEANUP (una corrida — SOLO al terminar o tras capturar evidencia)

Filtra por el `test_run_id`, muestra los conteos ANTES de borrar, aborta si
detecta filas no etiquetadas, revierte el crédito del admin-clon con el monto
exacto del ledger, y elimina la clave del run al final.

```sql
BEGIN;
DO $$
DECLARE
  v_run          TEXT;
  v_group        UUID;
  v_res          UUID[];
  v_res_txt      TEXT[];
  v_admin        UUID;
  v_admin_credit NUMERIC := 0;
  v_mal          INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM payment_config WHERE key='environment' AND value='staging') THEN
    RAISE EXCEPTION 'ABORTADO: sin marca de staging — esto parece PRODUCCIÓN.';
  END IF;
  SELECT value INTO v_run FROM payment_config WHERE key='test_run_id';
  IF v_run IS NULL THEN
    RAISE NOTICE 'Nada que limpiar: no hay test_run_id activo';
    RETURN;
  END IF;

  SELECT id INTO v_group FROM groups WHERE name = '__TEST_2TABS_' || v_run;
  v_res     := ARRAY(SELECT id      FROM reservations WHERE group_id = v_group);
  v_res_txt := ARRAY(SELECT id::text FROM reservations WHERE group_id = v_group);

  -- Guard: TODO lo que se va a borrar debe estar etiquetado con el run
  SELECT COUNT(*) INTO v_mal FROM reservations
  WHERE id = ANY(v_res) AND address <> 'Av. Prueba ' || v_run;
  IF v_mal > 0 THEN
    RAISE EXCEPTION 'ABORTADO: % reservas del grupo NO llevan la etiqueta del run %', v_mal, v_run;
  END IF;

  -- Conteos que se van a eliminar (quedan visibles en los NOTICE)
  RAISE NOTICE 'A borrar [run %]: receipts=%, refunds=%, attempts=%, ledger=%, reservas=%, grupo=%',
    v_run,
    (SELECT COUNT(*) FROM payment_receipts  WHERE provider_payment_id LIKE v_run || '%' OR reservation_id = ANY(v_res)),
    (SELECT COUNT(*) FROM refund_intents    WHERE provider_payment_id LIKE v_run || '%' OR reservation_id = ANY(v_res)),
    (SELECT COUNT(*) FROM payment_attempts  WHERE client_key LIKE v_run || '%'),
    (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = ANY(v_res)),
    COALESCE(array_length(v_res,1),0),
    (v_group IS NOT NULL)::TEXT;

  -- Revertir crédito del admin-clon (exacto, desde el ledger)
  SELECT user_id, COALESCE(SUM(amount),0) INTO v_admin, v_admin_credit
  FROM wallet_transactions
  WHERE reservation_id = ANY(v_res) AND user_id IS NOT NULL AND type='platform_income'
  GROUP BY user_id;
  IF v_admin IS NOT NULL AND v_admin_credit > 0 THEN
    UPDATE wallets SET
      available_balance = available_balance - v_admin_credit,
      total_earned      = total_earned      - v_admin_credit,
      updated_at        = NOW()
    WHERE user_id = v_admin;
    RAISE NOTICE 'Revertido crédito admin-clon: %', v_admin_credit;
  END IF;

  DELETE FROM refund_intents       WHERE provider_payment_id LIKE v_run || '%' OR reservation_id = ANY(v_res);
  DELETE FROM payment_receipts     WHERE provider_payment_id LIKE v_run || '%' OR reservation_id = ANY(v_res);
  DELETE FROM payment_attempts     WHERE client_key LIKE v_run || '%';
  DELETE FROM wallet_transactions  WHERE reservation_id = ANY(v_res);
  DELETE FROM group_wallets        WHERE group_id = v_group;
  DELETE FROM notifications        WHERE (data->>'reservation_id') = ANY(v_res_txt);
  DELETE FROM financial_audit_logs WHERE entity_id = ANY(v_res);
  DELETE FROM reservations         WHERE id = ANY(v_res);
  DELETE FROM groups               WHERE id = v_group;
  DELETE FROM payment_config       WHERE key = 'test_run_id';

  RAISE NOTICE 'CLEANUP OK — run % eliminado', v_run;
END $$;
COMMIT;

-- Verificación post-cleanup (esperado: todo 0)
SELECT
  (SELECT COUNT(*) FROM payment_config WHERE key='test_run_id')       AS run_0,
  (SELECT COUNT(*) FROM groups        WHERE name ~ '^__TEST_2TABS')   AS grupos_0,
  (SELECT COUNT(*) FROM reservations  WHERE address LIKE 'Av. Prueba T2B_%') AS reservas_0,
  (SELECT COUNT(*) FROM payment_attempts WHERE client_key LIKE 'T2B_%')      AS attempts_0,
  (SELECT COUNT(*) FROM payment_receipts WHERE provider_payment_id LIKE 'T2B_%') AS receipts_0,
  (SELECT COUNT(*) FROM refund_intents  WHERE provider_payment_id LIKE 'T2B_%')  AS refunds_0;
```

## Criterios de paro generales

1. Preflight ≠ `1 · 0 · 0 · 4 · 2 · ≥1` → no seguir.
2. Cualquier resultado distinto al esperado (salvo los "también válido" de B) →
   detener, pegar el resultado tal cual, NO ejecutar el cleanup (preserva evidencia).
3. Deadlock `40P01` → detener todo; evidencia crítica.
4. El cleanup solo al final; sus NOTICE muestran qué borró y cuánto revirtió.
5. Post-cleanup todo 0; si algo queda > 0, pegar antes de tocar nada.
