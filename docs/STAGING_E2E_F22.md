# Runbook de staging + matriz E2E — F2.2 (gate + resolución + exclusión Conekta)

**Estado: preparado, EN REVISIÓN. Nada desplegado, nada ejecutado.**
**Regla dura: producción (`sqgzyipqpewzbnfrtdqk`) permanece intacta. Todos los
comandos de este runbook llevan `--project-ref <STAGING_REF>` explícito —
nunca se usa `supabase link` para cambiar el vínculo persistente del repo.**

## Deslinde de responsabilidad

- **Yo preparé:** el código (ya commiteado), los comandos exactos, las
  consultas de verificación, y esta matriz de pruebas.
- **Tú ejecutas:** la creación de la rama, el despliegue, los pagos reales
  (tarjeta de prueba en la app / hosted checkout), los reenvíos de webhook,
  y me pegas los resultados de las consultas.
- No puedo manejar tu app móvil ni tus cuentas de Stripe/Conekta.

---

## PARTE 1 — Preparar la Preview Branch

1. Dashboard de Supabase → **Branches → New Branch**. Copia: `project ref`,
   `API URL`, `anon key`, `service_role key`.
2. Verifica visualmente que el ref de la URL es el de la rama, no
   `sqgzyipqpewzbnfrtdqk`.
3. Aplica el esquema en este orden exacto (SQL Editor de la rama):
   `514 → 516 → 518 → 519 → 520 (debe dar 21/21) → 521 → 521b → 521c → 522
   (debe dar 29/29)`.
4. Verificación de esquema listo:

```sql
SELECT
  (SELECT COUNT(*) FROM pg_proc WHERE proname IN
    ('confirm_reservation_payment_v2','resolve_payment_receipt',
     '_apply_confirmed_credit','can_schedule'))                    AS funcs_gate_4,
  (SELECT COUNT(*) FROM pg_tables WHERE tablename IN
    ('payment_attempts','payment_receipts','refund_intents',
     'admin_payment_evidence'))                                    AS tablas_4;
-- Esperado: 4 · 4
```

5. **Secrets de la rama** (Dashboard → Edge Functions → Secrets, o
   `supabase secrets set --project-ref <STAGING_REF> KEY=valor`):
   - `STRIPE_SECRET_KEY` = clave de **test mode** (`sk_test_...`)
   - `STRIPE_WEBHOOK_SECRET` = del endpoint de prueba que crearás en el Paso
     de la Parte 3 (`whsec_...`)
   - `CONEKTA_PRIVATE_KEY` = clave de **sandbox**
   - `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` de la propia rama (normalmente
     ya inyectadas automáticamente por Supabase para Edge Functions; confirma
     que no falten)

---

## PARTE 2 — Desplegar los 4 Edge Functions

⚠️ **BLOQUEADO hasta que confirmes 2 valores del dashboard de PRODUCCIÓN**
(Edge Functions → función → "Enforce JWT Verification") para:
- `create-conekta-order`: ON o OFF → **`<VALOR_1>`**
- `conekta-webhook`: ON u OFF → **`<VALOR_2>`**

No asumo ninguno de los dos. Reemplaza `<VALOR_1>`/`<VALOR_2>` abajo y
elige la línea de comando que corresponda a cada uno — nunca uses la que
no aplica.

**Nota de seguridad ya verificada (no depende de lo que confirmes):**
`create-conekta-order` exige y valida un JWT de usuario **dentro de su
propio código** ([líneas 66-71](../supabase/functions/create-conekta-order/index.ts#L66-L71):
`admin.auth.getUser(jwt)` con 401 propio si falta o es inválido) —
la bandera de la plataforma NO decide si el endpoint queda público, solo
decide quién emite el 401 (la plataforma o el código). Mismo patrón que
`create-payment-intent`. `conekta-webhook` en cambio no tiene ningún
chequeo de JWT/firma en el código — su única barrera es la re-consulta a
la API de Conekta con la llave privada — por lo que **necesita**
`Enforce JWT Verification = OFF` sin alternativa, ya que Conekta nunca
envía un JWT de Supabase.

`create-payment-intent` y `stripe-webhook` no quedan condicionados:
`supabase/config.toml` ya declara `verify_jwt = false` para ambos.

```bash
supabase functions deploy create-payment-intent --project-ref <STAGING_REF> --no-verify-jwt
supabase functions deploy stripe-webhook          --project-ref <STAGING_REF> --no-verify-jwt

# create-conekta-order — usa la línea que corresponda a <VALOR_1>:
supabase functions deploy create-conekta-order    --project-ref <STAGING_REF> --no-verify-jwt   # si <VALOR_1> = OFF
supabase functions deploy create-conekta-order    --project-ref <STAGING_REF>                   # si <VALOR_1> = ON (sin la bandera)

# conekta-webhook — usa la línea que corresponda a <VALOR_2>:
supabase functions deploy conekta-webhook         --project-ref <STAGING_REF> --no-verify-jwt   # si <VALOR_2> = OFF
supabase functions deploy conekta-webhook         --project-ref <STAGING_REF>                   # si <VALOR_2> = ON (sin la bandera)
```

⚠️ Si `<VALOR_2>` resultara ser **ON** en producción, avísame antes de
desplegar en staging: significaría que Conekta actualmente logra pasar el
gate de la plataforma sin JWT por algún otro mecanismo (poco probable,
pero no lo asumo), y habría que investigarlo antes de replicarlo.

Confirma cada despliegue exitoso en el dashboard (Edge Functions → lista, con
timestamp reciente).

---

## PARTE 3 — Webhooks de prueba

- **Stripe (test mode):** Dashboard → Developers → Webhooks → **Add
  endpoint** → URL `https://<STAGING_REF>.supabase.co/functions/v1/stripe-webhook`
  → eventos: `payment_intent.succeeded`, `charge.refund.updated`,
  `charge.refunded` (y los de Plus/promos si vas a probarlos, opcional).
  Copia el `whsec_...` a `STRIPE_WEBHOOK_SECRET` de la rama.
- **Conekta (sandbox):** Dashboard → Webhooks → nuevo endpoint sandbox →
  URL `https://<STAGING_REF>.supabase.co/functions/v1/conekta-webhook` →
  evento `order.paid`.
- Apunta el **frontend de pruebas** (app o Postman/curl autenticado) a la
  `API URL` de la rama para que `create-payment-intent`/`create-conekta-order`
  lean/escriban en esa base.

---

## PARTE 4 — Preparación de datos de prueba

Antes de la matriz, crea 1 grupo + 1 cliente + reservas frescas por caso (para
no reutilizar `client_key` entre pruebas). Snapshot de wallets ANTES de
empezar:

```sql
SELECT gw.group_id, gw.pending_balance, gw.pending_balance_usd,
       gw.total_earned, gw.total_earned_usd
FROM group_wallets gw WHERE gw.group_id = '<GROUP_ID>';

SELECT w.user_id, w.available_balance, w.available_balance_usd
FROM wallets w JOIN profiles p ON p.id = w.user_id WHERE p.role='admin';
```

Guarda estos números — son la base para calcular los deltas de "balances
correctos por moneda" en cada caso.

---

## PARTE 5 — Matriz de pruebas

**Consulta de verificación única** (parametrizada por reserva) — córrela
después de CADA caso, sustituyendo `<RESERVATION_ID>`:

```sql
SELECT
  (SELECT COUNT(*) FROM payment_attempts WHERE reservation_id = '<RESERVATION_ID>') AS attempts_total,
  (SELECT string_agg(id::text||'/'||status||'/'||COALESCE(provider_order_id,'-'), ' | ')
     FROM payment_attempts WHERE reservation_id = '<RESERVATION_ID>')              AS attempts_detalle,
  (SELECT COUNT(*) FROM payment_receipts WHERE reservation_id = '<RESERVATION_ID>') AS receipts_total,
  (SELECT string_agg(id::text||'/'||provider||'/'||provider_payment_id||'/'||result||'/'||money_state||'/'||
                     COALESCE(processor_fee_minor::text,'NULL('||processor_fee_status||')'), ' | ')
     FROM payment_receipts WHERE reservation_id = '<RESERVATION_ID>')              AS receipts_detalle,
  (SELECT COUNT(*) FROM wallet_transactions WHERE reservation_id = '<RESERVATION_ID>'
     AND type = 'credit_pending')                                                  AS creditos_grupo,
  (SELECT COUNT(*) FROM notifications WHERE (data->>'reservation_id') = '<RESERVATION_ID>') AS notificaciones_total,
  (SELECT r.status||'/'||r.payment_status||'/'||r.payout_status||'/'||r.currency_code||'/'||
          r.group_earnings||'/'||COALESCE(r.stripe_fee_amount::text,'NULL')
     FROM reservations r WHERE r.id = '<RESERVATION_ID>')                          AS reserva_estado;
```

Interpretación esperada de `receipts_detalle`: el fee debe ser un número real
o `NULL(not_captured)` — **jamás** un valor estimado. Compáralo contra el fee
real mostrado en el dashboard del proveedor para ese cargo específico.

### A · Stripe — pago exitoso
Crear reserva → `create-payment-intent` → pagar con tarjeta de prueba
(`4242 4242 4242 4242`) → esperar webhook. Verificar: `attempts_total=1`
(`created`), `receipts_total=1` (`confirmed/credited`), `creditos_grupo=1`,
`notificaciones_total` = 1 (owner) + miembros aceptados del grupo,
`reserva_estado` = `confirmed/paid/held/...`.

### B · Stripe — doble clic
Misma reserva, disparar `create-payment-intent` dos veces casi simultáneas
(dos pestañas o dos `curl` en paralelo) ANTES de pagar. Verificar:
`attempts_total=1` (el `client_key` es el mismo `Idempotency-Key`; Stripe
deduplica). Completar el pago una sola vez → mismos resultados que A.

### C · Stripe — reenvío de webhook
Tras A, en el dashboard de Stripe: Webhooks → el evento → **Resend** (o
`stripe events resend <id>` con Stripe CLI en test mode). Verificar: HTTP
200 del webhook, **sin cambios** en la consulta única (mismos conteos que
A — `already_processed`, sin segunda notificación, sin segundo
`wallet_transaction`).

### D · Stripe — monto incorrecto
Vía Stripe CLI test mode (dispara un evento firmado válidamente, a
diferencia de un payload forjado que fallaría la verificación de firma):
```bash
stripe trigger payment_intent.succeeded \
  --override payment_intent:amount=<monto_distinto_centavos> \
  --override payment_intent:metadata.reservation_id=<RESERVATION_ID>
```
Verificar: `receipts_detalle` con `result=amount_mismatch`,
`money_state=blocked_refund_pending`, `reserva_estado` con `payment_status=
paid_blocked` (status de reserva sin tocar), `creditos_grupo=0`. Nota: esta
prueba re-valida a nivel webhook una decisión ya probada a nivel RPC en
sql/520 (T8/T9) — opcional si el tiempo apremia.

### E · Conekta tarjeta — pago exitoso
Reserva nueva → `create-conekta-order` (method=card) → completar checkout
hosted con tarjeta de prueba de Conekta sandbox → esperar webhook.
Mismas verificaciones que A, con `provider=conekta` y `provider_payment_id`
= el **charge** de Conekta (no el order id).

### F · Conekta tarjeta — doble clic real
Dos invocaciones de `create-conekta-order` para la MISMA reserva casi
simultáneas (dos `curl` en paralelo, o script con `&` de fondo). Verificar
`attempts_total=1` y que en los logs de Conekta (Dashboard → Orders) exista
**exactamente 1 orden** para esa reserva — este es el caso que el mecanismo
de exclusión nuevo (`attemptLock.ts`) protege.

### G · Conekta tarjeta — reenvío de webhook
Igual que C pero reenviando el evento `order.paid` desde el dashboard
sandbox de Conekta (o re-`curl` el mismo payload capturado la primera vez
contra el endpoint de la rama). Mismos conteos que E, sin duplicar nada.

### H · Conekta SPEI — creación y reutilización sin duplicados
Reserva nueva, method=spei → `create-conekta-order` → **sin pagar todavía**,
volver a invocar `create-conekta-order` para la MISMA reserva (simula
usuario que refresca la pantalla antes de pagar) → debe reutilizar la
misma orden (`order_id` idéntico en ambas respuestas). Verificar
`attempts_total=1`, `status='created'`. Luego sí pagar por SPEI (o dejarlo
sin pagar si el sandbox no simula transferencias) — si pagas, mismas
verificaciones que E con `method=spei` y `discount_minor=10000` (100 MXN).

### I · Intento `creating` fresco — el segundo invocador recibe conflicto
**Reproducible por SQL, sin depender de timing real.** Reserva nueva →
calcula `amountCentavos` esperado (total_price×100, sin descuento) →
siembra manualmente el intento:
```sql
INSERT INTO payment_attempts
  (provider, client_key, reservation_id, expected_amount_minor, currency,
   method, discount_minor, msi_months, msi_fee_minor, status)
VALUES ('conekta', 'ord_<RESERVATION_ID>_<amountCentavos>', '<RESERVATION_ID>',
        <amountCentavos>, 'MXN', 'card', 0, 1, 0, 'creating');
```
Invoca `create-conekta-order` UNA vez para esa reserva. Esperado: HTTP
**409** (`checkout_in_progress`) tras ~12s de espera. Verificar:
`attempts_total=1` sin cambios (sigue `creating`), **cero** órdenes nuevas
en el dashboard de Conekta para esa reserva.

### J · Intento `creating` atascado (stale) — takeover único
Mismo seed que I pero con `updated_at` viejo:
```sql
UPDATE payment_attempts SET updated_at = NOW() - INTERVAL '30 seconds'
WHERE reservation_id = '<RESERVATION_ID>' AND status = 'creating';
```
Invoca `create-conekta-order` UNA vez. Esperado: responde con éxito
(`ok:true`) y crea **exactamente 1** orden real. Verificar: `attempts_total=1`,
`status='created'`, `provider_order_id` presente, **1 sola** orden en Conekta.

### K · Intento `abandoned` — reintento inmediato
Siembra un intento fallido:
```sql
INSERT INTO payment_attempts
  (provider, client_key, reservation_id, expected_amount_minor, currency,
   method, discount_minor, msi_months, msi_fee_minor, status)
VALUES ('conekta', 'ord_<RESERVATION_ID>_<amountCentavos>', '<RESERVATION_ID>',
        <amountCentavos>, 'MXN', 'card', 0, 1, 0, 'abandoned');
```
Invoca `create-conekta-order` UNA vez, cronometrando la respuesta. Esperado:
responde en segundos (no ~20s), crea 1 orden real, `attempts_total=1` con
`status='created'`.

---

## PARTE 6 — Reporte que necesito

Para cada caso A–K: **reservation_id**, **payment_attempts.id + status +
provider_order_id**, **payment_receipts.id + provider_payment_id + result**,
resultado de la consulta única completa, y el screenshot/ID de la orden o
cargo real en el dashboard del proveedor. Para los casos con dinero real
(A/B/C/E/F/G/H), además el delta de wallets (grupo y admin) contra el
snapshot de la Parte 4, por moneda.

## Criterios de paro

Cualquier desviación de lo esperado en cualquier caso → detente, no
continúes con el resto de la matriz, pégame el resultado exacto (incluidos
logs de la función en el dashboard) para diagnosticar antes de seguir.
Ningún caso debe requerir tocar producción — si algo falla, se corrige en
staging y se vuelve a desplegar ahí.
