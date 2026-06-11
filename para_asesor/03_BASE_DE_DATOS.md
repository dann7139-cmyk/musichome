# Daricefy — Base de Datos (Supabase / PostgreSQL)

---

## TABLAS PRINCIPALES

### `profiles`
Perfil de cada usuario (cliente, grupo, admin, talent).
```
id                      UUID (FK → auth.users)
full_name               TEXT
role                    TEXT  ('client' | 'group' | 'admin' | 'talent')
avatar_url              TEXT
stripe_customer_id      TEXT  ← ID de cliente en Stripe (se crea al primer pago)
stripe_account_id       TEXT  ← Para grupos que reciben pagos
stripe_onboarding_completed  BOOLEAN
```

### `groups`
Perfil del grupo musical.
```
id                  UUID
owner_id            UUID → profiles.id
name                TEXT
description         TEXT
genre               TEXT  (Norteño, Banda, Mariachi, etc.)
city                TEXT  ← para matching con solicitudes
state               TEXT
latitude            FLOAT ← para ordenar por proximidad
longitude           FLOAT
is_verified         BOOLEAN
is_active           BOOLEAN
rating              FLOAT
profile_image       TEXT  (URL Supabase Storage)
promo_video         TEXT  (URL Supabase Storage)
nivel               TEXT  ('bronce' | 'plata' | 'oro' | 'platino')
stripe_account_id   TEXT
```

### `event_requests`
Solicitudes express del cliente (flujo inmediato).
```
id                      UUID
client_id               UUID → profiles.id
genre                   TEXT  (género musical solicitado)
event_type              TEXT  (boda, cumpleanos, fiesta, etc.)
event_date              DATE  (siempre el día de hoy en Express)
event_time              TIME
hours                   INT   (duración solicitada)
guest_count             INT

-- Ubicación (visible para grupos sin dirección exacta)
location_city           TEXT
location_municipio      TEXT  ← municipio real (ej: Zapopan)
location_estado         TEXT
city                    TEXT  ← normalizada para búsqueda/matching

-- Ubicación exacta (solo visible tras el pago)
location_address        TEXT
latitude                FLOAT ← del MapAddressPicker
longitude               FLOAT ← del MapAddressPicker

-- Detalles del lugar
venue_covered           TEXT  (si/no/no_se)
venue_size              TEXT
needs_sound             TEXT

comments                TEXT
status                  TEXT  ('open' | 'en_negociacion' | 'accepted' | 'cancelled' | 'expired')

-- Cuando un grupo propone
negotiating_group_id    UUID → groups.id (via owner_id)
proposal_data           JSONB  { price, start_time, arrival_time, notes, total_amount }

-- Cuando el cliente acepta
accepted_by_group_id    UUID
accepted_reservation_id UUID
```

### `quotes`
Solicitudes de cotización programadas del cliente.
```
id                  UUID
client_id           UUID → profiles.id
group_id            UUID → groups.id
event_type          TEXT
event_date          DATE  ← fecha futura elegida por el cliente
event_time          TIME

-- Ubicación exacta (guardada desde MapAddressPicker)
event_address       TEXT
event_municipio     TEXT
event_estado        TEXT
latitude            FLOAT ← coords exactas del lugar
longitude           FLOAT

duration_hours      INT   (mín 3)
num_personas        INT
venue_covered       TEXT
venue_size          TEXT
needs_sound         TEXT
comments            TEXT

-- Respuesta del grupo
status              TEXT  ('pending' | 'quoted' | 'accepted' | 'rejected' | 'expired')
price_per_hour      NUMERIC
travel_cost         NUMERIC
total_amount        NUMERIC
overtime_1h_price   NUMERIC  ← precio +1h extra (ya con 10% descontado para el grupo)
overtime_2h_price   NUMERIC
overtime_3h_price   NUMERIC
group_notes         TEXT
num_integrantes     INT
member_distribution JSONB  [ { amount: number }, ... ]
```

### `reservations`
Reserva confirmada (creada desde quote o event_request).
```
id                      UUID
client_id               UUID → profiles.id
group_id                UUID → groups.id
quote_id                UUID → quotes.id         (flujo Programado)
event_request_id        UUID → event_requests.id (flujo Express)

event_date              DATE
event_time              TIME
address                 TEXT  (dirección del evento)

-- Precios
total_price             NUMERIC
platform_commission     NUMERIC  (10% del total)
group_earnings          NUMERIC  (total - commission)

-- Status del flujo
status                  TEXT  ('pending' | 'pending_group_confirmation' | 'accepted' |
                               'confirmed' | 'in_progress' | 'completed' |
                               'cancelled' | 'rejected' | 'expired')

-- Pago
payment_status          TEXT  ('deposit_pending' | 'deposit_paid' | 'fully_paid')
payment_intent_id       TEXT  (Stripe PaymentIntent ID)
stripe_payment_method_id TEXT  (para cobro automático del restante)

-- Timer del evento
event_started_at        TIMESTAMPTZ  (cuando el grupo inicia)
event_ended_at          TIMESTAMPTZ  (cuando se completa)
group_arrived_at        TIMESTAMPTZ  (cuando el grupo llega)
break_type              TEXT  ('A' | 'B' | 'C' | 'D')
hours_count             INT   (horas contratadas — express)

-- Pago distribuido
deposit_transfer_id     TEXT
final_transfer_id       TEXT
payout_completed        BOOLEAN
```

### `packages`
Paquetes de servicio que ofrece cada grupo.
```
id              UUID
group_id        UUID → groups.id
name            TEXT  (ej: "Paquete Básico")
duration_hours  INT
price           NUMERIC
extra_hour_price NUMERIC
description     TEXT
```

### `job_invitations`
Integrantes del grupo (miembros + invitados de trabajo).
```
id              UUID
group_id        UUID → groups.id
invited_user_id UUID → profiles.id
invitation_type TEXT  ('membership' | 'job')
status          TEXT  ('pending' | 'accepted' | 'rejected')
```

### `notifications`
Notificaciones del sistema.
```
id        UUID
user_id   UUID → profiles.id
type      TEXT  (new_quote_request | quote_accepted | deposit_paid | etc.)
title     TEXT
body      TEXT
data      JSONB  (datos adicionales: reservation_id, screen, etc.)
read      BOOLEAN
created_at TIMESTAMPTZ
```

---

## RELACIONES CLAVE

```
profiles (1) ───── (N) groups              [owner_id]
profiles (1) ───── (N) event_requests      [client_id]
profiles (1) ───── (N) quotes              [client_id]
groups   (1) ───── (N) quotes              [group_id]
groups   (1) ───── (N) reservations        [group_id]
groups   (1) ───── (N) packages            [group_id]
groups   (1) ───── (N) job_invitations     [group_id]
quotes   (1) ───── (0..1) reservations     [quote_id]
event_requests (1) ─── (0..1) reservations [event_request_id]
reservations (1) ── (N) notifications      (indirecto, por user_id de group/client)
```

---

## CICLO DE VIDA DE STATUS

### event_requests (flujo Express)
```
open
  ↓ grupo propone
en_negociacion
  ↓ cliente acepta        ↓ cliente rechaza
accepted                 open (vuelve a estar disponible)
  ↓ también puede ir a:
cancelled (cliente cancela)
expired   (pasa el tiempo sin respuesta)
```

### quotes (flujo Programado)
```
pending   ← cliente envía solicitud
  ↓ grupo responde
quoted    ← grupo envió precio
  ↓ cliente acepta    ↓ cliente rechaza
accepted              rejected
  ↓ puede ir a:
expired
```

### reservations
```
pending
  ↓ (flujo programado)
pending_group_confirmation
  ↓ grupo confirma
accepted
  ↓ cliente paga anticipo
confirmed
  ↓ evento inicia (event_started_at)
in_progress
  ↓ evento termina automáticamente
completed

En cualquier momento → cancelled | rejected | expired
```

### payment_status
```
deposit_pending   ← reserva creada, esperando pago
  ↓ cliente paga 50%
deposit_paid      ← anticipo confirmado por Stripe
  ↓ al finalizar el evento (cobro automático del restante)
fully_paid
```

---

## FUNCIONES RPC IMPORTANTES

| Función | Qué hace |
|---|---|
| `get_my_group()` | Retorna el grupo del usuario autenticado (SECURITY DEFINER) |
| `notify_wave_1(p_request_id, p_event_lat, p_event_lng, p_radius_km)` | Notifica top-5 grupos por ranking y proximidad a una solicitud express |
| `client_accept_proposal(p_request_id)` | Crea reserva en status='accepted' cuando cliente acepta propuesta express |
| `client_reject_proposal(p_request_id)` | Devuelve la solicitud a status='open' para que otro grupo proponga |
| `get_groups_ranked_by_city(p_city, p_state, p_limit)` | Lista grupos por ciudad con ranking |
| `get_surge_factor(p_genre, p_city)` | Factor de demanda (para precio dinámico) |

---

## EDGE FUNCTIONS (Supabase / Deno)

| Función | Qué hace |
|---|---|
| `create-payment-intent` | Crea/reutiliza Stripe Customer. Crea PaymentIntent por 50% del total. Guarda tarjeta para cobro off_session |
| `stripe-webhook` | Recibe eventos de Stripe. En `payment_intent.succeeded`: confirma reserva, notifica al grupo |
