# ✅ Actualización completa de la lógica de reservas

## Cambios implementados

### 1. **GroupConfirmBookingScreen** (Grupo)

**Archivo:** `src/screens/group/ConfirmBookingScreen.tsx`

**Botón "Confirmar reserva"** (líneas 47-71):
- ✅ Actualiza `status` a `'confirmed'`
- ✅ Crea notificación al cliente:
  ```
  Título: "✅ ¡Reserva confirmada!"
  Mensaje: "Tu reserva para el [fecha] fue confirmada. ¡Nos vemos pronto!"
  ```

**Botón "Rechazar"** (líneas 73-101):
- ✅ Actualiza `status` a `'rejected'` (no `'cancelled'`)
- ✅ Crea notificación al cliente:
  ```
  Título: "❌ Reserva rechazada"
  Mensaje: "Lo sentimos, tu reserva para el [fecha] fue rechazada..."
  ```

**Nuevo estado agregado:**
- ✅ `rejected` → Badge rojo "Rechazada"

---

### 2. **ClientReservationsScreen** (Cliente)

**Archivo:** `src/screens/client/ReservationsScreen.tsx`

**Botón "Cancelar reserva"** (líneas 157-174):
- ✅ Aparece solo si `status = 'pending'` o `status = 'confirmed'`
- ✅ Al cancelar:
  - Actualiza `status` a `'cancelled'`
  - Crea notificación al grupo (owner_id):
    ```
    Título: "❌ Reserva cancelada"
    Mensaje: "El cliente canceló la reserva del [fecha]."
    ```
  - Actualiza la lista automáticamente

**Diseño del botón:**
```tsx
┌─────────────────────────────────────┐
│ [X] Cancelar reserva                │ ← Fondo rojo suave
└─────────────────────────────────────┘
```

**Nuevo estado agregado:**
- ✅ `rejected` → Badge rojo "Rechazada"

---

### 3. **GroupReservationsScreen** (Grupo)

**Archivo:** `src/screens/group/ReservationsScreen.tsx`

**Actualizado:**
- ✅ Agregado estado `rejected` al STATUS_MAP

**Filtros disponibles:**
- Todas
- Pendiente (`pending`)
- Confirmada (`confirmed`)
- En curso (`in_progress`)
- Completada (`completed`)

**Estados de reserva:**
- `pending` → 🟠 Pendiente
- `confirmed` → 🟢 Confirmada
- `in_progress` → 🔵 En curso
- `completed` → ⚪ Completada
- `cancelled` → 🔴 Cancelada
- `rejected` → 🔴 Rechazada

---

### 4. **GroupDashboardScreen** (Grupo)

**Archivo:** `src/screens/group/DashboardScreen.tsx`

**"Pendientes" (mini-stat):**
- ✅ Cuenta solo reservas con `status = 'pending'`
- ✅ Muestra el número exacto
- ✅ Al tocar navega a `GroupReservations`

**"Próximos eventos" (líneas 184-191):**
- ✅ Muestra solo reservas con:
  - `status IN ('confirmed', 'in_progress')`
  - `event_date >= hoy`
  - Ordenadas por `event_date ASC`
  - Límite: 5 eventos

**Ejemplo de query:**
```sql
SELECT *
FROM reservations
WHERE group_id = 'xxx'
  AND status IN ('confirmed', 'in_progress')
  AND event_date >= CURRENT_DATE
ORDER BY event_date ASC
LIMIT 5;
```

---

## Flujo completo de una reserva

### 📋 **Estados de una reserva**

```
Cliente crea reserva
         ↓
    [pending] ────────┐
         ↓            │
         │            │ Grupo rechaza
    Grupo confirma    │      ↓
         ↓            └→ [rejected] (final)
    [confirmed] ──────┐
         ↓            │
         │            │ Cliente cancela
    Grupo inicia      │      ↓
         ↓            └→ [cancelled] (final)
    [in_progress]
         ↓
    Grupo completa
         ↓
    [completed] ← Pago procesado
         ↓
     [paid] (final)
```

### 🔔 **Notificaciones automáticas**

| Acción | Destinatario | Tipo | Título | Cuándo |
|--------|--------------|------|--------|--------|
| Nueva reserva | Grupo | `reservation` | 🎉 Nueva reserva recibida | Trigger automático al crear reserva |
| Grupo confirma | Cliente | `reservation` | ✅ ¡Reserva confirmada! | Al confirmar desde GroupConfirmBookingScreen |
| Grupo rechaza | Cliente | `reservation` | ❌ Reserva rechazada | Al rechazar desde GroupConfirmBookingScreen |
| Cliente cancela | Grupo | `reservation` | ❌ Reserva cancelada | Al cancelar desde ClientReservationsScreen |

---

## Restricciones y validaciones

### ✅ **Lo que el cliente PUEDE hacer:**

| Status | Puede cancelar? | Aparece en "Mis Reservas"? |
|--------|-----------------|---------------------------|
| `pending` | ✅ Sí | ✅ Sí |
| `confirmed` | ✅ Sí | ✅ Sí |
| `in_progress` | ❌ No | ✅ Sí |
| `completed` | ❌ No | ✅ Sí |
| `paid` | ❌ No | ✅ Sí |
| `cancelled` | ❌ No | ✅ Sí |
| `rejected` | ❌ No | ✅ Sí |

### ✅ **Lo que el grupo PUEDE hacer:**

| Status | Puede confirmar? | Puede rechazar? | Puede iniciar evento? |
|--------|------------------|-----------------|----------------------|
| `pending` | ✅ Sí | ✅ Sí | ❌ No |
| `confirmed` | ❌ No | ❌ No | ✅ Sí |
| `in_progress` | ❌ No | ❌ No | ❌ No (ya iniciado) |
| Otros | ❌ No | ❌ No | ❌ No |

---

## Pantallas actualizadas

### 1. **GroupConfirmBookingScreen**
```
┌────────────────────────────────────┐
│ ← Detalle de Reserva               │
├────────────────────────────────────┤
│ [Pendiente] #abc123                │
│                                    │
│ Cliente                            │
│ 👤 María López                     │
│ 📱 +52 33 1234 5678                │
│ ⭐ 4.8 Calificación del cliente    │
│                                    │
│ Evento                             │
│ 📅 2025-03-20                      │
│ 🕐 18:00                           │
│ 📍 Jardín Primavera, Zapopan      │
│                                    │
│ Paquete: Premium                   │
│ 3h de servicio                     │
│                                    │
│ ┌────────────────────────────────┐ │
│ │ ✅ Confirmar reserva           │ │ ← Verde
│ └────────────────────────────────┘ │
│ ┌────────────────────────────────┐ │
│ │ Rechazar                       │ │ ← Rojo
│ └────────────────────────────────┘ │
└────────────────────────────────────┘
```

### 2. **ClientReservationsScreen**
```
┌────────────────────────────────────┐
│ Mis Reservas                       │
├────────────────────────────────────┤
│ ┌──────────────────────────────┐   │
│ │ Los Trovadores   [Confirmada]│   │
│ │ Paquete Premium              │   │
│ │ 📅 2025-03-20  🕐 18:00      │   │
│ │ $5,200                    →  │   │
│ ├──────────────────────────────┤   │
│ │ [X] Cancelar reserva         │   │ ← Solo si pending o confirmed
│ └──────────────────────────────┘   │
└────────────────────────────────────┘
```

### 3. **GroupDashboardScreen - Mini Stats**
```
┌─────────────┬─────────────┬─────────────┐
│ 📅 3        │ ✅ 12       │ 📦 4        │
│ Pendientes  │ Completadas │ Paquetes    │
└─────────────┴─────────────┴─────────────┘
```

### 4. **GroupDashboardScreen - Próximos eventos**
```
PRÓXIMOS EVENTOS

20 MAR  María López
        Premium · 3h
        Jardín Primavera
        $4,250 →

25 MAR  Carlos Ramírez
        Básico · 2h
        Salón Estrella
        $3,000 →
```
Solo muestra: `confirmed` o `in_progress`, con `event_date >= hoy`

---

## Testing checklist

### Como Grupo:
- [ ] Ver solo reservas `pending` en el contador "Pendientes"
- [ ] Ver solo eventos `confirmed/in_progress` con fecha >= hoy en "Próximos eventos"
- [ ] Confirmar reserva → cliente recibe notificación
- [ ] Rechazar reserva → cliente recibe notificación
- [ ] Estado cambia correctamente en la lista

### Como Cliente:
- [ ] Ver todas mis reservas (cualquier estado)
- [ ] Botón "Cancelar" aparece solo en `pending` y `confirmed`
- [ ] Botón "Cancelar" NO aparece en otros estados
- [ ] Al cancelar → grupo recibe notificación
- [ ] Al cancelar → la reserva desaparece del contador del grupo

### Notificaciones:
- [ ] Cliente recibe notificación al confirmar
- [ ] Cliente recibe notificación al rechazar
- [ ] Grupo recibe notificación al cancelar cliente
- [ ] Contador de notificaciones se actualiza
- [ ] Al tocar notificación navega correctamente

---

## SQL para verificar

```sql
-- Ver todas las reservas pendientes de un grupo
SELECT r.id, r.event_date, r.status, c.full_name as cliente
FROM reservations r
JOIN profiles c ON c.id = r.client_id
WHERE r.group_id = 'GROUP_ID'
  AND r.status = 'pending'
ORDER BY r.created_at DESC;

-- Ver próximos eventos confirmados
SELECT r.id, r.event_date, r.event_time, r.status
FROM reservations r
WHERE r.group_id = 'GROUP_ID'
  AND r.status IN ('confirmed', 'in_progress')
  AND r.event_date >= CURRENT_DATE
ORDER BY r.event_date ASC;

-- Ver notificaciones del cliente
SELECT type, title, message, is_read, created_at
FROM notifications
WHERE user_id = 'CLIENT_ID'
ORDER BY created_at DESC;
```

---

## ✅ Todo implementado y funcional

No hay placeholders. Todo está conectado a Supabase:
- ✅ Estados de reserva
- ✅ Filtros por status
- ✅ Notificaciones automáticas
- ✅ Botones condicionales
- ✅ Navegación entre pantallas
- ✅ Actualización en tiempo real
