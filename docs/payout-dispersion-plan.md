# Plan de retiro instantáneo a grupos (dispersión SPEI)

**Meta:** el grupo pide su retiro y le llega a su CLABE **al instante** (segundos), para
pagar rápido a sus compañeros.

## Decisión de riel (2026-07-08)

| Opción | Velocidad | Veredicto |
|---|---|---|
| Stripe Connect (MX) | Días hábiles | ❌ descartado (lento + onboarding por grupo) |
| Conekta Dispersiones | Día hábil siguiente (T+1) | ❌ descartado (no instantáneo; requiere prefondeo) |
| **Agregador SPEI-out (Fintoc / Bitso Business)** | **Segundos, 24/7** | ✅ **elegido** (instantáneo + onboarding ligero) |
| STP directo | Segundos | Alternativa (onboarding pesado) |

**Estado:** formulario de contacto enviado a proveedor(es). Conviene aplicar a **Fintoc**
y **Bitso Business** a la vez y quedarse con el que apruebe más rápido / salga más barato.

## Preguntas a confirmar con el proveedor
1. **Costo por dispersión** (y por volumen).
2. **Tiempo real** de acreditación (¿segundos de verdad?).
3. **Onboarding/KYC** de Daricefy: requisitos y tiempo.
4. **Prefondeo**: ¿hay que mantener saldo con ellos para dispersar?
5. ¿Dispersan a **CLABE de terceros** por API? (Fintoc/Bitso: sí.)
6. ¿Piden **KYC del destinatario** (el grupo)?

## Lo que necesito para construir
- **API Key de dispersiones** (producción).
- **Link a la documentación** del endpoint de payout SPEI.

## Arquitectura a construir (cuando haya API Key)
- Edge function **`disperse-payout`**, **encapsulado (adaptador)** — igual patrón que
  `verifyConektaPayment`: si mañana se cambia de proveedor, se toca solo el adaptador.
- Se dispara al **aprobar el retiro** (o al solicitarlo, según política).
- Estados: `pending → dispersado → confirmado` (confirmación por webhook del proveedor).
- **Reconciliación** de estatus de dispersión.
- **Guardas anti-fraude:** límites de retiro, verificar CLABE/titular del grupo,
  retención en el primer retiro.

## Estado actual del retiro (ya funciona, manual)
- `request_withdrawal` corregido (sql/460): lee/descuenta de **`group_wallets`** (antes
  leía la tabla vieja `wallets` y los grupos no podían retirar).
- Botón "Retirar" destrabado (se quitó el candado `!stripeOk`) — el grupo pide por CLABE.
- Hoy: el grupo solicita → admin marca `completed` y transfiere a mano.
  → El `disperse-payout` automatiza este último paso.

## Tesorería (tener en el radar)
- Todos los rieles piden **prefondeo**: mantener saldo con el proveedor de dispersión.
- El dinero llega por Conekta (cobro MX) y Stripe (meses). Hay que **mover fondos** al
  proveedor de dispersión para cubrir los retiros. Es tarea operativa, no de código.

## Pendiente aparte
- Verificar `admin_refund_withdrawal` (ruta de rechazo de retiro): confirmar que reingresa
  a `group_wallets` y no a la tabla vieja `wallets` (mismo bug que arregló sql/460).
