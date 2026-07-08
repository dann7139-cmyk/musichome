# Integración Conekta — Plan de arquitectura de pagos

> **Estado:** planeado (pendiente de llaves sandbox + confirmación de capacidades Conekta).
> **Alcance:** agregar Conekta como **nuevo método de cobro para México**, manteniendo Stripe para USA/internacional. Ambos entran al **mismo flujo actual** de reservas/wallet/retenciones/liberaciones.

---

## 🔒 Regla de oro (invariante que NO se rompe)

**Las ganancias del grupo (`group_earnings`, `base_price`) nunca cambian por método de pago, descuento o promoción.** El grupo siempre recibe lo acordado. Cualquier ahorro o costo sale de la parte de **la plataforma** (comisión / ahorro), jamás del corte del grupo.

Si se respeta esto, el resto del sistema (wallet, GPS, 50/50, anti-fraude) **ni se entera** de qué proveedor cobró.

## Lo que NO se toca (garantía)

`group_wallets` · `confirm_full_payment_and_credit_wallet` (misma RPC para ambos proveedores) · `release_half_on_arrival` (candado GPS 50%) · `release_group_earnings_atomic` · gate de llegada (`arrival_verified`, sql/451) · disputas · payout manual (`request_payout`/`approve_payout`) · lógica de grupos.

Conekta entra **solo como adapter de cobro** en paralelo a Stripe → todo río abajo queda igual.

---

## Cómo funciona hoy el flujo de dinero (auditoría del código actual)

1. **Cobro (Stripe):** `create-payment-intent` crea un **PaymentIntent plano** — sin `transfer_data`/`application_fee`/Connect. **El 100% cae al balance de la plataforma en Stripe.** No va directo al grupo.
2. **Confirmación:** `stripe-webhook` → en `payment_intent.succeeded` llama
   `confirm_full_payment_and_credit_wallet(p_reservation_id, p_mp_payment_id = pi.id, p_amount_paid, p_stripe_fee)`.
   El `reservation_id` sale de `pi.metadata.reservation_id`.
3. **Wallet = ledger contable.** `group_wallets` (`pending_balance` / `available_balance`) solo registra *cuánto se le debe* al grupo. **No hay dinero apartado en ninguna cuenta del grupo**; el dinero físico está en el balance de Stripe/banco de la plataforma. (El código lo dice textual: *"No implica transferencia real."*)
4. **Retención → liberación:**
   - Pago → `pending_balance` (`payout_status = 'held'`).
   - Llegada GPS → `release_half_on_arrival` → 50% `pending → available` (`half_released`).
   - Fin del evento / cron 12h → `release_group_earnings_atomic` → resto `pending → available` (`released`), respetando el gate de llegada (`arrival_verified`, sql/451).
5. **Payout al grupo = manual.** `request_payout` (grupo da su CLABE) descuenta de `available_balance` y crea `payout_requests`; el admin hace `approve_payout` y **envía el SPEI a mano**. (Existe `release-deposit-payout` + `stripe-connect-*` con Stripe Connect transfers, pero es de un modelo viejo y **no es el flujo activo**.)
6. **Reembolsos:** `process-refund` es **bi-proveedor** — detecta `pi_...` → Stripe, numérico → MercadoPago. Modos `full` y `cancellation` (este último usa `compute_cancellation_charge` + `settle_cancellation`).

---

## Plan de integración Conekta

### A. Base de datos (SQL — se corre en Supabase)

| Cambio | Motivo |
|---|---|
| `ALTER TABLE reservations ADD COLUMN payment_provider TEXT DEFAULT 'stripe'` | **No existe hoy** (solo está en `countries`, legacy). Registra quién cobró cada reserva → para que el reembolso vuelva por el proveedor correcto. |
| (opcional) extender constraint `countries.payment_provider` para incluir `'conekta'` | Solo si se usa esa tabla como fuente del router. |

### B. Edge Functions NUEVAS

**1. `create-conekta-order`** — espejo de `create-payment-intent`:
- Autentica al cliente, lee la reserva (`total_price`, `msi_months`).
- Crea la **orden en Conekta** con `metadata.reservation_id`.
- MXN, MSI si aplica, **idempotencia por `reservation_id`**.
- Devuelve al frontend lo necesario para el checkout de Conekta.

**2. `conekta-webhook`** — espejo de la parte de éxito de `stripe-webhook`:
- Verifica **firma** del webhook (secret de Conekta).
- Saca `reservation_id` (de metadata) + el **id de la orden/charge** de Conekta.
- Llama **LA MISMA RPC**:
  ```
  confirm_full_payment_and_credit_wallet({
    p_reservation_id: reservationId,
    p_mp_payment_id:  conektaId,    // id de Conekta como referencia (para el refund)
    p_amount_paid:    amount,
    p_stripe_fee:     fee
  })
  ```
- Setea `reservations.payment_provider = 'conekta'`.
- **Idempotente** (Conekta reintenta webhooks).

⇒ Aterriza en el mismo `pending_balance` / `held`. Cero cambios río abajo.

### C. Edge Functions a MODIFICAR (mínimo)

**1. `process-refund/index.ts`** — hoy `isStripe = paymentId.startsWith('pi_')`. Agregar **rama Conekta**: si `reservations.payment_provider = 'conekta'` → refund vía Conekta API (parcial para cancelaciones/no-show). `settle_cancellation` / `process_refund_reversal` quedan **idénticos**.

**2. `stripe-webhook/index.ts`** — al confirmar, setear `payment_provider = 'stripe'` (1 línea, consistencia para el refund routing).

### D. Frontend — router por país

El checkout Stripe está **inline** en:
- `QuotePaymentScreen.tsx` (programadas): `create-payment-intent` → `initPaymentSheet` → `presentPaymentSheet`.
- `ReservationsScreen.tsx` (exprés/booking): mismo patrón.

**Router:** `if (event_country === 'MX') → flujo Conekta` ; `else → PaymentSheet Stripe actual (intacto)`.

**Recomendación:** extraer un helper `startCheckout(reservation)` que centralice el branch (no duplicar en 2 pantallas; el path Stripe US/intl queda sin tocar). El cliente ve **el checkout propio**; nunca "Conekta"/"Stripe".

### Radio de cambio

| Tipo | Cantidad |
|---|---|
| Columna nueva | 1 (`reservations.payment_provider`) |
| Edge Functions nuevas | 2 (`create-conekta-order`, `conekta-webhook`) |
| Edge Functions modificadas | 2 (`process-refund` +rama, `stripe-webhook` +1 línea) |
| Frontend | 1 helper `startCheckout` + branch en 2 checkouts |
| **Wallet / GPS / liberaciones / anti-fraude** | **0 (intactos)** |

---

## Capacidades de Conekta a confirmar ANTES de construir

- [ ] **Orders API** con `metadata` (para el `reservation_id`).
- [ ] **Webhooks** de pago exitoso + **firma** verificable.
- [ ] **Reembolsos parciales** (para cancelaciones / no-show).
- [ ] **MSI** por API (meses y tasas).
- [ ] **Idempotencia** en cargos y refunds.
- [ ] (a futuro) **Payouts a CLABE de terceros** por API — clave para dispersar rápido a grupos.

---

## Orden de construcción

1. **(Ahora)** Conseguir llaves sandbox + confirmar capacidades ↑.
2. **Núcleo:** `create-conekta-order` + `conekta-webhook` → validar que el pago entra al mismo flujo de wallet. **No tocar nada más hasta comprobar esto.**
3. Columna `payment_provider` + rama de refund Conekta.
4. Router `startCheckout` (MX→Conekta).

---

## Roadmap posterior (diseñado, NO construido aún)

### Paso 2 — Descuento por método de pago
Incentivo tipo *"Ahorra $X pagando por transferencia"*. **Primero números reales**, luego se decide el %:
```
ahorro          = costo_tarjeta − costo_transferencia(SPEI/OXXO)
descuento_cliente = ahorro × %compartido     (SIEMPRE ≤ ahorro)
margen_extra_plataforma = ahorro − descuento_cliente
```
- El descuento sale de la comisión/precio al cliente, **nunca de `group_earnings`** (regla de oro).
- SPEI **no tiene contracargos** → ahorro adicional real.
- Requiere: tarifas negociadas reales de Stripe MX y Conekta.

### Paso 3 — Pagos a meses visibles
- **MSI con tarjeta:** YA existe (`create-payment-intent` usa `installments` + `MSI_FEE_RATES`; el fee MSI ya es revenue de la plataforma). Falta **UI**: mostrarlo fuerte (*"Desde $X al mes"*, `mensualidad = total × (1 + msi_fee_rate) / meses`). Cero cambio al wallet.
- **BNPL sin tarjeta** (Aplazo / Kueski Pay / partner Conekta): integración **separada**, sujeta a aprobación del proveedor. Entra como otro `payment_provider` que cae en la misma RPC de wallet.

### Paso 4 — Payouts rápidos a grupos
Meta: cuando se libere el 50% en la llegada, que el grupo tenga el dinero rápido (idealmente automático).

| Camino | Velocidad MX | Nota |
|---|---|---|
| Stripe Connect (integración dormida) | media | depende del ciclo de payout de Stripe |
| **Conekta payouts (STP/SPEI)** | **instantáneo** | solo si su API dispersa a CLABE de terceros |
| STP directo | instantáneo | más compliance propio |

Probable split por país (igual que el cobro): **MX → Conekta/SPEI**, **US → Stripe Connect**, disparado por `release_half_on_arrival` / `release_group_earnings_atomic` al marcar `available`.

> ⚠️ **Nota regulatoria:** como el dinero vive físicamente en la plataforma (modelo de custodia), aplica la conversación de **Ley Fintech / IFPE** con un abogado fintech mexicano. Conekta no cambia ese modelo; solo agrega una forma de cobrar.
